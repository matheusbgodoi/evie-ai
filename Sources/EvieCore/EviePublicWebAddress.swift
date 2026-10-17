import Darwin
import Foundation

/// Public-web policy is deliberately independent from the model transport,
/// which may reach the owner's private machines under a different authority.
struct EviePublicWebAddress: Sendable {
  let url: URL
  let host: String
  let port: Int

  init(_ url: URL) throws {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
      components.user == nil, components.password == nil,
      let rawHost = components.host?.lowercased(), !rawHost.isEmpty,
      !url.absoluteString.contains("\\"),
      !url.absoluteString.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      })
    else { throw EviePublicWebError.unsafeAddress }
    let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let port = components.port ?? (scheme == "https" ? 443 : 80)
    guard !host.isEmpty, !host.contains("%"), !host.hasPrefix("."), !host.hasSuffix("."),
      port == (scheme == "https" ? 443 : 80),
      !["localhost", "local", "internal", "home", "lan"].contains(host),
      ![".localhost", ".local", ".internal", ".home", ".lan"].contains(where: host.hasSuffix)
    else { throw EviePublicWebError.unsafeAddress }
    if let literal = PublicWebIP(host) {
      guard literal.isPublic else { throw EviePublicWebError.unsafeAddress }
    } else {
      guard host.contains("."), host.utf8.count <= 253,
        !host.split(separator: ".").allSatisfy({ label in
          label.allSatisfy(\.isNumber)
            || (label.hasPrefix("0x") && label.dropFirst(2).allSatisfy(\.isHexDigit))
        }),
        host.utf8.allSatisfy({
          (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46
        })
      else { throw EviePublicWebError.unsafeAddress }
    }
    components.scheme = scheme
    // Serialize the same canonical host used by --resolve. Encoded or
    // differently cased authorities must never miss the pinned DNS entry.
    components.host = rawHost
    components.fragment = nil
    guard let normalized = components.url else { throw EviePublicWebError.unsafeAddress }
    self.init(url: normalized, host: host, port: port)
  }

  /// Internal transport data, not an authorization token. Every public fetch
  /// enters through the validating initializer above. Wire tests construct
  /// this shape directly to reach only their isolated loopback server.
  init(url: URL, host: String, port: Int) {
    self.url = url
    self.host = host
    self.port = port
  }
}

/// A conservative allowlist of globally routable unicast address space.
/// IPv4-mapped IPv6, transition mechanisms and special-use ranges are refused.
struct PublicWebIP: Sendable {
  let text: String
  private let bytes: [UInt8]

  init?(_ text: String) {
    var ipv4 = in_addr()
    var ipv6 = in6_addr()
    if inet_pton(AF_INET, text, &ipv4) == 1 {
      let numericBytes = withUnsafeBytes(of: &ipv4) { Array($0) }
      // Darwin accepts leading-zero octets as decimal; curl may interpret
      // those as octal. Only one canonical spelling can reach the wire.
      guard text == numericBytes.map(String.init).joined(separator: ".") else { return nil }
      bytes = numericBytes
    } else if inet_pton(AF_INET6, text, &ipv6) == 1 {
      bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
    } else {
      return nil
    }
    self.text = text
  }

  var isPublic: Bool {
    if bytes.count == 4 {
      let a = bytes[0]
      let b = bytes[1]
      let c = bytes[2]
      guard a != 0, a != 10, a != 127, a < 224,
        !(a == 100 && (64...127).contains(b)),
        !(a == 169 && b == 254), !(a == 172 && (16...31).contains(b)),
        !(a == 192 && ((b == 0 && (c == 0 || c == 2)) || b == 168)),
        !(a == 192 && b == 88 && c == 99),
        !(a == 198 && (b == 18 || b == 19)),
        !(a == 198 && b == 51 && c == 100),
        !(a == 203 && b == 0 && c == 113)
      else { return false }
      return true
    }
    // Only 2000::/3, excluding IETF assignments, documentation and 6to4.
    guard bytes[0] & 0xE0 == 0x20,
      !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] < 0x02),
      !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0D && bytes[3] == 0xB8),
      !(bytes[0] == 0x20 && bytes[1] == 0x02),
      !(bytes[0] == 0x3F && bytes[1] == 0xFF && bytes[2] < 0x10)
    else { return false }
    return true
  }

  var curlAddress: String { bytes.count == 16 ? "[\(text)]" : text }
}
