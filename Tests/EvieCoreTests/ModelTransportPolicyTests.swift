import Foundation
import Testing

@testable import EvieCore

@Suite("Model transport policy")
struct ModelTransportPolicyTests {
  private let pcHost = "ai-node-3090.tail6146ef.ts.net"
  private let policy = ModelTransportPolicy()

  @Test("plain http to loopback is allowed without a credential")
  func loopbackHTTP() {
    for address in [
      "http://127.0.0.1:38433/v1",
      "http://localhost:38480/v1",
      "http://[::1]:38480/v1",
    ] {
      #expect(policy.evaluate(URL(string: address)!, credentialHost: nil) == .allowed)
    }
  }

  @Test("plain http to the PC is refused even with its credential")
  func remoteHTTP() {
    let verdict = policy.evaluate(
      URL(string: "http://\(pcHost)/v1")!,
      credentialHost: pcHost
    )

    #expect(verdict.isRefused)
  }

  @Test("https to the PC with a credential bound to it is allowed")
  func remoteHTTPSWithBoundCredential() {
    let verdict = policy.evaluate(
      URL(string: "https://\(pcHost)/v1")!,
      credentialHost: pcHost
    )

    #expect(verdict == .allowed)
  }

  @Test("a host that is not on the allowlist is refused")
  func unlistedHost() {
    let verdict = policy.evaluate(
      URL(string: "https://evil.example/v1")!,
      credentialHost: "evil.example"
    )

    #expect(verdict.isRefused)
  }

  @Test("another tailnet's host is refused: ts.net is not a trust boundary")
  func suffixHole() {
    // Funnel publishes strangers' machines under ts.net, so a suffix match on
    // it would trust anyone with a Tailscale account.
    let verdict = policy.evaluate(
      URL(string: "https://someone.ts.net/v1")!,
      credentialHost: "someone.ts.net"
    )

    #expect(verdict.isRefused)
  }

  @Test("an allowlisted host without a credential is refused")
  func allowlistedWithoutCredential() {
    let verdict = policy.evaluate(
      URL(string: "https://\(pcHost)/v1")!,
      credentialHost: nil
    )

    #expect(verdict.isRefused)
  }

  @Test("a credential bound to another host is refused")
  func credentialForAnotherHost() {
    let verdict = policy.evaluate(
      URL(string: "https://\(pcHost)/v1")!,
      credentialHost: "other-node.tail6146ef.ts.net"
    )

    #expect(verdict.isRefused)
  }

  @Test("host comparison ignores case, as DNS does")
  func caseInsensitiveHost() {
    let verdict = policy.evaluate(
      URL(string: "https://AI-Node-3090.tail6146ef.ts.net/v1")!,
      credentialHost: pcHost
    )

    #expect(verdict == .allowed)
  }

  @Test("the tailnet wildcard admits one label of that tailnet and nothing wider")
  func tailnetWildcard() {
    let wildcard = ModelTransportPolicy(allowedRemoteHosts: ["*.tail6146ef.ts.net"])

    #expect(
      wildcard.evaluate(
        URL(string: "https://laptop.tail6146ef.ts.net/v1")!,
        credentialHost: "laptop.tail6146ef.ts.net"
      ) == .allowed
    )
    #expect(
      wildcard.evaluate(
        URL(string: "https://a.b.tail6146ef.ts.net/v1")!,
        credentialHost: "a.b.tail6146ef.ts.net"
      ).isRefused
    )
    #expect(
      wildcard.evaluate(
        URL(string: "https://tail6146ef.ts.net/v1")!,
        credentialHost: "tail6146ef.ts.net"
      ).isRefused
    )
    #expect(
      wildcard.evaluate(
        URL(string: "https://laptop.othernet.ts.net/v1")!,
        credentialHost: "laptop.othernet.ts.net"
      ).isRefused
    )
  }

  @Test("a wildcard wider than one tailnet never matches")
  func overbroadWildcards() {
    for entry in ["*.ts.net", "*", "*.net", "*.example.com"] {
      let wide = ModelTransportPolicy(allowedRemoteHosts: [entry])
      #expect(
        wide.evaluate(
          URL(string: "https://someone.ts.net/v1")!,
          credentialHost: "someone.ts.net"
        ).isRefused,
        "\(entry) must not admit a stranger's host"
      )
      #expect(
        wide.evaluate(
          URL(string: "https://api.example.com/v1")!,
          credentialHost: "api.example.com"
        ).isRefused,
        "\(entry) must not admit an arbitrary host"
      )
    }
  }

  @Test("credentials embedded in the URL are refused")
  func userInfoInURL() {
    let verdict = policy.evaluate(
      URL(string: "https://user:secret@\(pcHost)/v1")!,
      credentialHost: pcHost
    )

    #expect(verdict.isRefused)
  }

  @Test("schemes other than http and https are refused")
  func otherSchemes() {
    #expect(
      policy.evaluate(URL(string: "ftp://127.0.0.1/v1")!, credentialHost: nil).isRefused
    )
    #expect(
      policy.evaluate(URL(fileURLWithPath: "/tmp/socket"), credentialHost: nil).isRefused
    )
  }

  @Test("the default allowlist is exactly the PC gateway")
  func defaultAllowlist() {
    #expect(policy.allowedRemoteHosts == [pcHost])
  }
}

extension ModelTransportPolicy.Verdict {
  fileprivate var isRefused: Bool {
    if case .refused = self { return true }
    return false
  }
}
