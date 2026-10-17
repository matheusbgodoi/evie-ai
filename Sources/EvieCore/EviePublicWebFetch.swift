import Foundation

public enum EviePublicWebError: Error, Equatable, Sendable, LocalizedError {
  case unsafeAddress, network, tooLarge, timedOut, tooManyRedirects, unsupportedContent,
    invalidResponse
  case rejected(Int)

  public var errorDescription: String? {
    switch self {
    case .unsafeAddress: "O endereço não é uma página pública permitida."
    case .network: "Não consegui alcançar a internet agora."
    case .tooLarge: "A página ultrapassa o limite de download permitido."
    case .timedOut: "A página demorou além do limite permitido."
    case .tooManyRedirects: "A página redirecionou vezes demais."
    case .unsupportedContent: "Essa página não veio como texto que eu consiga ler."
    case .invalidResponse: "O site não devolveu uma resposta HTTP válida."
    case .rejected(let code): "O site respondeu com um erro (HTTP \(code))."
    }
  }
}

struct PinnedWebRequest: Sendable {
  let address: EviePublicWebAddress
  let addresses: [String]
  let method: String
  let body: Data?
  let userAgent: String
  let maximumBytes: Int
  let timeout: TimeInterval
}

struct PublicWebResponse: Sendable {
  let status: Int
  let headers: [String: String]
  let body: Data
}

/// Each hop resolves and validates DNS, then pins the approved addresses in
/// a short-lived HTTP transport. No private address can be reached by rebinding.
public struct EviePublicWebFetcher: Sendable {
  private let resolve: @Sendable (String, TimeInterval) async throws -> [String]
  private let transfer: @Sendable (PinnedWebRequest) async throws -> PublicWebResponse

  public init() {
    resolve = PublicWebDNS.resolve
    transfer = CurlWebTransport.fetch
  }

  init(
    resolve: @escaping @Sendable (String, TimeInterval) async throws -> [String],
    transfer: @escaping @Sendable (PinnedWebRequest) async throws -> PublicWebResponse
  ) {
    self.resolve = resolve
    self.transfer = transfer
  }

  public static func accepts(_ url: URL) -> Bool { (try? EviePublicWebAddress(url)) != nil }

  public func text(
    for request: URLRequest, maximumBytes: Int = 4 * 1_024 * 1_024, timeout: TimeInterval = 20
  ) async throws -> String {
    guard let url = request.url, maximumBytes > 0, maximumBytes <= 4 * 1_024 * 1_024,
      timeout > 0, timeout.isFinite
    else { throw EviePublicWebError.unsafeAddress }
    var address = try EviePublicWebAddress(url)
    var method = request.httpMethod ?? "GET"
    var body = request.httpBody
    guard ["GET", "POST"].contains(method), (body?.count ?? 0) <= 16_384,
      method != "GET" || body == nil
    else { throw EviePublicWebError.unsafeAddress }
    let userAgent = request.value(forHTTPHeaderField: "User-Agent") ?? "Evie/2"
    guard !userAgent.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      throw EviePublicWebError.unsafeAddress
    }
    let deadline = ContinuousClock.now + .seconds(timeout)
    for hop in 0...3 {
      try Task.checkCancellation()
      let dnsBudget = Self.remaining(until: deadline)
      guard dnsBudget > 0 else { throw EviePublicWebError.timedOut }
      let addresses = try await resolve(address.host, min(5, dnsBudget))
      try Task.checkCancellation()
      guard !addresses.isEmpty, addresses.count <= 32,
        addresses.allSatisfy({ PublicWebIP($0)?.isPublic == true })
      else { throw EviePublicWebError.unsafeAddress }
      let seconds = Self.remaining(until: deadline)
      guard seconds > 0 else { throw EviePublicWebError.timedOut }
      let response = try await transfer(
        PinnedWebRequest(
          address: address, addresses: addresses, method: method, body: body, userAgent: userAgent,
          maximumBytes: maximumBytes, timeout: seconds))
      try Task.checkCancellation()
      if [301, 302, 303, 307, 308].contains(response.status) {
        guard hop < 3 else { throw EviePublicWebError.tooManyRedirects }
        guard let location = response.headers["location"],
          let next = URL(string: location, relativeTo: address.url)?.absoluteURL
        else { throw EviePublicWebError.invalidResponse }
        let redirected = try EviePublicWebAddress(next)
        if method == "POST" {
          if [301, 302, 303].contains(response.status) {
            method = "GET"
            body = nil
          } else if redirected.host != address.host || redirected.port != address.port {
            throw EviePublicWebError.unsafeAddress
          }
        }
        address = redirected
        continue
      }
      guard (200...299).contains(response.status) else {
        throw EviePublicWebError.rejected(response.status)
      }
      let type =
        response.headers["content-type"]?.lowercased().split(separator: ";").first.map(String.init)
        ?? ""
      guard
        type.hasPrefix("text/")
          || ["application/xhtml+xml", "application/json", "application/xml"].contains(type),
        response.headers["content-encoding"].map({ $0.lowercased() == "identity" }) ?? true
      else { throw EviePublicWebError.unsupportedContent }
      guard response.body.count <= maximumBytes else { throw EviePublicWebError.tooLarge }
      guard
        let text = String(data: response.body, encoding: .utf8)
          ?? String(data: response.body, encoding: .isoLatin1)
      else { throw EviePublicWebError.unsupportedContent }
      return text
    }
    throw EviePublicWebError.tooManyRedirects
  }

  private static func remaining(until deadline: ContinuousClock.Instant) -> TimeInterval {
    let remaining = ContinuousClock.now.duration(to: deadline).components
    return Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
  }
}
