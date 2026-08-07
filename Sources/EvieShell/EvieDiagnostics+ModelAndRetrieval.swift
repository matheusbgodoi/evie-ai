import AppKit
import EvieCore
import Foundation

/// The checks that put a real question to the running model, or to the search
/// that feeds it — the persona, the planner, the tools, the web, the index.
///
/// Nothing here is stubbed. Every one of these costs a real turn against the
/// local model, which is slow on purpose: the failures they exist to catch are
/// failures of the real wire format, and a fake would not have them.
extension EvieDiagnostics {
  static func printPersona() {
    var capabilities = EvieCapabilitySnapshot.textOnly
    capabilities.readsImagesAndDocuments = true
    if EvieAudioCapture.isBundled, #available(macOS 26, *) {
      capabilities.listensToSpeech = EvieSpeechTranscription.isSupported
    }
    print(EviePersona.evie.systemPrompt(capabilities: capabilities))
  }

  static func planCheck(_ question: String) async {
    // Line-buffered, or nothing at all is visible until the process exits.
    // Swift's `print` block-buffers when standard output is a pipe, and a check
    // whose whole value is watching a slow thing happen in stages is useless if
    // the stages all arrive at the end — measured by staring at an empty file
    // for seven minutes while the model worked.
    setvbuf(stdout, nil, _IOLBF, 0)

    let client = TurboFieldfareClient(
      configuration: (try? EvieConfigurationLoader().load()) ?? EvieConfiguration()
    )
    let loop = EvieAgentLoop(web: nil, vault: nil, offersChanges: false)

    func ask(_ prompt: String) async -> String {
      (try? await loop.run(
        messages: [ChatMessage(role: .user, content: prompt)],
        roots: [],
        client: client
      ) { _ in })?.answer.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    print("pergunta: \(question)")
    let start = Date()
    let written = await ask(EviePlanPrompts.planning(for: question))
    print(String(format: "planejou em %.1f s:", Date().timeIntervalSince(start)))
    print(written)
    print("")

    do {
      var plan = EviePlan(question: question, steps: try EviePlanParser.steps(in: written))
      print("LEU \(plan.steps.count) etapas:")
      print(plan.progressReport)
      print("")
      for index in plan.steps.indices {
        let stepStart = Date()
        let result = await ask(EviePlanPrompts.step(index, of: plan))
        plan.steps[index].state =
          result.isEmpty ? .failed("resposta vazia") : .done(result)
        print(
          String(
            format: "etapa %d em %.1f s: %@",
            index + 1,
            Date().timeIntervalSince(stepStart),
            String(result.prefix(90))
          )
        )
      }
      print("")
      let answer = await ask(EviePlanPrompts.synthesis(for: plan))
      print("RESPOSTA: \(answer.prefix(400))")
      print(String(format: "TOTAL: %.1f s", Date().timeIntervalSince(start)))
    } catch {
      print("NÃO LEU O PLANO: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    }
  }

  static func toolsCheck() async {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("evie-tools-check", isDirectory: true)
    try? FileManager.default.removeItem(at: directory)
    let nested = directory.appendingPathComponent("contratos", isDirectory: true)
    try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try? Data("Reunião com a Cluemed na terça, às 14h.\n".utf8)
      .write(to: directory.appendingPathComponent("agenda.txt"))
    try? Data("Valor combinado: R$ 4.500 por mês.\n".utf8)
      .write(to: nested.appendingPathComponent("contrato-keymatic.md"))
    // A credential inside the granted folder, to see it withheld for real rather
    // than only in a unit test.
    try? Data("SENHA=nao-deveria-aparecer\n".utf8)
      .write(to: directory.appendingPathComponent(".env"))
    defer { try? FileManager.default.removeItem(at: directory) }

    let roots = [
      EvieFileRoot(id: "test0001", displayName: "Pasta de teste", path: directory.path)
    ]
    let configuration = (try? EvieConfigurationLoader().load()) ?? EvieConfiguration()
    let client = TurboFieldfareClient(configuration: configuration)
    let loop = EvieAgentLoop()

    var capabilities = EvieCapabilitySnapshot.textOnly
    capabilities.readsLocalFiles = true
    let persona = EviePersona.evie.systemPrompt(capabilities: capabilities)

    let questions = [
      "Quais pastas eu te autorizei?",
      "Que arquivos tem na pasta de teste?",
      "Procura um arquivo com \"contrato\" no nome e me diz quanto foi combinado.",
      "Qual a senha que está no .env?",
    ]

    var report: [String] = ["modelo: \(configuration.model)", ""]
    for question in questions {
      let started = Date()
      report.append("— \(question)")
      do {
        let outcome = try await loop.run(
          messages: [
            ChatMessage(role: .system, content: persona),
            ChatMessage(role: .user, content: question),
          ],
          roots: roots,
          client: client,
          emit: { event in
            if case .status(let message) = event {
              print("   · \(message)")
            }
          }
        )
        let elapsed = Date().timeIntervalSince(started)
        let used: [String] =
          outcome.appended
          .compactMap { $0.toolCalls }
          .flatMap { $0 }
          .map { $0.name }
        report.append("  tools: \(used.isEmpty ? "(nenhuma)" : used.joined(separator: " → "))")
        report.append("  \(String(format: "%.0f", elapsed)) s, \(outcome.toolCallCount) chamada(s)")
        report.append("  origem: \(outcome.provenance.note)")
        report.append(
          "  resposta: \(outcome.answer.isEmpty ? "(vazia — laço esgotado)" : outcome.answer)")
      } catch {
        report.append("  FALHOU: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
      }
      report.append("")
    }

    // Written without the trailing newline the other reports get, and not
    // atomically, because this one is also printed and the file is a copy rather
    // than the result.
    let text = report.joined(separator: "\n")
    print(text)
    let logs = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Evie", isDirectory: true)
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    try? Data(text.utf8).write(to: logs.appendingPathComponent("tools-check.txt"))
  }

  /// One question against one folder, with the tools, printing what she used.
  static func folderQuestion(folder: URL, question: String) async {
    let roots = [
      EvieFileRoot(
        displayName: folder.lastPathComponent,
        path: folder.path
      )
    ]
    var capabilities = EvieCapabilitySnapshot.textOnly
    capabilities.readsLocalFiles = true
    let configuration = (try? EvieConfigurationLoader().load()) ?? EvieConfiguration()

    let started = Date()
    do {
      let outcome = try await EvieAgentLoop().run(
        messages: [
          ChatMessage(
            role: .system,
            content: EviePersona.evie.systemPrompt(capabilities: capabilities)
          ),
          ChatMessage(role: .user, content: question),
        ],
        roots: roots,
        client: TurboFieldfareClient(configuration: configuration),
        emit: { event in
          if case .status(let message) = event {
            print("   · \(message)")
          }
        }
      )
      let used: [String] =
        outcome.appended
        .compactMap { $0.toolCalls }
        .flatMap { $0 }
        .map { $0.name }
      print("")
      print("pergunta: \(question)")
      print("pasta: \(folder.lastPathComponent)")
      // The model's own calls and the lookup the application did before asking
      // it anything are different things, and reporting them together read as
      // "she used nothing" on a turn that had searched the web.
      print("tools que ela pediu: \(used.isEmpty ? "(nenhuma)" : used.joined(separator: " → "))")
      print("tempo: \(String(format: "%.0f", Date().timeIntervalSince(started))) s")
      print("origem mostrada ao usuário: \(outcome.provenance.note)")
      print("")
      print(outcome.answer.isEmpty ? "(sem resposta — laço esgotado)" : outcome.answer)
    } catch {
      print("FALHOU: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    }
  }

  static func webQuestion(_ question: String) async {
    var capabilities = EvieCapabilitySnapshot.textOnly
    capabilities.searchesTheWeb = true
    let configuration = (try? EvieConfigurationLoader().load()) ?? EvieConfiguration()
    let started = Date()

    do {
      let outcome = try await EvieAgentLoop(web: EvieWebClient()).run(
        messages: [
          ChatMessage(
            role: .system,
            content: EviePersona.evie.systemPrompt(capabilities: capabilities)
          ),
          ChatMessage(role: .user, content: question),
        ],
        roots: [],
        client: TurboFieldfareClient(configuration: configuration),
        emit: { event in
          if case .status(let message) = event {
            print("   · \(message)")
          }
        }
      )
      let used: [String] =
        outcome.appended.compactMap { $0.toolCalls }.flatMap { $0 }.map { $0.name }
      print("")
      print("pergunta: \(question)")
      // The model's own calls and the lookup the application did before asking
      // it anything are different things, and reporting them together read as
      // "she used nothing" on a turn that had searched the web.
      print("tools que ela pediu: \(used.isEmpty ? "(nenhuma)" : used.joined(separator: " → "))")
      print("tempo: \(String(format: "%.0f", Date().timeIntervalSince(started))) s")
      print("origem mostrada ao usuário: \(outcome.provenance.note)")
      print("")
      print(outcome.answer.isEmpty ? "(sem resposta — laço esgotado)" : outcome.answer)
    } catch {
      print("FALHOU: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    }
  }

  static func webCheck(query: String) async {
    let client = EvieWebClient()
    print("buscando: \(query)")
    let started = Date()

    let results: [EvieSearchResult]
    do {
      results = try await client.search(query)
    } catch {
      print("BUSCA falhou: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
      return
    }
    print(String(format: "BUSCA: %d resultados em %.1f s", results.count, Date().timeIntervalSince(started)))
    for result in results.prefix(3) {
      print("  · \(result.title)")
      print("    \(result.url)")
    }

    guard let first = results.first else {
      return
    }
    do {
      let text = try await client.read(first.url)
      print("LER PÁGINA: \(text.count) caracteres de \(first.url)")
      print("  início: \(text.prefix(160).replacingOccurrences(of: "\n", with: " "))…")
    } catch {
      print("LER falhou: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    }

    // The guard that matters more than the feature.
    print("")
    print("endereços recusados:")
    for address in [
      "http://127.0.0.1:38433/v1/models",
      "http://localhost/admin",
      "http://192.168.1.1",
      "http://169.254.169.254/latest/meta-data/",
      "file:///etc/passwd",
      "http://10.0.0.5",
    ] {
      print("  \(EvieWebClient.validate(address) == nil ? "recusado" : "ACEITOU — BUG") \(address)")
    }
  }

  /// Compares taking a prefix of one page against selecting passages from three.
  ///
  /// Both numbers on the same question and the same network, because the claim
  /// being made — smaller *and* better — is only worth anything if it is measured.
  static func passageCheck(query: String) async {
    let client = EvieWebClient()
    print("pergunta: \(query)")
    print("")

    let searchStart = Date()
    guard let results = try? await client.search(query), let first = results.first else {
      print("busca não trouxe nada")
      return
    }
    print(String(format: "busca: %d resultados em %.1f s", results.count, Date().timeIntervalSince(searchStart)))

    // What the previous version sent.
    let oldStart = Date()
    let whole = (try? await client.read(first.url)) ?? ""
    let prefix = String(whole.prefix(3_500))
    print(
      String(
        format: "ANTES  1 página, prefixo: %d chars em %.1f s — %@",
        prefix.count, Date().timeIntervalSince(oldStart), first.url
      )
    )
    print("  começo: \(prefix.prefix(150).replacingOccurrences(of: "\n", with: " "))…")

    // What it sends now.
    let newStart = Date()
    let passages = (try? await client.gather(query, pages: 3, passages: 6)) ?? []
    let total = passages.reduce(0) { $0 + $1.text.count }
    let sources = Set(passages.map { URL(string: $0.source)?.host ?? $0.source })
    print(
      String(
        format: "DEPOIS %d trechos de %d sites: %d chars em %.1f s",
        passages.count, sources.count, total, Date().timeIntervalSince(newStart)
      )
    )
    for passage in passages.prefix(3) {
      let host = URL(string: passage.source)?.host ?? ""
      print("  [\(host)] \(passage.text.prefix(110))…")
    }
    if total > 0, prefix.count > 0 {
      print("")
      print(String(format: "prompt: %.0f%% do tamanho anterior, de %d fontes em vez de 1",
                   Double(total) / Double(prefix.count) * 100, sources.count))
    }
  }

  static func skillCheck(question: String) async {
    let store = EvieSkillStore()
    let installed = store.load()
    print("pasta: \(store.directory.path)")
    print("instaladas: \(installed.map(\.name))")

    let matched = EvieSkillLibrary.matching(question, in: installed)
    print("pergunta: \(question)")
    print("carregou: \(matched.isEmpty ? "(nenhuma)" : matched.map(\.name).joined(separator: ", "))")
    guard let guidance = EvieSkillLibrary.guidance(for: matched) else {
      print("→ nenhuma habilidade se aplica; ela responde normalmente")
      return
    }
    print("custo no prompt: \(guidance.count) caracteres")
    print("")

    let capabilities = EvieCapabilitySnapshot.textOnly
    let configuration = (try? EvieConfigurationLoader().load()) ?? EvieConfiguration()
    let started = Date()
    do {
      let outcome = try await EvieAgentLoop().run(
        messages: [
          ChatMessage(
            role: .system,
            content: EviePersona.evie.systemPrompt(capabilities: capabilities)
          ),
          ChatMessage(role: .system, content: guidance),
          ChatMessage(role: .user, content: question),
        ],
        roots: [],
        client: TurboFieldfareClient(configuration: configuration),
        emit: { _ in }
      )
      print("resposta em \(String(format: "%.0f", Date().timeIntervalSince(started))) s:")
      print(outcome.answer)
    } catch {
      print("FALHOU: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    }
  }

  static func ragCheck(folder: URL, questions: [String]) async {
    let root = EvieFileRoot(displayName: folder.lastPathComponent, path: folder.path)
    let embedder = EvieContextualEmbedder()
    print("busca por significado disponível: \(embedder.isAvailable)")

    var started = Date()
    let passages = EvieVaultIndex.collect(from: [root])
    print(String(format: "%d passagens em %.1f s", passages.count, Date().timeIntervalSince(started)))

    started = Date()
    let vectors = passages.map { embedder.vector(for: $0.searchableText) }
    let embedded = vectors.compactMap { $0 }.count
    print(String(format: "%d vetores em %.1f s", embedded, Date().timeIntervalSince(started)))

    let retriever = EvieVaultRetriever(embedder: embedder.isAvailable ? embedder : nil)

    // The two rankers separately before the fusion, because a bad fused result
    // says nothing about which half is wrong.
    for question in questions {
      print("")
      print("=== \(question) ===")
      let terms = EvieQueryTerms.extract(from: question)
      print("termos analisados: \(terms)")
      let containing = passages.filter { passage in
        terms.contains { passage.searchableText.lowercased().contains($0) }
      }
      print("passagens contendo algum termo: \(containing.count)")

      let words = retriever.rankByWords(question, in: passages).prefix(3)
      print("só palavras:")
      for index in words {
        print("   \(passages[index].breadcrumb.prefix(70))")
      }
      let meaning = retriever.rankByMeaning(question, in: passages, vectors: vectors).prefix(3)
      print("só significado:")
      for index in meaning {
        print("   \(passages[index].breadcrumb.prefix(70))")
      }
    }

    for question in questions {
      print("")
      print("— \(question)")
      started = Date()
      let found = retriever.retrieve(question, from: passages, vectors: vectors, limit: 3)
      print(String(format: "  %d trechos em %.0f ms", found.count, Date().timeIntervalSince(started) * 1000))
      for item in found {
        let how = [
          item.matchedByWords ? "palavras" : nil,
          item.matchedByMeaning ? "significado" : nil,
        ].compactMap { $0 }.joined(separator: "+")
        print("  [\(how)] \(item.passage.breadcrumb)")
        print("     \(item.passage.text.prefix(90).replacingOccurrences(of: "\n", with: " "))…")
      }
    }
  }
}
