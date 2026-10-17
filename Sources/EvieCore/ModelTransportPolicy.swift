import Foundation

/// Decides whether Evie may send a conversation to a model endpoint at all.
///
/// A conversation carries the person's files, mail and screen, so the question
/// is not "is this a valid URL" but "is this one of the machines she said she
/// owns". The rules, in the order they are checked:
///
/// - only `http` and `https`, and never a URL with a user or password in it;
/// - plain `http` only to loopback, where nothing crosses a wire;
/// - anywhere else, `https`, to a host that **exactly** matches the allowlist;
/// - and a remote host must come with a credential saved for that same host, so
///   a key saved for the PC cannot be replayed to whatever an edited endpoint
///   now names.
///
/// One wildcard form is accepted: `*.<tailnet>.ts.net`, which admits a single
/// label inside that one tailnet. Anything wider never matches — in particular
/// `*.ts.net`, because Tailscale Funnel publishes strangers' machines under that
/// suffix, and a suffix match there would trust anyone with an account.
///
/// This deliberately does not reuse `EvieWebClient.validate`. That check exists
/// to keep web fetches off private address space, and 100.64.0.0/10 — where a
/// tailnet lives — is exactly the carrier-grade NAT range it refuses.
public struct ModelTransportPolicy: Sendable, Equatable {
  public enum Verdict: Sendable, Equatable {
    case allowed
    case refused(String)
  }

  /// Reserved documentation host. Live clients trust only the user's saved
  /// configuration; no owner's private connection ships in the application.
  public static let defaultRemoteHosts = ["models.example.invalid"]

  public let allowedRemoteHosts: [String]
  public let trustedConfigurationURL: URL?

  public init(
    allowedRemoteHosts: [String] = ModelTransportPolicy.defaultRemoteHosts,
    trustedConfigurationURL: URL? = nil
  ) {
    self.allowedRemoteHosts = allowedRemoteHosts
    self.trustedConfigurationURL = trustedConfigurationURL
  }

  /// The local configuration is written by Settings, never by model tools.
  /// Reading it at the request boundary applies saved host changes immediately.
  /// Missing or malformed files grant nothing; credentials remain host-bound.
  private var configuredRemoteHosts: [String] {
    guard let trustedConfigurationURL,
      let data = try? Data(contentsOf: trustedConfigurationURL),
      let document = try? JSONDecoder().decode(TrustedDocument.self, from: data)
    else { return [] }
    return document.profiles.compactMap { profile in
      guard profile.endpoint.scheme?.lowercased() == "https",
        profile.endpoint.user == nil, profile.endpoint.password == nil
      else { return nil }
      return profile.endpoint.host?.lowercased()
    }
  }

  private struct TrustedDocument: Decodable {
    struct Profile: Decodable { let endpoint: URL }
    let profiles: [Profile]
  }

  /// - Parameter credentialHost: the host the endpoint's credential was saved
  ///   for, or `nil` when the endpoint has none.
  public func evaluate(_ url: URL, credentialHost: String?) -> Verdict {
    refusal(of: url, credentialHost: credentialHost).map { .refused($0.reason) } ?? .allowed
  }

  /// Why `url` is refused, or `nil` when it is allowed: the same rules as
  /// `evaluate`, as a value, so Settings can say it in Portuguese while the
  /// client's error and the logs keep the sentence they always had.
  public func refusal(of url: URL, credentialHost: String?) -> Refusal? {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
    else {
      return .unsupportedScheme
    }
    guard let host = url.host?.lowercased(), !host.isEmpty else {
      return .missingHost
    }
    guard url.user == nil, url.password == nil else {
      return .userOrPasswordInURL
    }

    if Self.isLoopback(host) {
      return nil
    }
    guard scheme == "https" else {
      return .plainHTTPOffLoopback(host: host)
    }
    guard allows(host) else {
      return .hostNotAllowed(host: host)
    }
    guard let credentialHost else {
      return .noCredential(host: host)
    }
    guard credentialHost.lowercased() == host else {
      return .credentialForAnotherHost(host: host)
    }
    return nil
  }

  /// The rule an endpoint broke, in the order they are checked.
  public enum Refusal: Sendable, Equatable {
    case unsupportedScheme
    case missingHost
    case userOrPasswordInURL
    case plainHTTPOffLoopback(host: String)
    case hostNotAllowed(host: String)
    case noCredential(host: String)
    case credentialForAnotherHost(host: String)

    /// The sentence the client's `transportRefused` error carries.
    public var reason: String {
      switch self {
      case .unsupportedScheme:
        "Model endpoints must use http or https."
      case .missingHost:
        "The model endpoint has no host."
      case .userOrPasswordInURL:
        "The model endpoint must not carry a user or password in its URL."
      case .plainHTTPOffLoopback(let host):
        "Plain http is only allowed to this Mac; \(host) needs https."
      case .hostNotAllowed(let host):
        "\(host) is not on the list of model hosts Evie may use."
      case .noCredential(let host):
        "\(host) needs a saved key before Evie sends it anything."
      case .credentialForAnotherHost(let host):
        "The saved key belongs to another host, not \(host)."
      }
    }

    /// The same rule as Settings says it, under the endpoint field.
    public var explanation: String {
      switch self {
      case .unsupportedScheme:
        "O endereço precisa começar com http:// ou https://."
      case .missingHost:
        "O endereço não tem um servidor."
      case .userOrPasswordInURL:
        "O endereço não pode levar usuário ou senha."
      case .plainHTTPOffLoopback(let host):
        "\(host) precisa de https: http só vale para este Mac."
      case .hostNotAllowed(let host):
        "\(host) não está na lista de servidores que a Evie pode usar."
      case .noCredential(let host):
        "\(host) precisa de uma chave antes de a Evie mandar qualquer coisa."
      case .credentialForAnotherHost(let host):
        "A chave salva é de outro servidor, não de \(host)."
      }
    }
  }

  /// Loopback by name or literal. `URL.host` drops the brackets of an IPv6
  /// literal, but both spellings are listed so the answer does not depend on
  /// which Foundation produced the URL.
  static func isLoopback(_ host: String) -> Bool {
    ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
  }

  private func allows(_ host: String) -> Bool {
    (allowedRemoteHosts + configuredRemoteHosts).contains { entry in
      let entry = entry.lowercased()
      guard entry.hasPrefix("*.") else {
        return entry == host
      }
      return Self.matchesTailnetWildcard(host, suffix: String(entry.dropFirst(2)))
    }
  }

  /// `*.<tailnet>.ts.net` admits exactly one label in front of the tailnet. Any
  /// other wildcard — `*.ts.net`, `*`, `*.example.com` — never matches.
  private static func matchesTailnetWildcard(_ host: String, suffix: String) -> Bool {
    let suffixLabels = suffix.split(separator: ".", omittingEmptySubsequences: false)
    guard suffixLabels.count == 3,
      suffixLabels[1] == "ts",
      suffixLabels[2] == "net",
      !suffixLabels[0].isEmpty
    else {
      return false
    }
    guard host.hasSuffix("." + suffix) else { return false }
    let label = host.dropLast(suffix.count + 1)
    return !label.isEmpty && !label.contains(".")
  }
}
