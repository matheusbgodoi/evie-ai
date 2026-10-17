import AppKit
import Darwin
import EvieCore
import Foundation

/// Tests synthetic color and OCR through the real Mac brain/client. Refuses a
/// preexisting listener; after its own run, verifies both process exit and a
/// free port. Only the diagnostic report remains on disk.
///
/// `waitForIdleUnload` additionally requires the real ten-minute idle policy to
/// stop the process before the final cleanup, within a fifteen-minute deadline.
extension EvieDiagnostics {
  static func brainCheck(waitForIdleUnload: Bool) async {
    setvbuf(stdout, nil, _IOLBF, 0)
    var lines = ["Evie local brain: synthetic color + OCR + owned-process shutdown"]
    func report(_ line: String) {
      lines.append(line)
      print(line)
    }
    defer { writeLog(lines, named: "brain-check.log") }
    let profiles = EvieConfigurationLoader().loadWithDiagnostics().loaded.profiles
    guard
      let profile = profiles.profiles.first(where: {
        if case .localOnDemand = $0.runtime { true } else { false }
      }),
      case .localOnDemand(let runtime) = profile.runtime
    else {
      report("RESULTADO: falhou — nenhum perfil roda neste Mac.")
      return
    }
    // Never adopt or stop a server that existed before this diagnostic. Even
    // an authenticated matching listener may belong to the person's live turn.
    guard EvieProcessInspector.listeningPID(onPort: runtime.port) == nil else {
      report("RESULTADO: falhou — já existe um servidor nesta porta; ele foi preservado.")
      return
    }
    report("perfil: \(profile.id) · \(profile.model)")
    let available = EvieLocalBrainLauncher.availableMemoryBytes()
    report(String(format: "memória livre: %.2f GiB", Double(available) / Double(1 << 30)))
    report("motor de voz no ar: \(EvieVoiceEngineLauncher.isPortBound())")

    let launcher = EvieLocalBrainLauncher()
    var ownedPID: pid_t?
    var colorCorrect = false
    var textCorrect = false
    var idleUnloaded = !waitForIdleUnload
    do {
      let start = ContinuousClock.now
      let endpoint = try await launcher.ensureRunning(profile)
      guard let pid = EvieProcessInspector.listeningPID(onPort: runtime.port) else {
        throw BrainCheckFailure("O servidor iniciado não está escutando.")
      }
      ownedPID = pid
      report("no ar em \(start.duration(to: .now))")
      guard try await launcher.isServing(profile) != nil else {
        throw BrainCheckFailure("O servidor iniciado não serve o perfil configurado.")
      }
      var served = profile.configuration
      served.endpoint = endpoint
      let client = ModelClientFactory.live.makeClient(configuration: served)
      let asked = ContinuousClock.now
      let answer = try await readComplete(
        image: redSquare(), goal: "Qual é a cor desta imagem? Responda com uma palavra.",
        client: client)
      let normalizedColor = answer.lowercased().trimmingCharacters(
        in: .whitespacesAndNewlines.union(.punctuationCharacters))
      colorCorrect = ["vermelho", "red"].contains(normalizedColor)
      report(
        "cor sintética: \(colorCorrect ? "correta" : "incorreta") em \(asked.duration(to: .now))")
      let readback = try await readComplete(
        image: captionImage(),
        goal: "Transcreva somente o código impresso nesta imagem, sem explicações.", client: client)
      textCorrect = readback.filter { $0.isLetter || $0.isNumber }.uppercased() == "ZEBRA4817"
      report("leitura do código sintético: \(textCorrect ? "correta" : "incorreta")")
      if waitForIdleUnload {
        launcher.noteUse()
        let idleSince = ContinuousClock.now
        report("esperando o desligamento por ociosidade…")
        while !processIsGone(pid), idleSince.duration(to: .now) < .seconds(15 * 60) {
          try await Task.sleep(for: .seconds(5))
        }
        idleUnloaded =
          processIsGone(pid)
          && EvieProcessInspector.listeningPID(onPort: runtime.port) == nil
        report("idleUnloaded: \(idleUnloaded); espera: \(idleSince.duration(to: .now))")
      }
    } catch {
      report("falha: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
    }
    let stopping = ContinuousClock.now
    await launcher.stop()
    // Foundation reaps its terminated child on the run loop. The shutdown
    // inspector can already see an exited process before kill(pid, 0) reports
    // ESRCH, so allow that notification to run without accepting a zombie.
    if let ownedPID {
      let reaping = ContinuousClock.now
      while !processIsGone(ownedPID), reaping.duration(to: .now) < .seconds(5) {
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
    let portFree = EvieProcessInspector.listeningPID(onPort: runtime.port) == nil
    let processStopped = ownedPID.map(processIsGone) ?? false
    report("parado em \(stopping.duration(to: .now))")
    report("visionColor: \(colorCorrect)")
    report("visionText: \(textCorrect)")
    report("ownedProcessStopped: \(processStopped)")
    report("portFree: \(portFree)")
    if waitForIdleUnload { report("idleUnloaded: \(idleUnloaded)") }
    let passed = colorCorrect && textCorrect && processStopped && portFree && idleUnloaded
    report("RESULTADO: \(passed ? "passou" : "falhou")")
  }

  private struct BrainCheckFailure: LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
  }

  private static func processIsGone(_ pid: pid_t) -> Bool {
    kill(pid, 0) == -1 && errno == ESRCH
  }

  /// A plausible text delta alone is never a successful visual answer.
  private static func readComplete(
    image: EvieImagePart, goal: String, client: any AgentClient
  ) async throws -> String {
    var question = ChatMessage(role: .user, content: goal)
    question.images = [image]
    question.derivedFromPicture = true
    var options = TurnOptions.chat(client.configuration)
    options.readiness = .ready
    var answer: String?
    for try await event in client.stream(messages: [question], tools: [], options: options) {
      try Task.checkCancellation()
      switch event {
      case .completed(let message, let reason):
        guard answer == nil, reason == "stop", message.role == .assistant,
          message.toolCalls?.isEmpty != false
        else { throw BrainCheckFailure("A resposta visual não terminou de forma completa.") }
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 16_000 else {
          throw BrainCheckFailure("A resposta visual está vazia ou excede o limite.")
        }
        answer = text
      case .failed:
        throw BrainCheckFailure("O modelo informou falha ao interpretar a imagem.")
      default: break
      }
    }
    try Task.checkCancellation()
    guard let answer else { throw BrainCheckFailure("A resposta visual não foi concluída.") }
    return answer
  }

  /// The answer exists only in pixels; the text prompt never supplies it.
  private static func captionImage() -> EvieImagePart {
    let size = CGSize(width: 512, height: 128)
    let image = NSImage(size: size, flipped: false) { bounds in
      NSColor.white.setFill()
      bounds.fill()
      NSAttributedString(
        string: "ZEBRA4817",
        attributes: [
          .font: NSFont.boldSystemFont(ofSize: 58), .foregroundColor: NSColor.black,
        ]
      ).draw(at: CGPoint(x: 60, y: 30))
      return true
    }
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return EvieImagePart(
      mimeType: "image/png", data: bitmap.representation(using: .png, properties: [:])!,
      pixelSize: size, origin: .attachment)
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
