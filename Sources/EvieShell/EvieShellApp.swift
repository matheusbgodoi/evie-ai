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

    let coordinator = AppCoordinator()
    self.coordinator = coordinator
    coordinator.start()
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
    capture.onLevels = { levels in
      peak = max(peak, levels.max() ?? 0)
    }

    do {
      let format = try await capture.prepareInputFormat()
      report.append("permissão depois de pedir: \(EvieAudioCapture.currentPermission())")
      report.append(
        "formato de entrada: \(Int(format.sampleRate)) Hz, \(format.channelCount) canal(is)"
      )
      try await capture.start()
      report.append("microfone aberto: sim")
      try? await Task.sleep(for: .seconds(2))
      report.append(String(format: "pico de nível em 2 s: %.3f", Double(peak)))
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
