import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import EvieCore

@Suite("Lens image preparation")
struct EvieLensImagePreparationTests {
  private var configuration: EvieConfiguration {
    EvieConfiguration(
      endpoint: URL(string: "http://127.0.0.1:38480/v1")!,
      model: "mlx-community/LensVLM-9B-OptiQ-4bit", thinkingStyle: .topLevel)
  }

  @Test("the actual Lens request sends a small image with enough visual patches")
  func requestUpscalesSmallImage() throws {
    var question = ChatMessage(role: .user, content: "Read the attached image.")
    question.images = [try image(width: 512, height: 128)]
    let request = try OpenAICompatibleClient.makeRequest(
      messages: [question], tools: [], options: .chat(configuration), configuration: configuration,
      bearerToken: nil)
    let bodyData = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    let messages = try #require(body["messages"] as? [[String: Any]])
    let content = try #require(messages[0]["content"] as? [[String: Any]])
    let picture = try #require(content.last?["image_url"] as? [String: Any])
    let url = try #require(picture["url"] as? String)
    let bytes = try #require(Data(base64Encoded: String(url.split(separator: ",")[1])))
    let decoded = try decode(bytes)
    #expect(decoded.width == 1_536)
    #expect(decoded.height == 384)
  }

  @Test(
    "native enlargement keeps pure colors, identity, provenance and the original history",
    arguments: ["red", "green", "blue"])
  func enlargementPreservesContentAndProvenance(color: String) throws {
    let rgb: [CGFloat] = color == "red" ? [1, 0, 0] : color == "green" ? [0, 1, 0] : [0, 0, 1]
    let picture = try image(width: 32, height: 32, components: rgb + [1])
    let source = EvieImagePart(
      id: picture.id, mimeType: picture.mimeType, data: picture.data,
      pixelSize: picture.pixelSize, origin: .screenshot)
    var question = ChatMessage(role: .user, content: "Keep this question intact.")
    question.derivedFromPicture = true
    question.images = [source]
    let prepared = try EvieLensImagePreparation.prepare([question], configuration: configuration)
    let result = try #require(prepared[0].images?.first)
    #expect(prepared[0].id == question.id)
    #expect(prepared[0].content == question.content)
    #expect(prepared[0].createdAt == question.createdAt)
    #expect(prepared[0].derivedFromPicture)
    #expect(result.id == source.id)
    #expect(result.origin == .screenshot)
    #expect(result.mimeType == "image/png")
    #expect(result.pixelSize == CGSize(width: 768, height: 768))
    #expect(result.data != source.data)
    #expect(question.images?.first?.data == source.data)
    #expect(question.images?.first?.pixelSize == CGSize(width: 32, height: 32))
    let decoded = try decode(result.data)
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
      CGContext(
        data: nil, width: decoded.width, height: decoded.height, bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
    let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    let expected = rgb.map { UInt8($0 * 255) }
    let onlyExpectedColor = stride(from: 0, to: context.bytesPerRow * decoded.height, by: 4)
      .allSatisfy {
        pixels[$0] == expected[0] && pixels[$0 + 1] == expected[1] && pixels[$0 + 2] == expected[2]
      }
    #expect(
      onlyExpectedColor, "First pixel bytes: \(Array(UnsafeBufferPointer(start: pixels, count: 4)))"
    )
  }

  @Test("actual bytes decide dimensions, while other models and remote hosts remain byte-stable")
  func modelScopeAndActualDimensions() throws {
    let picture = try image(width: 32, height: 32)
    var question = ChatMessage(role: .user, content: "Picture")
    question.images = [
      EvieImagePart(
        id: picture.id, mimeType: picture.mimeType, data: picture.data,
        pixelSize: CGSize(width: 100_000, height: 100_000), origin: .attachment)
    ]
    let prepared = try EvieLensImagePreparation.prepare([question], configuration: configuration)
    #expect(prepared[0].images?.first?.pixelSize == CGSize(width: 768, height: 768))
    var otherModel = configuration
    otherModel.model = "another-model"
    var remote = configuration
    remote.endpoint = URL(string: "https://models.example.invalid/v1")!
    var otherStyle = configuration
    otherStyle.thinkingStyle = .templateKwargs
    for other in [otherModel, remote, otherStyle] {
      let untouched = try EvieLensImagePreparation.prepare([question], configuration: other)
      #expect(untouched[0].images?.first?.data == picture.data)
      #expect(untouched[0].images?.first?.pixelSize == question.images?.first?.pixelSize)
    }
  }

  @Test("large-enough images stay byte-stable and narrow images cannot exceed the output edge cap")
  func existingSizeAndEdgeCap() throws {
    var question = ChatMessage(role: .user, content: "Picture")
    let large = try image(width: 768, height: 768)
    question.images = [large]
    let untouched = try EvieLensImagePreparation.prepare([question], configuration: configuration)
    #expect(untouched[0].images?.first?.data == large.data)
    question.images = [try image(width: 4_096, height: 1)]
    let bounded = try EvieLensImagePreparation.prepare([question], configuration: configuration)
    let decoded = try decode(#require(bounded[0].images?.first?.data))
    #expect(decoded.width <= 4_096 && decoded.height == 1)
  }

  @Test("invalid image bytes fail legibly and oversized inputs are refused before decoding")
  func invalidAndOversizedBytes() throws {
    var question = ChatMessage(role: .user, content: "Picture")
    question.images = [
      EvieImagePart(
        mimeType: "image/png", data: Data([1, 2, 3]), pixelSize: CGSize(width: 32, height: 32),
        origin: .attachment)
    ]
    do {
      _ = try EvieLensImagePreparation.prepare([question], configuration: configuration)
      Issue.record("Invalid image bytes must not silently disappear from the request.")
    } catch ModelClientError.requestEncoding(let reason) {
      #expect(!reason.isEmpty)
    }
    question.images = [
      EvieImagePart(
        mimeType: "image/png", data: Data(count: 20 * 1_024 * 1_024 + 1),
        pixelSize: CGSize(width: 32, height: 32), origin: .attachment)
    ]
    #expect(throws: ModelClientError.requestTooLarge) {
      try EvieLensImagePreparation.prepare([question], configuration: configuration)
    }
  }

  private func image(width: Int, height: Int, components: [CGFloat] = [1, 0, 0, 1]) throws
    -> EvieImagePart
  {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(try #require(CGColor(colorSpace: space, components: components)))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let bitmap = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, bitmap, nil)
    #expect(CGImageDestinationFinalize(destination))
    return EvieImagePart(
      mimeType: "image/png", data: data as Data,
      pixelSize: CGSize(width: width, height: height), origin: .attachment)
  }

  private func decode(_ data: Data) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
  }
}
