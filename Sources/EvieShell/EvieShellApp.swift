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

    let coordinator = AppCoordinator()
    self.coordinator = coordinator
    coordinator.start()
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
