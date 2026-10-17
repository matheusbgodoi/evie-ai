import Darwin
import Foundation

/// A per-request system transport: no shell, curlrc, proxy, cookie jar, disk
/// cache or inherited environment. --resolve pins the validated IPs while
/// retaining the URL hostname for TLS SNI and certificate verification.
enum CurlWebTransport {
  static let maximumHeaderBytes = 65_536

  static func fetch(_ request: PinnedWebRequest) async throws -> PublicWebResponse {
    let transfer = CurlWebTransfer(request: request)
    let data = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
          continuation.resume(with: Result { try transfer.run() })
        }
      }
    } onCancel: {
      transfer.stop(.cancelled)
    }
    try Task.checkCancellation()
    return try parse(data, maximumBytes: request.maximumBytes)
  }

  static func parse(_ data: Data, maximumBytes: Int) throws -> PublicWebResponse {
    let delimiter = Data("\r\n\r\n".utf8)
    var remainder = data
    var totalHeaders = 0
    while let range = remainder.range(of: delimiter) {
      let headerBytes = remainder[..<range.lowerBound]
      totalHeaders += headerBytes.count + 4
      guard totalHeaders <= maximumHeaderBytes,
        let text = String(data: headerBytes, encoding: .isoLatin1)
      else { throw EviePublicWebError.invalidResponse }
      let lines = text.components(separatedBy: "\r\n")
      guard let line = lines.first, line.hasPrefix("HTTP/"),
        let status = line.split(separator: " ").dropFirst().first.flatMap({ Int($0) })
      else { throw EviePublicWebError.invalidResponse }
      var headers: [String: String] = [:]
      for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { throw EviePublicWebError.invalidResponse }
        let name = line[..<colon].lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if headers[name] != nil, ["location", "content-type", "content-encoding"].contains(name) {
          throw EviePublicWebError.invalidResponse
        }
        headers[name] = value
      }
      remainder = Data(remainder[range.upperBound...])
      if (100...199).contains(status) {
        guard status != 101 else { throw EviePublicWebError.invalidResponse }
        continue
      }
      guard remainder.count <= maximumBytes else { throw EviePublicWebError.tooLarge }
      // --compressed has already decoded the bytes written to stdout. Do not
      // hand consumers a wire encoding that no longer describes this body.
      headers.removeValue(forKey: "content-encoding")
      return PublicWebResponse(status: status, headers: headers, body: remainder)
    }
    throw EviePublicWebError.invalidResponse
  }

  static func bodyOffset(in data: Data) -> Int? {
    let delimiter = Data("\r\n\r\n".utf8)
    var start = data.startIndex
    while let range = data.range(of: delimiter, in: start..<data.endIndex) {
      let header = String(decoding: data[start..<range.lowerBound], as: UTF8.self)
      guard let first = header.components(separatedBy: "\r\n").first,
        first.hasPrefix("HTTP/"),
        let status = first.split(separator: " ").dropFirst().first.flatMap({ Int($0) })
      else { return nil }
      if !(100...199).contains(status) { return range.upperBound }
      start = range.upperBound
    }
    return nil
  }
}

private final class CurlWebTransfer: @unchecked Sendable {
  enum StopReason { case cancelled, tooLarge }
  private let request: PinnedWebRequest
  private let process = Process()
  private let lock = NSLock()
  private var launched = false
  private var finished = false
  private var reason: StopReason?

  init(request: PinnedWebRequest) { self.request = request }

  func run() throws -> Data {
    let output = Pipe()
    let input = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = ["--disable", "--config", "-"]
    process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
    process.currentDirectoryURL = URL(fileURLWithPath: "/")
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = input
    try lock.withLock {
      guard reason == nil else { throw CancellationError() }
      try process.run()
      launched = true
    }
    defer {
      try? input.fileHandleForWriting.close()
      try? output.fileHandleForReading.close()
      process.waitUntilExit()
      lock.withLock { finished = true }
    }
    do {
      try input.fileHandleForWriting.write(contentsOf: configuration())
      try input.fileHandleForWriting.close()
    } catch {
      process.terminate()
      throw EviePublicWebError.network
    }
    let limit = request.maximumBytes + CurlWebTransport.maximumHeaderBytes
    var data = Data()
    var bodyOffset: Int?
    while let chunk = try output.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
      guard data.count <= limit - chunk.count else {
        stop(.tooLarge)
        break
      }
      data.append(chunk)
      if bodyOffset == nil { bodyOffset = CurlWebTransport.bodyOffset(in: data) }
      if let bodyOffset {
        if bodyOffset > CurlWebTransport.maximumHeaderBytes
          || data.count - bodyOffset > request.maximumBytes
        {
          stop(.tooLarge)
          break
        }
      } else if data.count > CurlWebTransport.maximumHeaderBytes {
        stop(.tooLarge)
        break
      }
    }
    process.waitUntilExit()
    let stopped = lock.withLock { reason }
    if stopped == .cancelled { throw CancellationError() }
    if stopped == .tooLarge || process.terminationStatus == 63 { throw EviePublicWebError.tooLarge }
    if process.terminationStatus == 28 { throw EviePublicWebError.timedOut }
    guard process.terminationStatus == 0 else { throw EviePublicWebError.network }
    return data
  }

  func stop(_ reason: StopReason) {
    lock.withLock {
      guard !finished, self.reason == nil else { return }
      self.reason = reason
      if launched, process.isRunning { process.terminate() }
    }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self else { return }
      self.lock.withLock {
        if self.launched, !self.finished, self.process.isRunning {
          _ = Darwin.kill(self.process.processIdentifier, SIGKILL)
        }
      }
    }
  }

  private func configuration() throws -> Data {
    func quoted(_ value: String) -> String {
      "\""
        + value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\t", with: "\\t") + "\""
    }
    var lines = [
      "silent", "show-error", "include", "globoff", "http1.1", "compressed",
      "proxy = \"\"", "noproxy = \"*\"", "proto = \"=http,https\"",
      "max-redirs = 0", "max-filesize = \(request.maximumBytes)",
      "max-time = \(request.timeout)", "connect-timeout = \(min(5, request.timeout))",
      "url = \(quoted(request.address.url.absoluteString))",
      "user-agent = \(quoted(request.userAgent))", "request = \(quoted(request.method))",
    ]
    if PublicWebIP(request.address.host) == nil {
      let pinned = request.addresses.compactMap { PublicWebIP($0)?.curlAddress }.joined(
        separator: ",")
      guard !pinned.isEmpty else { throw EviePublicWebError.unsafeAddress }
      lines.append(
        "resolve = \(quoted("\(request.address.host):\(request.address.port):\(pinned)"))")
    }
    if let body = request.body {
      guard let value = String(data: body, encoding: .utf8), !value.contains("\0") else {
        throw EviePublicWebError.unsafeAddress
      }
      lines.append("header = \"Content-Type: application/x-www-form-urlencoded\"")
      lines.append("data-binary = \(quoted(value))")
    }
    return Data((lines.joined(separator: "\n") + "\n").utf8)
  }
}
