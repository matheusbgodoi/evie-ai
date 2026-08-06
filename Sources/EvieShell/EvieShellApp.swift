import AVFoundation
import EvieCore
import SwiftUI

@main
struct EvieShellApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    Settings {
      EmptyView()
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var coordinator: AppCoordinator?
  private var terminationTask: Task<Void, Never>?
  private var terminationPrepared = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Diagnostics that must not require launching a window. `--print-persona`
    // exists so the exact hidden instructions Evie receives can be reviewed
    // without reading them out of a running conversation.
    if CommandLine.arguments.contains("--print-persona") {
      var capabilities = EvieCapabilitySnapshot.textOnly
      capabilities.readsImagesAndDocuments = true
      if EvieAudioCapture.isBundled, #available(macOS 26, *) {
        capabilities.listensToSpeech = EvieSpeechTranscription.isSupported
      }
      print(EviePersona.evie.systemPrompt(capabilities: capabilities))
      NSApp.terminate(nil)
      return
    }

    // Reports the microphone situation without asking for anything. Deliberately
    // never calls `requestAccess`: a diagnostic must not put a consent dialog on
    // someone's screen as a side effect of being run.
    if CommandLine.arguments.contains("--audio-check") {
      let bundleIdentifier = Bundle.main.bundleIdentifier ?? "(nenhum — não empacotado)"
      let usage =
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
      print("bundle: \(bundleIdentifier)")
      print("bundlePath: \(Bundle.main.bundlePath)")
      print("NSMicrophoneUsageDescription: \(usage ?? "(ausente)")")
      print("permissão do microfone: \(EvieAudioCapture.currentPermission())")
      print("pode capturar: \(EvieAudioCapture.isBundled ? "identidade OK" : "sem identidade")")
      NSApp.terminate(nil)
      return
    }

    // Reports whether this Mac can transcribe Portuguese, and whether doing so
    // would first need a download. Opens no microphone.
    if CommandLine.arguments.contains("--speech-check") {
      Task {
        if #available(macOS 26, *) {
          let locale = Locale(identifier: "pt-BR")
          let availability = await EvieSpeechTranscription.availability(for: locale)
          print("reconhecimento disponível: \(EvieSpeechTranscription.isSupported)")
          print("pt-BR: \(availability) — \(availability.message)")
        } else {
          print("Este macOS não tem o reconhecimento de fala do sistema.")
        }
        NSApp.terminate(nil)
      }
      return
    }

    // Runs a real plan against the running model and prints each stage, because
    // the only thing worth knowing about a planner is whether the model actually
    // produces a list this parser can read.
    if let index = CommandLine.arguments.firstIndex(of: "--plan-check"),
      index + 1 < CommandLine.arguments.count
    {
      let question = CommandLine.arguments[index + 1]
      Task { @MainActor in
        await Self.runPlanCheck(question)
        NSApp.terminate(nil)
      }
      return
    }

    // Runs the update check against the real feed, and runs the signature
    // verification against real tampered copies of this very bundle. The second
    // half is the one that matters: it is the only thing standing between a
    // release feed and code executing here.
    if CommandLine.arguments.contains("--update-check") {
      Task { @MainActor in
        await Self.runUpdateCheck()
        NSApp.terminate(nil)
      }
      return
    }

    // Brings the voice engine up the way asking her to speak does, and reports
    // how long it took. The point is to prove the app can start it without the
    // shell script, which is the failure this exists for.
    if CommandLine.arguments.contains("--voice-engine-check") {
      Task { @MainActor in
        await Self.runVoiceEngineCheck()
        NSApp.terminate(nil)
      }
      return
    }

    // Speaks one sentence out loud through the whole path — synthesis, playback,
    // and metering — and reports what happened. You hear it; the file says
    // whether the level was real.
    if CommandLine.arguments.contains("--speak-check") {
      Task { @MainActor in
        await Self.runSpeakCheck()
        NSApp.terminate(nil)
      }
      return
    }

    // Drives the presentation animation through the sequence most likely to break
    // it — show, hide, and show again before the dismissal has finished — and
    // reports whether the window survived. A half-faded or ordered-out overlay is
    // the failure this guards against.
    if CommandLine.arguments.contains("--presentation-check") {
      let coordinator = AppCoordinator()
      self.coordinator = coordinator
      coordinator.start()
      Task { @MainActor in
        var report: [String] = []
        try? await Task.sleep(for: .milliseconds(400))
        report.append("depois de abrir: \(coordinator.presentationDiagnostics)")

        coordinator.diagnosticHide()
        try? await Task.sleep(for: .milliseconds(40))
        coordinator.diagnosticShow()
        try? await Task.sleep(for: .milliseconds(400))
        report.append("depois de esconder e reabrir rápido: \(coordinator.presentationDiagnostics)")

        coordinator.diagnosticHide()
        try? await Task.sleep(for: .milliseconds(400))
        report.append("depois de esconder: \(coordinator.presentationDiagnostics)")

        coordinator.diagnosticShow()
        try? await Task.sleep(for: .milliseconds(400))
        report.append("depois de reabrir: \(coordinator.presentationDiagnostics)")

        let directory = FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent("Library/Logs/Evie", isDirectory: true)
        try? FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true)
        try? report.joined(separator: "\n").appending("\n").write(
          to: directory.appendingPathComponent("presentation-check.txt"),
          atomically: true,
          encoding: .utf8
        )
        NSApp.terminate(nil)
      }
      return
    }

    // Opens the microphone for a couple of seconds through exactly the path a
    // real activation takes, and writes what happened to a file. Launch Services
    // gives no console, and this is the only way to exercise the audio tap —
    // where a main-actor closure once crashed the process — without a mouse.
    if CommandLine.arguments.contains("--voice-check") {
      Task { @MainActor in
        await Self.runVoiceCheck()
        NSApp.terminate(nil)
      }
      return
    }

    // Reads a file and prints exactly what Evie would receive. Useful on its own,
    // and the only way to check the reader without dragging something onto a
    // window.
    if let index = CommandLine.arguments.firstIndex(of: "--read"),
      index + 1 < CommandLine.arguments.count
    {
      let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
      Task {
        do {
          let pages = try await EvieDocumentReader().read(fileAt: url)
          print(pages.promptEvidence)
        } catch {
          FileHandle.standardError.write(
            Data(
              ((error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription).utf8)
          )
        }
        NSApp.terminate(nil)
      }
      return
    }

    // Runs a real agentic turn against the running model, over a folder made for
    // the occasion. The wire format was proved with a throwaway script; this is
    // the only thing that proves *this* client speaks it, which is the part that
    // would otherwise be discovered by a person asking Evie a question.
    if CommandLine.arguments.contains("--tools-check") {
      Task { @MainActor in
        await Self.runToolsCheck()
        NSApp.terminate(nil)
      }
      return
    }

    // Asks a real question of a real folder — the vault, by default — so that
    // "she can read my notes" is something demonstrated rather than claimed.
    if let index = CommandLine.arguments.firstIndex(of: "--ask-folder"),
      index + 2 < CommandLine.arguments.count
    {
      let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])
      let question = CommandLine.arguments[index + 2]
      Task { @MainActor in
        await Self.runFolderQuestion(folder: folder, question: question)
        NSApp.terminate(nil)
      }
      return
    }

    // A real agentic turn with the web switched on, so the whole path — decide to
    // search, search, open a page, answer — is demonstrated rather than assumed.
    if let index = CommandLine.arguments.firstIndex(of: "--ask-web"),
      index + 1 < CommandLine.arguments.count
    {
      let question = CommandLine.arguments[index + 1]
      Task { @MainActor in
        await Self.runWebQuestion(question)
        NSApp.terminate(nil)
      }
      return
    }

    // Exercises the voice library through the same client the settings window
    // uses. The engine's protocol was proved with a throwaway script; this is
    // what proves *this* code speaks it, which is otherwise discovered by a
    // person trying to train a voice and getting an error.
    if let index = CommandLine.arguments.firstIndex(of: "--voices-check"),
      index + 1 < CommandLine.arguments.count
    {
      let audioURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
      Task { @MainActor in
        await Self.runVoicesCheck(audioURL: audioURL)
        NSApp.terminate(nil)
      }
      return
    }

    // Proves the one part of Evie that leaves this Mac actually works, and
    // shows exactly what it sends and receives.
    if let index = CommandLine.arguments.firstIndex(of: "--web-check"),
      index + 1 < CommandLine.arguments.count
    {
      let query = CommandLine.arguments[index + 1]
      Task { @MainActor in
        await Self.runWebCheck(query: query)
        NSApp.terminate(nil)
      }
      return
    }

    // Measures the claim that selecting passages is both smaller and better than
    // taking a prefix, rather than asserting it.
    if let index = CommandLine.arguments.firstIndex(of: "--passage-check"),
      index + 1 < CommandLine.arguments.count
    {
      let query = CommandLine.arguments[index + 1]
      Task { @MainActor in
        await Self.runPassageCheck(query: query)
        NSApp.terminate(nil)
      }
      return
    }

    // Describes a real image through the real path, so "she can see" is
    // demonstrated rather than claimed.
    if let index = CommandLine.arguments.firstIndex(of: "--see"),
      index + 1 < CommandLine.arguments.count
    {
      let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
      Task { @MainActor in
        print("visão disponível: \(EvieVisionDescriber.isAvailable)")
        if let reason = EvieVisionDescriber.unavailableReason {
          print("motivo: \(reason)")
        }
        let started = Date()
        do {
          let seen = try await EvieVisionDescriber().describe(imageAt: url)
          print(String(format: "descrito em %.2f s:", Date().timeIntervalSince(started)))
          print("  \(seen)")
        } catch {
          print("falhou: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
        // And the text in it, which is the other half.
        if let pages = try? await EvieDocumentReader().read(fileAt: url) {
          let text = pages.map(\.text).joined(separator: " ").prefix(200)
          print("texto reconhecido: \(text.isEmpty ? "(nenhum)" : String(text))")
        }
        NSApp.terminate(nil)
      }
      return
    }

    // Drives the whole change path against the running model over a throwaway
    // folder: she proposes, the proposal is inspected, it is performed, and the
    // file is checked afterwards. Nothing about this is asserted from the couch.
    if CommandLine.arguments.contains("--change-check") {
      Task { @MainActor in
        await Self.runChangeCheck()
        NSApp.terminate(nil)
      }
      return
    }

    // Shows which skills a question loads, and answers it with them, so
    // "she learned it" is something seen rather than assumed.
    if let index = CommandLine.arguments.firstIndex(of: "--skill-check"),
      index + 1 < CommandLine.arguments.count
    {
      let question = CommandLine.arguments[index + 1]
      Task { @MainActor in
        await Self.runSkillCheck(question: question)
        NSApp.terminate(nil)
      }
      return
    }

    // Builds the index over a real folder and asks it real questions, including
    // the paraphrase kind that substring search cannot answer at all.
    if let index = CommandLine.arguments.firstIndex(of: "--rag-check"),
      index + 1 < CommandLine.arguments.count
    {
      let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])
      let questions = Array(CommandLine.arguments.dropFirst(index + 2))
      Task { @MainActor in
        await Self.runRagCheck(folder: folder, questions: questions)
        NSApp.terminate(nil)
      }
      return
    }

    let coordinator = AppCoordinator()
    self.coordinator = coordinator
    coordinator.start()
  }

  static func runRagCheck(folder: URL, questions: [String]) async {
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

  static func runSkillCheck(question: String) async {
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

  static func runChangeCheck() async {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("evie-change-check", isDirectory: true)
    try? FileManager.default.removeItem(at: directory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? Data("rascunho velho\n".utf8)
      .write(to: directory.appendingPathComponent("rascunho-antigo.txt"))
    try? Data("importante\n".utf8)
      .write(to: directory.appendingPathComponent("contrato.pdf.txt"))
    defer { try? FileManager.default.removeItem(at: directory) }

    let roots = [
      EvieFileRoot(id: "chk00001", displayName: "Pasta de teste", path: directory.path)
    ]
    var capabilities = EvieCapabilitySnapshot.textOnly
    capabilities.readsLocalFiles = true
    let configuration = (try? EvieConfigurationLoader().load()) ?? EvieConfiguration()

    let question = "manda o rascunho-antigo.txt pro lixo"
    print("pergunta: \(question)")
    print("a mensagem dele pede mudança: \(EvieChangeIntent.isPresent(in: question))")

    do {
      let outcome = try await EvieAgentLoop(offersChanges: true).run(
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
          if case .status(let message) = event { print("   · \(message)") }
        }
      )

      guard let change = outcome.changeProposals.first else {
        print("NÃO propôs mudança nenhuma. Resposta: \(outcome.answer.prefix(200))")
        return
      }
      print("propôs: \(change.describe(rootName: "Pasta de teste"))")
      print("  identidade capturada: \(change.precondition != nil)")
      print("  arquivo ainda lá antes de aprovar: "
        + "\(FileManager.default.fileExists(atPath: directory.appendingPathComponent("rascunho-antigo.txt").path))")

      let receipt = try EvieFileWriter().perform(change, in: roots[0])
      print("aprovado e feito: \(receipt.change.kind.rawValue)")
      print("  arquivo sumiu da pasta: "
        + "\(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("rascunho-antigo.txt").path))")
      print("  o outro arquivo continua: "
        + "\(FileManager.default.fileExists(atPath: directory.appendingPathComponent("contrato.pdf.txt").path))")
    } catch {
      print("FALHOU: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    }
  }

  static func runWebQuestion(_ question: String) async {
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

  /// Compares taking a prefix of one page against selecting passages from three.
  ///
  /// Both numbers on the same question and the same network, because the claim
  /// being made — smaller *and* better — is only worth anything if it is measured.
  static func runPassageCheck(query: String) async {
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

  static func runWebCheck(query: String) async {
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

  @MainActor
  static func runPlanCheck(_ question: String) async {
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

  @MainActor
  static func runUpdateCheck() async {
    let running = Bundle.main.bundleURL
    print("rodando: \(running.path)")
    print("versão instalada: \(EvieUpdater.installedVersion?.description ?? "nenhuma")")
    print("é um bundle: \(EvieUpdater.isRunningFromBundle)")

    switch (try? EvieBundleSignature.leafCertificateHash(ofBundleAt: running)) ?? nil {
    case .some(let hash):
      print("certificado desta cópia: \(hash.prefix(8).map { String(format: "%02x", $0) }.joined())…")
    case .none:
      print("certificado desta cópia: NENHUM (ad-hoc) — nenhuma atualização seria aceita")
    }

    // Against tampered copies of this exact bundle, so the table in
    // EvieBundleSignature is a measurement rather than a claim.
    print("")
    print("verificação contra cópias adulteradas:")
    let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("evie-update-check-\(ProcessInfo.processInfo.processIdentifier)")
    defer { try? FileManager.default.removeItem(at: workspace) }
    try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

    for (label, tamper) in Self.tamperings {
      let copy = workspace.appendingPathComponent("\(label).app")
      try? FileManager.default.removeItem(at: copy)
      guard (try? FileManager.default.copyItem(at: running, to: copy)) != nil else {
        print("  \(label): não consegui copiar")
        continue
      }
      tamper(copy)
      do {
        try EvieBundleSignature.verify(candidateAt: copy, matchesSignerOf: running)
        print("  \(label): ACEITOU — investigar")
      } catch {
        print("  \(label): recusado — \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
      }
    }
    // The control: an untouched copy must be accepted, or the check is only
    // refusing everything and proving nothing.
    let clean = workspace.appendingPathComponent("intacta.app")
    try? FileManager.default.copyItem(at: running, to: clean)
    do {
      try EvieBundleSignature.verify(candidateAt: clean, matchesSignerOf: running)
      print("  cópia intacta: aceita (controle)")
    } catch {
      print("  cópia intacta: RECUSADA — \(error)")
    }

    print("")
    let updater = EvieUpdater()
    await updater.check(force: true)
    print("feed: \(updater.state)")
  }

  /// The ways a downloaded bundle could have been interfered with.
  private static var tamperings: [(String, (URL) -> Void)] {
    [
      (
        "info-plist-alterado",
        { copy in
          let plist = copy.appendingPathComponent("Contents/Info.plist")
          guard var text = try? String(contentsOf: plist, encoding: .utf8) else { return }
          text = text.replacingOccurrences(of: "<string>APPL</string>", with: "<string>APPX</string>")
          try? text.write(to: plist, atomically: true, encoding: .utf8)
        }
      ),
      (
        "recurso-adicionado",
        { copy in
          let extra = copy.appendingPathComponent("Contents/Resources/injetado.sh")
          try? "malicioso".write(to: extra, atomically: true, encoding: .utf8)
        }
      ),
      (
        "reassinado-adhoc",
        { copy in
          let sign = Process()
          sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
          sign.arguments = ["--force", "--deep", "-s", "-", copy.path]
          sign.standardError = FileHandle.nullDevice
          sign.standardOutput = FileHandle.nullDevice
          try? sign.run()
          sign.waitUntilExit()
        }
      ),
    ]
  }

  @MainActor
  static func runVoiceEngineCheck() async {
    print("instalado: \(EvieVoiceEngineLauncher.isInstalled)")
    print("porta \(EvieOmniVoiceClient.defaultPort) ocupada: \(EvieVoiceEngineLauncher.isPortBound())")

    let client = EvieOmniVoiceClient()
    print("já no ar: \(await client.isHealthy())")

    let start = Date()
    do {
      try await EvieVoiceEngineLauncher().ensureRunning(client: client)
      let elapsed = Date().timeIntervalSince(start)
      let profiles = await client.voices()
      print(String(format: "RESULTADO: no ar em %.2f s, %d perfil(is)", elapsed, profiles.count))
      for profile in profiles {
        print("  \(profile.name) [\(profile.id)]")
      }
    } catch {
      print("RESULTADO: falhou — \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
      print("log: \(EvieVoiceEngineLauncher.logURL.path)")
    }
  }

  static func runVoicesCheck(audioURL: URL) async {
    let engine = EvieOmniVoiceClient()

    guard await engine.isHealthy() else {
      print("motor de voz fora do ar — rode Scripts/evie-voice start")
      return
    }

    let before = await engine.voices()
    print("vozes treinadas antes: \(before.map(\.name))")
    print("vozes do sistema: \(EvieSpeechOutput.availableVoices().count)")

    let identifier: String
    do {
      identifier = try await engine.createProfile(
        name: "TESTE-descartavel",
        audioURL: audioURL,
        referenceText: "Esta é uma gravação de referência para testar o treino de voz da Evie."
      )
      print("TREINAR: ok, id = \(identifier)")
    } catch {
      print("TREINAR falhou: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
      return
    }

    let during = await engine.voices()
    print("aparece na lista: \(during.contains { $0.id == identifier })")

    // And it can actually speak, which is the only thing that makes a trained
    // voice worth having.
    do {
      let buffer = try await engine.synthesise("Pronta.", profileID: identifier)
      let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
      print(String(format: "FALAR: ok, %.2f s de áudio", seconds))
    } catch {
      print("FALAR falhou: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    }

    do {
      try await engine.deleteProfile(id: identifier)
      print("APAGAR: ok")
    } catch {
      print("APAGAR falhou: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    }

    let after = await engine.voices()
    print("vozes depois: \(after.map(\.name))")
    print("suas vozes intactas: \(before.map(\.id).sorted() == after.map(\.id).sorted())")
  }

  /// One question against one folder, with the tools, printing what she used.
  static func runFolderQuestion(folder: URL, question: String) async {
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

  static func runToolsCheck() async {
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

    let text = report.joined(separator: "\n")
    print(text)
    let logs = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Evie", isDirectory: true)
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    try? Data(text.utf8).write(to: logs.appendingPathComponent("tools-check.txt"))
  }

  static func runSpeakCheck() async {
    var report: [String] = []
    let voices = EvieSpeechOutput.availableVoices()
    report.append("vozes pt-BR instaladas: \(voices.count)")
    for voice in voices.prefix(4) {
      report.append("  \(voice.displayName)  [\(voice.id)]")
    }

    // The natural Siri voices appear in the system list. Whether a third-party
    // app can actually instantiate one is a different question, and the answer
    // decides how good Evie can sound without a cloned voice.
    for identifier in ["com.apple.siri.natural.Sandra", "com.apple.siri.natural.Nando"] {
      let resolved = AVSpeechSynthesisVoice(identifier: identifier) != nil
      report.append("\(identifier): \(resolved ? "utilizável" : "INDISPONÍVEL para este app")")
    }

    let output = EvieSpeechOutput()
    var peak: CGFloat = 0
    var updates = 0
    var started = false
    output.onStarted = { started = true }
    output.onLevels = { levels in
      peak = max(peak, levels.max() ?? 0)
      updates += 1
    }

    let start = Date()
    output.speak(
      EvieRichText(
        "Oi, Matheus. Agora eu falo. Interrompa quando quiser, é só falar por cima."
      ),
      using: .system(identifier: voices.first?.id),
      rate: 0.5
    )
    while !started, Date().timeIntervalSince(start) < 20 {
      try? await Task.sleep(for: .milliseconds(50))
    }
    report.append(
      String(
        format: "áudio começou depois de %.2f s: %@",
        Date().timeIntervalSince(start), started ? "sim" : "NÃO"))

    while output.isSpeaking, Date().timeIntervalSince(start) < 40 {
      try? await Task.sleep(for: .milliseconds(100))
    }
    report.append(String(format: "duração: %.2f s", Date().timeIntervalSince(start)))
    report.append(String(format: "pico de nível de saída: %.3f", Double(peak)))
    report.append("amostras de nível publicadas: \(updates)")
    report.append(
      peak > 0.05
        ? "RESULTADO (voz do sistema): falou, e o anel tem nível real."
        : "RESULTADO (voz do sistema): terminou sem nível audível — investigar."
    )

    // Now the cloned engine, if it is running.
    let cloned = EvieOmniVoiceClient()
    report.append("")
    if await cloned.isHealthy() {
      let profiles = await cloned.voices()
      report.append("motor de voz clonada: no ar, \(profiles.count) perfil(is)")
      for profile in profiles {
        report.append("  \(profile.name) [\(profile.id)] \(profile.language)")
      }
      // Prefer a profile whose reference text is stored: without it the backend
      // transcribes the reference with Whisper on first use, which is a one-time
      // cost measured at over thirty seconds.
      let chosen =
        profiles.first { $0.name.localizedCaseInsensitiveContains("matheus") }
        ?? profiles.first
      if let profile = chosen {
        var clonedPeak: CGFloat = 0
        var clonedStarted = false
        let output = EvieSpeechOutput()
        output.onLevels = { levels in clonedPeak = max(clonedPeak, levels.max() ?? 0) }
        output.onStarted = { clonedStarted = true }
        let clonedStart = Date()
        output.speak(
          EvieRichText("Oi Matheus. Agora sou eu falando com a sua voz clonada."),
          using: .cloned(profileID: profile.id),
          rate: 0.5
        )
        while !clonedStarted, Date().timeIntervalSince(clonedStart) < 90 {
          try? await Task.sleep(for: .milliseconds(100))
        }
        report.append(
          String(
            format: "primeiro áudio clonado em %.2f s: %@",
            Date().timeIntervalSince(clonedStart), clonedStarted ? "sim" : "NÃO"))
        while output.isSpeaking, Date().timeIntervalSince(clonedStart) < 120 {
          try? await Task.sleep(for: .milliseconds(100))
        }
        report.append(String(format: "pico de nível clonado: %.3f", Double(clonedPeak)))
      }
    } else {
      report.append("motor de voz clonada: desligado (Scripts/evie-voice start)")
    }

    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Evie", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? report.joined(separator: "\n").appending("\n").write(
      to: directory.appendingPathComponent("speak-check.txt"),
      atomically: true,
      encoding: .utf8
    )
  }

  /// Result goes to a file because a bundle launched by Launch Services has no
  /// standard output anyone can read.
  static func runVoiceCheck() async {
    var report = ["bundle: \(Bundle.main.bundleIdentifier ?? "(nenhum)")"]
    report.append("permissão antes de pedir: \(EvieAudioCapture.currentPermission())")

    let capture = EvieAudioCapture()
    var peak: CGFloat = 0
    // Every published level, so a gate that misbehaves can be read rather than
    // guessed at. Theorising about this cost two wrong fixes.
    var trace: [CGFloat] = []
    capture.onLevels = { levels in
      peak = max(peak, levels.max() ?? 0)
      if let latest = levels.last {
        trace.append(latest)
      }
    }

    do {
      let format = try await capture.prepareInputFormat()
      report.append("permissão depois de pedir: \(EvieAudioCapture.currentPermission())")
      report.append(
        "formato de entrada: \(Int(format.sampleRate)) Hz, \(format.channelCount) canal(is)"
      )
      // The gate's decisions are recorded, not just the peak. A capture that
      // reaches a healthy level and still never ends a turn is exactly the bug
      // the user hit, and the peak alone cannot tell the two apart.
      var ended = false
      var endedAfter: Double = 0
      let started = Date()
      capture.detectsEndOfSpeech = true
      capture.onSpeechStarted = {
        report.append(String(format: "  fala detectada em %.1f s", Date().timeIntervalSince(started)))
      }
      capture.onEndOfSpeech = {
        ended = true
        endedAfter = Date().timeIntervalSince(started)
      }

      try await capture.start()
      report.append("microfone aberto: sim")
      report.append("FALE ALGO AGORA, depois fique em silêncio.")
      for _ in 0..<40 where !ended {
        try? await Task.sleep(for: .milliseconds(250))
      }
      report.append(String(format: "pico de nível: %.3f", Double(peak)))
      report.append(String(format: "piso de ruído aprendido: %.3f", Double(capture.noiseFloor)))
      report.append(String(format: "limiar de fala: %.3f", Double(capture.speechThreshold)))
      report.append(
        ended
          ? String(format: "FIM DE FALA: detectado em %.1f s", endedAfter)
          : "FIM DE FALA: NÃO detectado em 10 s"
      )
      report.append("")
      report.append("níveis publicados (um a cada 30 ms):")
      for chunk in stride(from: 0, to: trace.count, by: 10) {
        let slice = trace[chunk..<min(chunk + 10, trace.count)]
        let stamp = String(format: "%5.1fs", Double(chunk) * 0.03)
        report.append(
          "  \(stamp)  " + slice.map { String(format: "%.3f", Double($0)) }.joined(separator: " ")
        )
      }
      capture.stop()
      report.append("microfone fechado: sim")
      report.append("RESULTADO: o caminho do áudio rodou inteiro sem derrubar o processo.")
    } catch {
      report.append(
        "FALHA: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
      )
    }

    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Evie", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? report.joined(separator: "\n").appending("\n")
      .write(
        to: directory.appendingPathComponent("voice-check.txt"),
        atomically: true,
        encoding: .utf8
      )
  }

  func applicationWillTerminate(_ notification: Notification) {
    coordinator?.stop()
    coordinator = nil
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if terminationPrepared || coordinator == nil {
      return .terminateNow
    }
    guard terminationTask == nil, let coordinator else {
      return .terminateLater
    }

    terminationTask = Task { @MainActor [weak self] in
      await coordinator.prepareForTermination()
      guard let self else { return }
      terminationPrepared = true
      terminationTask = nil
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }
}
