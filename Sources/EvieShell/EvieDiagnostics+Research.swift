import AppKit
import EvieCore

extension EvieDiagnostics {
  /// Real model transport and real pasteboard, using only synthetic pixels
  /// and a uniquely named pasteboard. Never captures the user's display.
  static func researchCheck() async {
    setvbuf(stdout, nil, _IOLBF, 0)
    NSApp.setActivationPolicy(.prohibited)
    var lines = ["Evie research: synthetic image → model → isolated clipboard"]
    defer { writeLog(lines, named: "research-check.log") }
    func report(_ line: String) {
      lines.append(line)
      print(line)
    }
    let loaded = EvieConfigurationLoader().loadWithDiagnostics().loaded
    var configuration = loaded.profiles.preferredProfile.configuration
    configuration.defaultReasoning = .off
    let client = ModelClientFactory.live.makeClient(configuration: configuration)
    report("model: \(configuration.model); reasoning: off; pixels: 900x300")
    let board = NSPasteboard(name: .init("evie-research-check-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    do {
      let image = try researchFixtureImage()
      let start = ContinuousClock.now
      let answer = try await EvieResearchAnswer.read(
        image: image, goal: "Leia a questão e responda apenas com a letra da alternativa correta.",
        client: client, readiness: .ready)
      let written = board.setString(answer, forType: .string)
      let readBack = board.string(forType: .string)
      let correct = answer.trimmingCharacters(in: .whitespacesAndNewlines) == "B"
      report("answer: \(answer); elapsed: \(start.duration(to: .now))")
      report("pasteboard roundtrip: \(written && readBack == answer)")
      report(correct && written && readBack == answer ? "RESULTADO: passou" : "RESULTADO: falhou")
    } catch { report("RESULTADO: falhou — \(error.localizedDescription)") }
  }

  private static func researchFixtureImage() throws -> EvieImagePart {
    let image = NSImage(size: NSSize(width: 900, height: 300))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 900, height: 300).fill()
    let text = """
      TESTE SINTÉTICO LOCAL — PESQUISA EVIE
      Quanto é 17 × 4?
      A) 64     B) 68     C) 72
      """
    (text as NSString).draw(
      in: NSRect(x: 35, y: 25, width: 830, height: 240),
      withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let data = bitmap.representation(using: .png, properties: [:])
    else { throw EvieResearchError.invalidAnswer }
    return EvieImagePart(
      mimeType: "image/png", data: data, pixelSize: NSSize(width: 900, height: 300),
      origin: .screenshot)
  }
}
