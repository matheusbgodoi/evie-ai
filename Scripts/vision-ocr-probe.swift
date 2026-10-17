import CoreGraphics
import CoreML
import CoreText
import Foundation
import Vision

/// Synthetic, standalone runtime diagnostic; no files or user content are read.
@main
struct VisionOCRProbe {
  struct Result: Codable {
    var route: String
    var succeeded: Bool
    var matchesAll: Bool
    var lines: Int
    var minimumConfidence: Float?
    var cpuStages: Int
    var seconds: Double
    var error: String?
  }

  static func image() throws -> CGImage {
    guard
      let context = CGContext(
        data: nil, width: 1500, height: 500,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw Failure.image }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1500, height: 500))
    let lines = [
      "Relatório de agosto", "Observações: coração, informação, exceção.",
      "Total: R$ 1.234,56 em 05/08/2026",
    ]
    for (index, text) in lines.enumerated() {
      let attributed = NSAttributedString(
        string: text,
        attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
            "Helvetica" as CFString, 42, nil),
          NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
            gray: 0, alpha: 1),
        ])
      context.textPosition = CGPoint(x: 35, y: 380 - index * 100)
      CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
    guard let image = context.makeImage() else { throw Failure.image }
    return image
  }

  static func main() async throws {
    let image = try image()
    let needles = ["Relatório", "coração", "informação", "exceção", "1.234,56"]
    for route in ["modern-cpu", "legacy-3-cpu", "legacy-3-auto", "legacy-2-cpu"] {
      let start = Date()
      var result = Result(
        route: route, succeeded: false, matchesAll: false,
        lines: 0, cpuStages: 0, seconds: 0)
      do {
        let lines: [(String, Float)]
        if route == "modern-cpu" {
          var request = RecognizeTextRequest()
          request.recognitionLevel = .accurate
          request.recognitionLanguages = [
            Locale.Language(identifier: "pt-BR"), Locale.Language(identifier: "en-US"),
          ]
          request.minimumTextHeightFraction = 0
          for (stage, devices) in request.supportedComputeStageDevices {
            guard
              let cpu = devices.first(where: {
                if case .cpu = $0 { return true }
                return false
              })
            else { throw Failure.cpu }
            request.setComputeDevice(cpu, for: stage)
            result.cpuStages += 1
          }
          lines = try await request.perform(on: image).compactMap { observation in
            observation.topCandidates(1).first.map { ($0.string, $0.confidence) }
          }
        } else {
          let request = VNRecognizeTextRequest()
          request.revision = route.contains("-2-") ? 2 : VNRecognizeTextRequestRevision3
          request.recognitionLevel = .accurate
          request.recognitionLanguages = ["pt-BR", "en-US"]
          request.usesLanguageCorrection = true
          request.minimumTextHeight = 0
          if route.hasSuffix("cpu") {
            for (stage, devices) in try request.supportedComputeStageDevices {
              guard
                let cpu = devices.first(where: {
                  if case .cpu = $0 { return true }
                  return false
                })
              else { throw Failure.cpu }
              request.setComputeDevice(cpu, for: stage)
              result.cpuStages += 1
            }
          }
          try VNImageRequestHandler(cgImage: image).perform([request])
          lines = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { ($0.string, $0.confidence) }
          }
        }
        let text = lines.map(\.0).joined(separator: "\n")
        result.succeeded = true
        result.matchesAll = needles.allSatisfy { text.contains($0) }
        result.lines = lines.count
        result.minimumConfidence = lines.map(\.1).min()
      } catch { result.error = String(reflecting: error) }
      result.seconds = Date().timeIntervalSince(start)
      print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
    }
  }
  enum Failure: Error { case image, cpu }
}
