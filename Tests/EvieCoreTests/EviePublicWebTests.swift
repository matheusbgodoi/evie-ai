import Darwin
import Foundation
import Testing

@testable import EvieCore

@Suite("Public web policy")
struct EviePublicWebTests {
  @Test("private, special-use and transition IPs never enter public web transport")
  func blockedIPs() {
    for address in [
      "0.0.0.0", "10.1.2.3", "127.0.0.2", "100.64.0.1", "100.127.255.254",
      "169.254.169.254", "172.16.0.1", "172.31.255.254", "192.168.0.1", "192.0.2.1",
      "198.18.0.1", "198.19.255.254", "198.51.100.1", "203.0.113.1", "224.0.0.1", "255.255.255.255",
      "::", "::1", "::ffff:8.8.8.8", "64:ff9b::808:808", "fc00::1", "fd00::1", "fe80::1",
      "ff02::1", "2001:db8::1", "2001::1", "2002:7f00:1::1", "3fff::1",
    ] {
      #expect(PublicWebIP(address)?.isPublic == false, "Unexpected public address: \(address)")
    }
    for address in [
      "8.8.8.8", "1.1.1.1", "93.184.216.34", "192.0.43.8", "2606:4700:4700::1111",
      "2001:4860:4860::8888",
    ] {
      #expect(PublicWebIP(address)?.isPublic == true)
    }
  }

  @Test("credentials, alternate ports, local names and noncanonical numeric hosts are refused")
  func blockedURLs() throws {
    for address in [
      "http://localhost/", "http://printer.local/", "http://metadata.google.internal/",
      "http://192.168.1.1/", "http://[::1]/", "http://[::ffff:127.0.0.1]/",
      "https://user:placeholder@example.org/", "https://example.org:8443/",
      "file:///etc/passwd", "http://2130706433/", "http://0x7f000001/", "http://0177.0.0.1/",
      "https://example.org./", "http://singlelabel/",
    ] {
      let url = try #require(URL(string: address))
      #expect(!EviePublicWebFetcher.accepts(url), "Unexpected accepted URL: \(address)")
    }
    #expect(
      EviePublicWebFetcher.accepts(URL(string: "https://developer.apple.com/documentation/")!))
  }

  @Test("DNS with any private answer is refused before transport")
  func mixedDNS() async {
    let calls = WebTransferCalls()
    let fetcher = EviePublicWebFetcher(
      resolve: { _, _ in ["8.8.8.8", "127.0.0.1"] },
      transfer: {
        await calls.record($0)
        return Self.response()
      })
    await #expect(throws: EviePublicWebError.unsafeAddress) {
      try await fetcher.text(for: URLRequest(url: URL(string: "https://public.example/")!))
    }
    #expect(await calls.count == 0)
  }

  @Test("each redirect revalidates DNS and never connects to a rebound private address")
  func redirectRebinding() async {
    let calls = WebTransferCalls()
    let fetcher = EviePublicWebFetcher(
      resolve: { host, _ in
        host == "public.example" ? ["8.8.8.8"] : ["127.0.0.1"]
      },
      transfer: {
        await calls.record($0)
        return PublicWebResponse(
          status: 302, headers: ["location": "https://rebound.example/"], body: Data())
      })
    await #expect(throws: EviePublicWebError.unsafeAddress) {
      try await fetcher.text(for: URLRequest(url: URL(string: "https://public.example/")!))
    }
    #expect(await calls.count == 1)
    #expect(await calls.firstAddresses == ["8.8.8.8"])
  }

  @Test("redirect loops stop after three hops and binary or compressed responses are rejected")
  func limits() async throws {
    let calls = WebTransferCalls()
    let looping = EviePublicWebFetcher(
      resolve: { _, _ in ["8.8.8.8"] },
      transfer: {
        await calls.record($0)
        return PublicWebResponse(status: 302, headers: ["location": "/loop"], body: Data())
      })
    let request = URLRequest(url: URL(string: "https://public.example/")!)
    await #expect(throws: EviePublicWebError.tooManyRedirects) {
      try await looping.text(for: request)
    }
    #expect(await calls.count == 4)
    for headers in [
      ["content-type": "image/png"], ["content-type": "text/html", "content-encoding": "gzip"],
    ] {
      let fetcher = EviePublicWebFetcher(
        resolve: { _, _ in ["8.8.8.8"] },
        transfer: { _ in
          PublicWebResponse(status: 200, headers: headers, body: Data([1, 2, 3]))
        })
      await #expect(throws: EviePublicWebError.unsupportedContent) {
        try await fetcher.text(for: request)
      }
    }
  }

  @Test("redirects cannot forward a POST body to another origin")
  func postRedirect() async {
    let calls = WebTransferCalls()
    let fetcher = EviePublicWebFetcher(
      resolve: { _, _ in ["8.8.8.8"] },
      transfer: {
        await calls.record($0)
        return PublicWebResponse(
          status: 307, headers: ["location": "https://other.example/"], body: Data())
      })
    var request = URLRequest(url: URL(string: "https://public.example/")!)
    request.httpMethod = "POST"
    request.httpBody = Data("q=synthetic".utf8)
    await #expect(throws: EviePublicWebError.unsafeAddress) { try await fetcher.text(for: request) }
    #expect(await calls.count == 1)
  }

  @Test("DNS cancellation discards a late OS answer without waiting for it")
  func cancelDNS() async throws {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let lookup = PublicWebDNSLookup(query: {
      started.signal()
      release.wait()
      return ["8.8.8.8"]
    })
    defer { release.signal() }
    let task = Task { try await lookup.addresses(timeout: 5) }
    let began = await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(returning: started.wait(timeout: .now() + 2) == .success)
      }
    }
    #expect(began)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test("DNS lookup has a deadline even while the OS resolver is still waiting")
  func deadlineDNS() async {
    let release = DispatchSemaphore(value: 0)
    let lookup = PublicWebDNSLookup(query: {
      release.wait()
      return ["8.8.8.8"]
    })
    defer { release.signal() }
    await #expect(throws: EviePublicWebError.timedOut) {
      try await lookup.addresses(timeout: 0.01)
    }
  }

  private static func response() -> PublicWebResponse {
    PublicWebResponse(
      status: 200, headers: ["content-type": "text/plain"], body: Data("synthetic".utf8))
  }
}

private actor WebTransferCalls {
  private var requests: [PinnedWebRequest] = []
  var count: Int { requests.count }
  var firstAddresses: [String]? { requests.first?.addresses }
  func record(_ request: PinnedWebRequest) { requests.append(request) }
}

@Suite("Public web real wire", .serialized)
struct EviePublicWebWireTests {
  @Test(
    "system curl really pins an otherwise nonexistent host and keeps cookies and credentials absent"
  )
  func pinnedWire() async throws {
    let server = try WebLoopbackServer()
    defer { server.stop() }
    var request = server.request()
    request = PinnedWebRequest(
      address: request.address, addresses: request.addresses, method: "POST",
      body: Data("q=synthetic%20test".utf8),
      userAgent: "EvieTransportTest", maximumBytes: 4_096, timeout: 3)
    let response = try await CurlWebTransport.fetch(request)
    let json = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    #expect(response.status == 200)
    #expect(json["host"] as? String == "web-fixture.invalid:\(server.port)")
    #expect(json["body"] as? String == "q=synthetic%20test")
    #expect((json["accept_encoding"] as? String)?.contains("gzip") == true)
    #expect(json["cookie"] is NSNull)
    #expect(json["authorization"] is NSNull)
    let second = try await CurlWebTransport.fetch(server.request())
    let secondJSON = try #require(JSONSerialization.jsonObject(with: second.body) as? [String: Any])
    #expect(secondJSON["cookie"] is NSNull)
  }

  @Test("a chunked response without Content-Length is stopped at the byte limit")
  func streamingLimit() async throws {
    let server = try WebLoopbackServer()
    defer { server.stop() }
    await #expect(throws: EviePublicWebError.tooLarge) {
      try await CurlWebTransport.fetch(server.request(path: "/overflow", maximumBytes: 1_024))
    }
  }

  @Test("a gzip page is decoded within the same bounded output pipeline")
  func gzipPage() async throws {
    let server = try WebLoopbackServer()
    defer { server.stop() }
    let response = try await CurlWebTransport.fetch(server.request(path: "/gzip-text"))
    let json = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    #expect(json["host"] as? String == "web-fixture.invalid:\(server.port)")
    #expect(response.headers["content-encoding"] == nil)
  }

  @Test("compressed input below the byte limit cannot expand beyond the decoded body limit")
  func gzipBomb() async throws {
    let server = try WebLoopbackServer()
    defer { server.stop() }
    await #expect(throws: EviePublicWebError.tooLarge) {
      try await CurlWebTransport.fetch(server.request(path: "/gzip-bomb", maximumBytes: 1_024))
    }
  }

  @Test("cancellation terminates a real request waiting on the server")
  func cancelWire() async throws {
    let server = try WebLoopbackServer()
    defer { server.stop() }
    let task = Task { try await CurlWebTransport.fetch(server.request(path: "/slow")) }
    try await server.waitFor(path: "/slow")
    let start = ContinuousClock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(start.duration(to: .now) < .seconds(2))
  }

  @Test("the production entry point refuses loopback before any TCP request")
  func noLoopbackAccess() async throws {
    let server = try WebLoopbackServer()
    defer { server.stop() }
    await #expect(throws: EviePublicWebError.unsafeAddress) {
      try await EviePublicWebFetcher().text(
        for: URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!))
    }
    let response = try await CurlWebTransport.fetch(server.request())
    let json = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    #expect(json["count"] as? Int == 1)
  }
}

private final class WebLoopbackServer: @unchecked Sendable {
  let port: UInt16
  private let process: Process
  private let directory: URL
  private let state: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "evie-web-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    state = directory.appendingPathComponent("state.json")
    process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    process.arguments = [
      repository.appendingPathComponent("evals/fixtures/PublicWebServer.py").path, state.path,
    ]
    process.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    var line = Data()
    while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty,
      byte != Data([10])
    {
      line.append(byte)
    }
    guard let value = UInt16(String(decoding: line, as: UTF8.self)) else {
      process.terminate()
      throw URLError(.cannotConnectToHost)
    }
    port = value
  }

  func request(path: String = "/", maximumBytes: Int = 4_096) -> PinnedWebRequest {
    PinnedWebRequest(
      address: EviePublicWebAddress(
        url: URL(string: "http://web-fixture.invalid:\(port)\(path)")!,
        host: "web-fixture.invalid", port: Int(port)),
      addresses: ["127.0.0.1"],
      method: "GET", body: nil, userAgent: "EvieTransportTest", maximumBytes: maximumBytes,
      timeout: 15)
  }

  func waitFor(path: String) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
      if let data = try? Data(contentsOf: state),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        json["path"] as? String == path
      {
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw URLError(.timedOut)
  }

  func stop() {
    if process.isRunning { process.terminate() }
    // Foundation's waitUntilExit can wait on the launching thread's dormant
    // run loop when an async test resumes on another executor thread. Reap
    // this exact child directly; ECHILD means Foundation already reaped it.
    var status: Int32 = 0
    while waitpid(process.processIdentifier, &status, 0) == -1 && errno == EINTR {}
    try? FileManager.default.removeItem(at: directory)
  }
}
