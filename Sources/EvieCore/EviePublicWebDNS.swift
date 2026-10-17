import Darwin
import Foundation

enum PublicWebDNS {
  static func resolve(_ host: String, timeout: TimeInterval) async throws -> [String] {
    try Task.checkCancellation()
    if let literal = PublicWebIP(host) { return [literal.text] }
    return try await PublicWebDNSLookup(query: { try query(host) }).addresses(timeout: timeout)
  }

  private static func query(_ host: String) throws -> [String] {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = IPPROTO_TCP
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
      throw EviePublicWebError.network
    }
    defer { freeaddrinfo(first) }
    var addresses = Set<String>()
    var current: UnsafeMutablePointer<addrinfo>? = first
    while let entry = current {
      let info = entry.pointee
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if let address = info.ai_addr,
        getnameinfo(
          address, info.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
      {
        addresses.insert(
          String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
      }
      current = info.ai_next
    }
    guard !addresses.isEmpty else { throw EviePublicWebError.network }
    return addresses.sorted()
  }
}

/// getaddrinfo itself is owned by the OS resolver. A cancellation or deadline
/// releases the caller immediately; a late OS reply is discarded and can never
/// start an HTTP connection. There is no repeating resolver task or cache.
final class PublicWebDNSLookup: @unchecked Sendable {
  private let query: @Sendable () throws -> [String]
  private let lock = NSLock()
  private var outcome: Result<[String], any Error>?
  private var continuation: CheckedContinuation<[String], any Error>?

  init(query: @escaping @Sendable () throws -> [String]) { self.query = query }

  func addresses(timeout: TimeInterval) async throws -> [String] {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let early: Result<[String], any Error>? = lock.withLock {
          if let outcome { return outcome }
          self.continuation = continuation
          return nil as Result<[String], any Error>?
        }
        if let early {
          continuation.resume(with: early)
          return
        }
        DispatchQueue.global(qos: .utility).async { [self] in
          guard lock.withLock({ outcome == nil }) else { return }
          finish(Result { try query() })
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
          self?.finish(.failure(EviePublicWebError.timedOut))
        }
      }
    } onCancel: {
      self.finish(.failure(CancellationError()))
    }
  }

  private func finish(_ result: Result<[String], any Error>) {
    let waiting = lock.withLock {
      guard outcome == nil else { return nil as CheckedContinuation<[String], any Error>? }
      outcome = result
      let waiting = continuation
      continuation = nil
      return waiting
    }
    waiting?.resume(with: result)
  }
}
