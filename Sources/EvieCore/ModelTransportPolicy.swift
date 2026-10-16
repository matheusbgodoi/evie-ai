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

  /// The one machine Evie talks to off this Mac unless told otherwise: the
  /// owner's RTX 3090 gateway on the owner's tailnet.
  public static let defaultRemoteHosts = ["ai-node-3090.tail6146ef.ts.net"]

  public let allowedRemoteHosts: [String]

  public init(allowedRemoteHosts: [String] = ModelTransportPolicy.defaultRemoteHosts) {
    self.allowedRemoteHosts = allowedRemoteHosts
  }

  /// - Parameter credentialHost: the host the endpoint's credential was saved
  ///   for, or `nil` when the endpoint has none.
  public func evaluate(_ url: URL, credentialHost: String?) -> Verdict {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
    else {
      return .refused("Model endpoints must use http or https.")
    }
    guard let host = url.host?.lowercased(), !host.isEmpty else {
      return .refused("The model endpoint has no host.")
    }
    guard url.user == nil, url.password == nil else {
      return .refused("The model endpoint must not carry a user or password in its URL.")
    }

    if Self.isLoopback(host) {
      return .allowed
    }
    guard scheme == "https" else {
      return .refused("Plain http is only allowed to this Mac; \(host) needs https.")
    }
    guard allows(host) else {
      return .refused("\(host) is not on the list of model hosts Evie may use.")
    }
    guard let credentialHost else {
      return .refused("\(host) needs a saved key before Evie sends it anything.")
    }
    guard credentialHost.lowercased() == host else {
      return .refused("The saved key belongs to another host, not \(host).")
    }
    return .allowed
  }

  /// Loopback by name or literal. `URL.host` drops the brackets of an IPv6
  /// literal, but both spellings are listed so the answer does not depend on
  /// which Foundation produced the URL.
  static func isLoopback(_ host: String) -> Bool {
    ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
  }

  private func allows(_ host: String) -> Bool {
    allowedRemoteHosts.contains { entry in
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
