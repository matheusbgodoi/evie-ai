import Foundation
import Testing

@testable import EvieCore

/// Proves the streaming client cannot mangle text at a chunk boundary.
///
/// A reported answer came back with `cumpre` written as `cumkl`, and the first
/// suspect for that shape of damage is a transport that decodes each network
/// chunk on its own: a two-byte `é` or a four-byte emoji sliced down the middle
/// decodes to a replacement character, and everything after it shifts. These
/// tests deliver the same stream cut at every single byte offset — including
/// offsets that fall inside a multi-byte character, inside a `data:` line, and
/// between the CR and the LF of a CRLF terminator — and demand the reassembled
/// text back byte for byte.
///
/// One honest limit: `URLSession` is free to recombine the body fragments a
/// `URLProtocol` hands it before `AsyncBytes` yields them, so these tests
/// corroborate rather than isolate. The structural reason the client is immune
/// is in `consumeStream`: it iterates the response one `UInt8` at a time, so a
/// network boundary has no representation it could act on, and the single place
/// bytes become a `String` is `SSELineBuffer.finishLine`, which runs on a whole
/// line. There is no code path that decodes a partial character.
@Suite("TurboFieldfare stream chunk boundaries")
struct TurboFieldfareStreamSplitTests {
  @Test("text survives a cut at every byte offset, LF framing")
  func everyOffsetLineFeed() async throws {
    try await sweepEveryOffset(basePort: SplitStubURLProtocol.lineFeedBasePort)
  }

  @Test("text survives a cut at every byte offset, CRLF framing")
  func everyOffsetCarriageReturn() async throws {
    try await sweepEveryOffset(
      basePort: SplitStubURLProtocol.carriageReturnBasePort
    )
  }

  @Test("text survives the body arriving one byte at a time")
  func maximalFragmentation() async throws {
    let text = try await streamedText(port: SplitStubURLProtocol.perBytePort)

    #expect(text == SplitStreamFixture.expectedText)
  }
}

extension TurboFieldfareStreamSplitTests {
  /// One request per possible cut. The offsets are byte offsets into the encoded
  /// body, not character offsets, which is the whole point: a character offset
  /// could never land inside `é`.
  fileprivate func sweepEveryOffset(basePort: Int) async throws {
    let byteCount = SplitStubURLProtocol.bodyByteCount(basePort: basePort)
    let session = makeSession()

    for offset in 0...byteCount {
      let text = try await streamedText(
        port: basePort + offset,
        session: session
      )
      #expect(
        text == SplitStreamFixture.expectedText,
        "A cut after byte \(offset) changed the text."
      )
      // A String comparison would already catch a replacement character, but
      // compare the UTF-8 too so a canonically-equivalent-but-different
      // encoding cannot pass either.
      #expect(Array(text.utf8) == Array(SplitStreamFixture.expectedText.utf8))
    }
  }

  fileprivate func streamedText(
    port: Int,
    session: URLSession? = nil
  ) async throws -> String {
    let client = TurboFieldfareClient(
      configuration: EvieConfiguration(
        endpoint: URL(string: "http://127.0.0.1:\(port)/v1")!,
        maxCompletionTokens: 128,
        requestTimeout: 5
      ),
      session: session ?? makeSession()
    )

    var deltas = ""
    var completed: String?
    for try await event in client.stream(
      messages: [ChatMessage(role: .user, content: "Explique o esquema")]
    ) {
      switch event {
      case .responseTextDelta(let delta):
        deltas += delta
      case .completed(let message, _):
        completed = message.content
      default:
        continue
      }
    }

    // The saved conversation is built from the completed message, so that is the
    // string under test; the deltas are checked against it because the overlay
    // shows those live and the two must not drift apart.
    let content = try #require(completed)
    #expect(deltas == content)
    return content
  }

  fileprivate func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SplitStubURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}

/// The stream under test.
///
/// Written in Portuguese on purpose: `é`, `ç`, `ã`, `õ` and the em dash are two
/// and three bytes wide, and the flag is a pair of four-byte scalars, so a cut
/// lands inside a character far more often than it would in English. `cumpre` is
/// deliberately straddling two deltas, which is how the reported word would have
/// arrived.
private enum SplitStreamFixture {
  static let deltas = [
    "Como é um esquema",
    " para um artigo, ele cum",
    "pre o papel de representar",
    " a arquitetura do sistema.",
    " Acentuação — ãõêç 🇧🇷",
  ]

  static var expectedText: String {
    deltas.joined()
  }

  static func body(lineEnding: String) -> Data {
    var events = deltas.enumerated().map { index, delta in
      let reason = index == deltas.count - 1 ? "\"stop\"" : "null"
      return #"data: {"choices":[{"delta":{"content":"\#(delta)"},"finish_reason":\#(reason)}]}"#
    }
    events.append("data: [DONE]")
    return Data(
      events.map { $0 + lineEnding + lineEnding }.joined().utf8
    )
  }
}

/// Serves the fixture with the split described by the port.
///
/// The port carries the cut offset because `URLProtocol` gets no other channel
/// from the test, and the client is only willing to talk to loopback.
private final class SplitStubURLProtocol: URLProtocol, @unchecked Sendable {
  static let lineFeedBasePort = 19_000
  static let carriageReturnBasePort = 21_000
  static let perBytePort = 23_000

  static func lineEnding(basePort: Int) -> String {
    basePort == carriageReturnBasePort ? "\r\n" : "\n"
  }

  static func bodyByteCount(basePort: Int) -> Int {
    SplitStreamFixture.body(lineEnding: lineEnding(basePort: basePort)).count
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "127.0.0.1"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let port = request.url?.port else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }

    let fragments: [Data]
    if port == Self.perBytePort {
      fragments = SplitStreamFixture.body(lineEnding: "\n").map { Data([$0]) }
    } else {
      let basePort =
        port >= Self.carriageReturnBasePort
        ? Self.carriageReturnBasePort
        : Self.lineFeedBasePort
      let body = SplitStreamFixture.body(
        lineEnding: Self.lineEnding(basePort: basePort)
      )
      fragments = Self.split(body, at: port - basePort)
    }

    guard
      let url = request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/event-stream"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }

    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    for fragment in fragments {
      client?.urlProtocol(self, didLoad: fragment)
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  /// Empty fragments are dropped rather than sent: a zero-length body chunk says
  /// nothing about boundary handling and some URL loading paths treat it as EOF.
  private static func split(_ body: Data, at offset: Int) -> [Data] {
    let bytes = Array(body)
    let cut = min(max(offset, 0), bytes.count)
    return [Data(bytes[..<cut]), Data(bytes[cut...])].filter { !$0.isEmpty }
  }
}
