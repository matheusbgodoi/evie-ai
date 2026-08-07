import Foundation

/// Runs a turn in which Evie may look things up before answering.
///
/// The loop is bounded in every direction that can run away. Each step costs a
/// full request against the local model, and a step is expensive: measured on
/// this Mac against a freshly started server, one tool took 20 s end to end and a
/// three-tool chain took 37 s. Four steps is enough for the deepest sensible
/// chain here (list_roots → search_files → read_file → answer) and short enough
/// that a confused model gives up while the user is still willing to wait.
///
/// An earlier version of this comment claimed those numbers degrade with server
/// uptime. They do not: that measurement was taken across a closed lid, and both
/// `Date()` and the server's own timer count standby. See `docs/FILESYSTEM.md`.
public struct EvieAgentLoop: Sendable {
  /// How many times the model may ask for tools before it must answer.
  public static let maximumIterations = 4
  /// How many calls are honoured in a single step. A model that asks for twenty
  /// at once has lost the thread.
  public static let maximumCallsPerIteration = 4

  public var toolbox: EvieFileToolbox
  /// Set only when the user switched web search on. Absent means the tools are
  /// never offered, which is the truth rather than a refusal she has to explain.
  public var web: (any EvieWebSearching)?
  /// Set only when the user switched Mail and Calendar on. Absent means the
  /// tools are never offered — the truth when the switch is off, and better than
  /// declaring three functions whose only possible outcome is a refusal.
  public var mailAndCalendar: (any EvieMailCalendarReading)?
  /// The vault, chunked and embedded. When present, grounding uses hybrid
  /// retrieval over it instead of scanning files for a substring — which finds
  /// nothing when the note says "valor da minha hora" and the question said
  /// "quanto eu cobro".
  public var vault: (@Sendable (String) async -> [EvieRetrievedPassage])?
  /// Whether she may suggest changing a file. Off unless the user switched it on,
  /// and even then the tool only ever raises a card.
  public var offersChanges: Bool
  public var maximumIterations: Int

  public init(
    toolbox: EvieFileToolbox = EvieFileToolbox(),
    web: (any EvieWebSearching)? = nil,
    mailAndCalendar: (any EvieMailCalendarReading)? = nil,
    vault: (@Sendable (String) async -> [EvieRetrievedPassage])? = nil,
    offersChanges: Bool = false,
    maximumIterations: Int = EvieAgentLoop.maximumIterations
  ) {
    self.toolbox = toolbox
    self.web = web
    self.mailAndCalendar = mailAndCalendar
    self.vault = vault
    self.offersChanges = offersChanges
    self.maximumIterations = maximumIterations
  }

  /// What the turn produced.
  public struct Outcome: Sendable {
    /// Everything added to the conversation: the assistant turns that asked for
    /// tools, the results, and the final answer.
    public var appended: [ChatMessage]
    /// The answer to show and speak. Empty when the model never produced one.
    public var answer: String
    /// How many tools actually ran, for the user to see afterwards.
    public var toolCallCount: Int
    /// True when the loop hit its ceiling instead of the model finishing.
    public var exhausted: Bool
    /// Memories she asked to keep. Nothing has been stored: these are proposals,
    /// and storing one is a click the user has not made yet.
    public var memoryProposals: [String] = []
    /// Where the answer came from, worked out from what ran rather than from what
    /// she says she did.
    public var provenance = EvieAnswerProvenance()
    /// Changes she asked to make. Nothing has happened: these are proposals, and
    /// each one is a button the user has not pressed.
    public var changeProposals: [EvieFileChange] = []
    /// Ways of working she asked to keep. Nothing installed.
    public var skillProposals: [EvieSkill] = []
  }

  /// Runs the turn.
  ///
  /// `emit` receives the same events a plain turn produces, so the overlay shows
  /// text streaming in exactly as it always did, plus the phase changes that say
  /// she is looking something up. It is `async` so the interface can be updated
  /// on the main actor while the loop itself — including the blocking file reads
  /// a tool performs — stays off it.
  /// - Parameter carriesAttachment: whether the conversation already contains a
  ///   file the person attached. When it does, nothing is looked up: the subject
  ///   of the question is on the screen, and searching for it is both slow and
  ///   wrong. Measured on a real turn — a painting attached with "sobre o que é
  ///   esta imagem?" — the search returned Google's own help pages about
  ///   identifying images, contributed nothing to an answer that came entirely
  ///   from having looked at the picture, and still made the card claim "Usei a
  ///   web". Seconds spent to end up citing a source that was not used.
  /// - Parameter skipsNotes: whether the person asked for the web specifically,
  ///   with `/web`. The notes-first order is enforced here rather than requested
  ///   of the model, so the only honest way to skip that step is to say so here.
  ///   It also forces the lookup: `/web` is an explicit instruction to go and
  ///   look, so the judgement about whether a question is worth looking up does
  ///   not get to overrule it.
  public func run(
    messages: [ChatMessage],
    roots: [EvieFileRoot],
    client: any AgentClient,
    carriesAttachment: Bool = false,
    skipsNotes: Bool = false,
    emit: @Sendable (EvieInteractionEvent) async -> Void
  ) async throws -> Outcome {
    var conversation = messages
    var appended: [ChatMessage] = []
    var toolCallCount = 0
    var memoryProposals: [String] = []
    var changeProposals: [EvieFileChange] = []
    var skillProposals: [EvieSkill] = []
    var toolNames: [String] = []
    var readAddresses: [String] = []
    // Memory is offered alongside the file tools, and is the only one of them
    // that is about her rather than about the disk. It still changes nothing.
    var tools =
      EvieFileToolbox.definitions
      + [
        EvieMemoryTool.definition, EvieSkillTool.definition,
        // Always declared. Arithmetic has no privacy dimension and no I/O, and a
        // calculator behind a switch is a calculator nobody turns on.
        EvieCalculatorTool.definition,
      ]
    if web != nil {
      tools += EvieWebTool.definitions
    }
    if mailAndCalendar != nil {
      tools += EvieMailCalendarTool.definitions
    }
    if offersChanges, !roots.isEmpty {
      tools.append(EvieChangeTool.definition)
    }

    // Looked up before the model is asked anything, so the order the user asked
    // for is a property of this code rather than a request the model can decline
    // — which, measured twice, it does.
    if let question = messages.last(where: { $0.role == .user })?.content {
      var grounding = EvieGroundingResult()
      if !carriesAttachment, skipsNotes || EvieGrounding.needsLookup(question) {
        grounding = await ground(
          question: question,
          roots: roots,
          skipsNotes: skipsNotes,
          emit: emit
        )
      }
      // Arithmetic is grounded on every turn, including the ones the search
      // above skipped: a sum is exactly what `EvieGrounding` refuses to look up,
      // and an attached file does not stop the person asking what 15% of 3400
      // is. It costs no I/O and no round trip, so there is nothing to weigh.
      grounding.arithmeticFindings = EvieArithmeticGrounding.findings(for: question)
      if let message = grounding.message {
        conversation.append(message)
        if grounding.localFindings != nil {
          toolNames.append(EvieFileToolbox.ToolName.searchContent.rawValue)
        }
        if grounding.webFindings != nil {
          toolNames.append(EvieWebTool.search.rawValue)
        }
        readAddresses.append(contentsOf: grounding.citedPages)
      }
    }

    for iteration in 0..<maximumIterations {
      try Task.checkCancellation()

      let isLastIteration = iteration == maximumIterations - 1
      // The tools stay declared on every pass, including the last.
      //
      // They used to be withdrawn there, to stop the model asking for something
      // that could no longer be honoured. It backfired: the model asks anyway —
      // the conversation it is reading is full of tool calls, so another one is
      // the obvious continuation — and this server rejects a call naming a tool
      // that was not declared. Measured in its log:
      //
      //   failed phase=generating status=500
      //   error=GemmaToolCallParserError.unknownTool("search_web")
      //
      // A 500 is worse than a wasted call: the turn dies and the person is told
      // the model failed, when what happened is that Evie asked it to answer
      // without the vocabulary it needed to refuse properly. Declaring the tools
      // and simply not running them keeps the request well formed.
      let step = try await Self.completeOnce(
        messages: conversation,
        tools: tools,
        client: client,
        emit: emit
      )

      // On the last pass a tool call is not honoured, but it is answered: the
      // model is told the lookups are finished and asked for what it has. One
      // extra completion, only in the case that used to be a dead turn.
      if isLastIteration, let calls = step.message.toolCalls, !calls.isEmpty {
        appended.append(step.message)
        conversation.append(step.message)
        for call in calls {
          let refusal = EvieToolResult(
            callID: call.id,
            name: call.name,
            content: "Não há mais consultas disponíveis nesta pergunta.",
            isFailure: true
          )
          conversation.append(refusal.message)
          appended.append(refusal.message)
        }
        // Said as a user turn, because this server refuses `developer`
        // guidance once a conversation has started — measured twice earlier in
        // this project. A tool result alone was not enough: with the tools still
        // declared the model simply asked again, and the turn ended empty.
        conversation.append(
          ChatMessage(
            role: .user,
            content: """
              Chega de buscas. Responda agora, em português, com o que você já \
              achou acima. Se o que você achou não responde tudo, diga o que \
              ficou faltando em vez de procurar de novo.
              """
          )
        )
        let closing = try await Self.completeOnce(
          messages: conversation,
          tools: tools,
          client: client,
          emit: emit
        )
        appended.append(closing.message)
        return Outcome(
          appended: appended,
          answer: closing.message.content,
          toolCallCount: toolCallCount,
          exhausted: closing.message.content.isEmpty,
          memoryProposals: memoryProposals,
          provenance: .from(
            toolCalls: toolNames,
            readAddresses: readAddresses,
            readAttachment: carriesAttachment
          ),
          changeProposals: changeProposals,
          skillProposals: skillProposals
        )
      }

      guard let calls = step.message.toolCalls, !calls.isEmpty else {
        appended.append(step.message)
        return Outcome(
          appended: appended,
          answer: step.message.content,
          toolCallCount: toolCallCount,
          exhausted: false,
          memoryProposals: memoryProposals,
          provenance: .from(
            toolCalls: toolNames,
            readAddresses: readAddresses,
            readAttachment: carriesAttachment
          ),
          changeProposals: changeProposals,
          skillProposals: skillProposals
        )
      }

      conversation.append(step.message)
      appended.append(step.message)

      let honoured = calls.prefix(Self.maximumCallsPerIteration)
      for call in honoured {
        try Task.checkCancellation()
        await emit(.status(message: Self.describe(call)))

        toolNames.append(call.name)
        let result: EvieToolResult
        if let web, let webTool = EvieWebTool(rawValue: call.name) {
          if webTool == .read, let address = ((try? call.arguments()) ?? [:])["url"] {
            readAddresses.append(address)
          }
          result = await Self.runWeb(webTool, call: call, using: web)
        } else if let mailAndCalendar,
          let appTool = EvieMailCalendarTool(rawValue: call.name)
        {
          result = await Self.runAppleApp(appTool, call: call, using: mailAndCalendar)
        } else if EvieMailCalendarTool.refusedWritingNames.contains(call.name) {
          // Reached only when the model invents a name that was never declared.
          // Answered with a sentence rather than "essa ferramenta não existe",
          // which reads as a typo and gets tried again with a different spelling.
          result = EvieToolResult(
            callID: call.id,
            name: call.name,
            content: EvieMailCalendarTool.writingRefusal,
            isFailure: true
          )
        } else if offersChanges, call.name == EvieChangeTool.name {
          let (outcome, proposal) = Self.recordChange(call, roots: roots, toolbox: toolbox)
          result = outcome
          if let proposal {
            changeProposals.append(proposal)
          }
        } else if call.name == EvieCalculatorTool.name {
          result = EvieCalculatorTool.execute(call)
        } else if call.name == EvieSkillTool.name {
          if let skill = EvieSkillTool.skill(from: call) {
            skillProposals.append(skill)
            result = EvieToolResult(
              callID: call.id,
              name: call.name,
              content: """
                Sugestão de skill "\(skill.name)" mostrada ao Matheus. NADA foi \
                instalado — só acontece se ele confirmar. Não diga que já aprendeu.
                """
            )
          } else {
            result = EvieToolResult(
              callID: call.id,
              name: call.name,
              content: "Faltou nome ou instruções.",
              isFailure: true
            )
          }
        } else if call.name == EvieMemoryTool.name {
          let fact = ((try? call.arguments()) ?? [:])["fact"] ?? ""
          result = Self.acknowledgeMemory(call, fact: fact)
          if !fact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            memoryProposals.append(fact)
          }
        } else {
          result = toolbox.execute(call, roots: roots)
        }
        toolCallCount += 1
        conversation.append(result.message)
        appended.append(result.message)
      }
      // A call that was not run still needs an answer, or the model waits for a
      // result that never comes and the next turn is malformed.
      for call in calls.dropFirst(Self.maximumCallsPerIteration) {
        let refusal = EvieToolResult(
          callID: call.id,
          name: call.name,
          content: "Pedidos demais de uma vez. Peça um por vez.",
          isFailure: true
        )
        conversation.append(refusal.message)
        appended.append(refusal.message)
      }
    }

    return Outcome(
      appended: appended,
      answer: "",
      toolCallCount: toolCallCount,
      exhausted: true,
      memoryProposals: memoryProposals,
      provenance: .from(
            toolCalls: toolNames,
            readAddresses: readAddresses,
            readAttachment: carriesAttachment
          ),
      changeProposals: changeProposals,
      skillProposals: skillProposals
    )
  }
}

extension EvieAgentLoop {
  /// Searches his notes, then the web, before anything is generated.
  ///
  /// The web is only consulted when the notes came back empty, which is the
  /// order he asked for and also the cheaper one: his own writing is on this
  /// disk and is more likely to be what he meant.
  fileprivate func ground(
    question: String,
    roots: [EvieFileRoot],
    skipsNotes: Bool = false,
    emit: @Sendable (EvieInteractionEvent) async -> Void
  ) async -> EvieGroundingResult {
    var result = EvieGroundingResult()
    let query = EvieGrounding.query(from: question)

    if skipsNotes {
      // `/web`: the notes step is skipped entirely rather than run and ignored,
      // because running it is the expensive part and its only other effect would
      // be to stop the web step below from happening at all.
    } else if let vault {
      // Hybrid retrieval over the indexed vault: words and meaning, fused.
      await emit(.status(message: "Procurando nas suas anotações…"))
      let retrieved = await vault(query)
      if !retrieved.isEmpty {
        result.localFindings = EvieVaultRetriever.describe(retrieved, query: query)
      }
    } else if !roots.isEmpty {
      // No index yet — the first launch, or a Mac with no embedding model. A
      // substring scan is worse and is better than nothing.
      await emit(.status(message: "Procurando nas suas anotações…"))
      let found = roots.compactMap { root -> String? in
        let call = EvieToolCall(
          id: "grounding-\(root.id)",
          name: EvieFileToolbox.ToolName.searchContent.rawValue,
          argumentsJSON: Self.searchArguments(rootID: root.id, query: query)
        )
        let outcome = toolbox.execute(call, roots: roots)
        return outcome.isFailure || outcome.content.contains("Não achei")
          ? nil
          : outcome.content
      }
      if !found.isEmpty {
        result.localFindings = found.joined(separator: "\n\n")
      }
    }

    // Only when his own writing did not answer it.
    if result.localFindings == nil, let web {
      await emit(.status(message: "Procurando na web…"))
      // Three pages read at once, and only the passages that match the question
      // sent on. The version this replaces took the first 3,500 characters of the
      // first result — mostly menu and cookie banner, from a single source that
      // might be wrong, while the paragraph that answered could sit past the cut.
      if let passages = try? await web.gather(query, pages: 3, passages: 6),
        !passages.isEmpty
      {
        result.webFindings = EvieWebPassages.describe(passages, query: query)
        result.citedPages = passages
          .map(\.source)
          .reduce(into: [String]()) { unique, source in
            if !unique.contains(source) {
              unique.append(source)
            }
          }
      }
    }
    return result
  }

  /// Built with `JSONSerialization` rather than string interpolation, because a
  /// question containing a quotation mark would otherwise produce malformed
  /// arguments.
  fileprivate static func searchArguments(rootID: String, query: String) -> String {
    let object: [String: String] = ["root_id": rootID, "query": query]
    guard let data = try? JSONSerialization.data(withJSONObject: object),
      let text = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return text
  }

  fileprivate struct Step {
    var message: ChatMessage
    var finishReason: EvieFinishReason
  }

  /// One request, collapsed from the event stream into a single message.
  fileprivate static func completeOnce(
    messages: [ChatMessage],
    tools: [EvieToolDefinition],
    client: any AgentClient,
    emit: @Sendable (EvieInteractionEvent) async -> Void
  ) async throws -> Step {
    var message: ChatMessage?
    var finishReason = EvieFinishReason.other

    for try await event in client.stream(messages: messages, tools: tools) {
      try Task.checkCancellation()
      await emit(event)
      if case .completed(let completed, let reason) = event {
        message = completed
        finishReason = EvieFinishReason(wireValue: reason)
      }
    }

    guard let message else {
      throw TurboFieldfareClientError.emptyStream
    }
    return Step(message: message, finishReason: finishReason)
  }

  /// What the overlay says while a tool runs.
  ///
  /// Said in terms of what the user granted, never in terms of a path or an
  /// identifier: "olhando em Downloads" is the truth at the level they care
  /// about.
  fileprivate static func describe(_ call: EvieToolCall) -> String {
    let arguments = (try? call.arguments()) ?? [:]
    switch EvieFileToolbox.ToolName(rawValue: call.name) {
    case .listRoots:
      return "Vendo o que você me autorizou…"
    case .listFolder:
      return "Olhando a pasta…"
    case .readFile:
      if let path = arguments["path"], !path.isEmpty {
        return "Lendo \((path as NSString).lastPathComponent)…"
      }
      return "Lendo um arquivo…"
    case .searchFiles:
      if let query = arguments["query"], !query.isEmpty {
        return "Procurando por \"\(query)\"…"
      }
      return "Procurando…"
    case .searchContent:
      if let query = arguments["query"], !query.isEmpty {
        return "Lendo suas anotações sobre \"\(query)\"…"
      }
      return "Lendo suas anotações…"
    case .fileInfo:
      return "Conferindo os detalhes…"
    case nil:
      if call.name == EvieMemoryTool.name {
        return "Anotando uma coisa para te perguntar…"
      }
      if call.name == EvieChangeTool.name {
        return "Preparando uma sugestão para você aprovar…"
      }
      if call.name == EvieSkillTool.name {
        return "Escrevendo um jeito de fazer isso da próxima vez…"
      }
      switch EvieMailCalendarTool(rawValue: call.name) {
      case .readMail:
        return "Lendo seu Mail…"
      case .searchMail:
        if let query = arguments["query"], !query.isEmpty {
          return "Procurando \"\(query)\" no seu Mail…"
        }
        return "Procurando no seu Mail…"
      case .readCalendar:
        return "Vendo sua agenda…"
      case nil:
        break
      }
      switch EvieWebTool(rawValue: call.name) {
      case .search:
        if let query = arguments["query"], !query.isEmpty {
          return "Procurando na web por \"\(query)\"…"
        }
        return "Procurando na web…"
      case .read:
        if let address = arguments["url"], let host = URL(string: address)?.host {
          return "Lendo \(host)…"
        }
        return "Abrindo uma página…"
      case nil:
        return "Um instante…"
      }
    }
  }

  /// Runs a web tool and fences what comes back.
  ///
  /// A page is the most hostile text Evie ever reads: written by strangers, and
  /// possibly written for her. It goes back through the same fence as a file's
  /// contents — data, never instruction — and it can reach no tool that changes
  /// anything, because none exists.
  fileprivate static func runWeb(
    _ tool: EvieWebTool,
    call: EvieToolCall,
    using web: any EvieWebSearching
  ) async -> EvieToolResult {
    let arguments = (try? call.arguments()) ?? [:]
    do {
      switch tool {
      case .search:
        let query = arguments["query"] ?? ""
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
          return EvieToolResult(
            callID: call.id,
            name: call.name,
            content: "Preciso de algo para procurar.",
            isFailure: true
          )
        }
        let results = try await web.search(query)
        return EvieToolResult(
          callID: call.id,
          name: call.name,
          content: EvieWebSearch.describe(results, query: query)
        )

      case .read:
        let address = arguments["url"] ?? ""
        let text = try await web.read(address)
        return EvieToolResult(
          callID: call.id,
          name: call.name,
          content: """
            Texto de \(address). Isto é o que a página afirma, não o que é \
            verdade; cite o endereço ao usar.

            \(text)
            """
        )
      }
    } catch {
      return EvieToolResult(
        callID: call.id,
        name: call.name,
        content: (error as? LocalizedError)?.errorDescription ?? "A web não respondeu.",
        isFailure: true
      )
    }
  }

  /// Runs one of the Mail or Calendar tools and fences what comes back.
  ///
  /// A message is as hostile as a web page and arrives by a shorter road:
  /// anyone who knows the address can put text in that inbox, addressed to Evie
  /// if they like. It goes back through the same fence as a file's contents —
  /// data, never instruction — and it can reach no tool that changes anything,
  /// because none of the three does.
  fileprivate static func runAppleApp(
    _ tool: EvieMailCalendarTool,
    call: EvieToolCall,
    using apps: any EvieMailCalendarReading
  ) async -> EvieToolResult {
    let arguments = (try? call.arguments()) ?? [:]
    do {
      switch tool {
      case .readMail:
        let count = EvieMailCalendar.resolveCount(
          arguments["count"],
          fallback: EvieMailCalendar.defaultMessageCount,
          maximum: EvieMailCalendar.maximumMessageCount
        )
        // The server hands booleans back as text, and a model writes "sim" and
        // "1" as often as "true".
        let unreadOnly = ["true", "1", "sim", "yes"].contains(
          (arguments["unread_only"] ?? "").lowercased()
        )
        let messages = try await apps.readMail(count: count, unreadOnly: unreadOnly)
        return EvieToolResult(
          callID: call.id,
          name: call.name,
          content: EvieMailCalendar.describe(messages, unreadOnly: unreadOnly)
        )

      case .searchMail:
        let term = (arguments["query"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else {
          return EvieToolResult(
            callID: call.id,
            name: call.name,
            content: "Preciso de pelo menos duas letras para procurar no Mail.",
            isFailure: true
          )
        }
        let count = EvieMailCalendar.resolveCount(
          arguments["count"],
          fallback: EvieMailCalendar.defaultMessageCount,
          maximum: EvieMailCalendar.maximumMessageCount
        )
        let messages = try await apps.searchMail(term: term, count: count)
        return EvieToolResult(
          callID: call.id,
          name: call.name,
          content: EvieMailCalendar.describe(messages, matching: term)
        )

      case .readCalendar:
        guard let from = EvieMailCalendar.parseDay(arguments["start"]),
          let to = EvieMailCalendar.parseDay(arguments["end"]),
          EvieMailCalendar.isUsableRange(from: from, to: to)
        else {
          return EvieToolResult(
            callID: call.id,
            name: call.name,
            content: EvieMailCalendarError.badDateRange.localizedDescription,
            isFailure: true
          )
        }
        let events = try await apps.readCalendar(
          from: from,
          to: to,
          limit: EvieMailCalendar.calendarCollectionCap
        )
        return EvieToolResult(
          callID: call.id,
          name: call.name,
          content: EvieMailCalendar.describe(events, from: from, to: to)
        )
      }
    } catch {
      return EvieToolResult(
        callID: call.id,
        name: call.name,
        content: (error as? LocalizedError)?.errorDescription
          ?? "Não consegui falar com o app.",
        isFailure: true
      )
    }
  }

  /// Turns a change request into a card, and performs nothing.
  ///
  /// The file's identity is captured here rather than when the button is pressed,
  /// because the approval is for the file as it is *now* — the one the user is
  /// about to be shown. If it changes between the card appearing and the click,
  /// the writer refuses.
  fileprivate static func recordChange(
    _ call: EvieToolCall,
    roots: [EvieFileRoot],
    toolbox: EvieFileToolbox
  ) -> (EvieToolResult, EvieFileChange?) {
    switch EvieChangeTool.proposal(from: call) {
    case .failure(let reason):
      return (
        EvieToolResult(
          callID: call.id, name: call.name, content: reason.message, isFailure: true
        ),
        nil
      )

    case .success(var change):
      guard let root = roots.first(where: { $0.id == change.rootID }) else {
        return (
          EvieToolResult(
            callID: call.id,
            name: call.name,
            content: """
              Não existe pasta autorizada com o identificador \(change.rootID). \
              Chame list_roots e use um de lá.
              """,
            isFailure: true
          ),
          nil
        )
      }
      // Refused here rather than at the button, so the model learns immediately
      // that the file is not reachable instead of the user discovering it.
      guard
        let precondition = try? EvieFileWriter().precondition(of: change, in: root)
      else {
        return (
          EvieToolResult(
            callID: call.id,
            name: call.name,
            content: "Não achei \(change.path) em \(root.displayName).",
            isFailure: true
          ),
          nil
        )
      }
      change.precondition = precondition

      return (
        EvieToolResult(
          callID: call.id,
          name: call.name,
          content: """
            Sugestão mostrada ao Matheus: \(change.describe(rootName: root.displayName)). \
            NADA foi feito ainda — só acontece se ele confirmar na tela. Não diga \
            que já fez.
            """
        ),
        change
      )
    }
  }

  /// The answer handed back for a memory proposal.
  ///
  /// It says plainly that nothing was stored, because a model told "ok" will
  /// otherwise go on to tell the user it has remembered something — which would
  /// be false until a button is pressed, and the kind of false that is only
  /// discovered much later.
  fileprivate static func acknowledgeMemory(
    _ call: EvieToolCall,
    fact: String
  ) -> EvieToolResult {
    guard !fact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return EvieToolResult(
        callID: call.id,
        name: call.name,
        content: "Faltou o texto da lembrança.",
        isFailure: true
      )
    }
    return EvieToolResult(
      callID: call.id,
      name: call.name,
      content: """
        Sugestão registrada e mostrada ao Matheus. NADA foi guardado ainda — só \
        será se ele confirmar na tela. Não diga a ele que você já lembrou disso; \
        se quiser, mencione que sugeriu guardar.
        """
    )
  }
}
