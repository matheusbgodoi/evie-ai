import AppKit
import EvieCore
import Foundation

/// The Mac brain, end to end and without the overlay: the launcher starts the
/// server, checks who listens, one question goes through the real client with
/// a picture, and the launcher stops it again. It costs about 8 GB for the
/// seconds it runs, and leaves nothing behind.
///
/// With `waitForIdleUnload` it does not stop the server itself: it waits for
/// the launcher's own idle timer, with the real ten-minute policy, and reports
/// when the server went away.
extension EvieDiagnostics {
  static func brainCheck(waitForIdleUnload: Bool) async {
    setvbuf(stdout, nil, _IOLBF, 0)
    let profiles = EvieConfigurationLoader().loadWithDiagnostics().loaded.profiles
    guard
      let profile = profiles.profiles.first(where: {
        if case .localOnDemand = $0.runtime { true } else { false }
      }),
      case .localOnDemand(let runtime) = profile.runtime
    else {
      print("RESULTADO: nenhum perfil roda neste Mac")
      return
    }
    print("perfil: \(profile.id) · \(profile.model)")
    print("executável: \(runtime.executable)")
    let available = EvieLocalBrainLauncher.availableMemoryBytes()
    print(String(format: "memória livre: %.2f GiB", Double(available) / Double(1 << 30)))
    print("motor de voz no ar: \(EvieVoiceEngineLauncher.isPortBound())")

    let launcher = EvieLocalBrainLauncher()
    await answerOnce(with: launcher, profile: profile, runtime: runtime, waitForIdleUnload: waitForIdleUnload)
    let stopping = ContinuousClock.now
    await launcher.stop()
    let left = EvieProcessInspector.listeningPID(onPort: runtime.port)
    print("parado em \(stopping.duration(to: .now))")
    print("depois de parar, porta \(runtime.port): \(left.map { "ocupada pelo PID \($0)" } ?? "livre")")
  }

  private static func answerOnce(
    with launcher: EvieLocalBrainLauncher,
    profile: EvieModelProfile,
    runtime: LocalRuntime,
    waitForIdleUnload: Bool
  ) async {
    do {
      let serving = try launcher.isServing(profile)
      print("já no ar antes: \(serving != nil)")
      let start = ContinuousClock.now
      let endpoint = try await launcher.ensureRunning(profile)
      print("no ar em \(start.duration(to: .now)) · \(endpoint.absoluteString)")
      print("quem escuta é o servidor configurado: \(try launcher.isServing(profile) != nil)")
      if let pid = EvieProcessInspector.listeningPID(onPort: runtime.port) {
        print("PID \(pid) · imagem \(EvieProcessInspector.executablePath(of: pid) ?? "?")")
      }

      var question = ChatMessage(role: .user, content: "Qual é a cor desta imagem? Responda com uma palavra.")
      question.images = [redSquare()]
      var served = profile.configuration
      served.endpoint = endpoint
      let client = ModelClientFactory.live.makeClient(configuration: served)
      var options = TurnOptions.chat(served)
      options.readiness = .ready
      let asked = ContinuousClock.now
      var answer = ""
      for try await event in client.stream(messages: [question], tools: [], options: options) {
        if case .responseTextDelta(let text) = event {
          answer += text
        }
      }
      print("resposta em \(asked.duration(to: .now)): \(answer.trimmingCharacters(in: .whitespacesAndNewlines))")
      if waitForIdleUnload {
        let idleSince = ContinuousClock.now
        print("esperando o desligamento por ociosidade…")
        while EvieProcessInspector.listeningPID(onPort: runtime.port) != nil,
          idleSince.duration(to: .now) < .seconds(15 * 60)
        {
          try await Task.sleep(for: .seconds(5))
        }
        print("ocioso por \(idleSince.duration(to: .now)) quando a porta ficou livre")
      }
      print("RESULTADO: ok")
    } catch {
      print("RESULTADO: falhou — \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
      print("log: \(EvieLocalBrainLauncher.logURL.path)")
    }
  }

  /// A 32×32 red PNG, drawn here so the check needs no file.
  private static func redSquare() -> EvieImagePart {
    let side = 32
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
      samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    if let pixels = bitmap.bitmapData {
      for row in 0..<side {
        for column in 0..<side {
          let offset = row * bitmap.bytesPerRow + column * 3
          pixels[offset] = 255
          pixels[offset + 1] = 0
          pixels[offset + 2] = 0
        }
      }
    }
    return EvieImagePart(
      mimeType: "image/png",
      data: bitmap.representation(using: .png, properties: [:]) ?? Data(),
      pixelSize: CGSize(width: side, height: side),
      origin: .attachment
    )
  }
}
