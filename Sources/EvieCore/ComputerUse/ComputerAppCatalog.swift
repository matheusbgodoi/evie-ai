import Foundation

/// The applications installed on this Mac, as `open_app` looks a name up.
///
/// The shell reads the application folders into entries — each with the
/// name the Finder shows ("Notas") and the others it goes by (its bundle
/// name, "Notes", and its file name) — and this matches the model's name
/// against them ignoring case, accents and a trailing ".app". The match is
/// whole: "Note" finds nothing, so the model cannot reach an app by a prefix
/// the person never said. What it returns is launched by bundle id, never by
/// name (ADR 0016), and the policy checks that id against the denylist first.
public struct ComputerAppCatalog: ComputerAppResolving {
  public let apps: [ResolvedApp]

  /// `apps` in order of preference: when two share a name, the first wins.
  public init(apps: [ResolvedApp]) {
    self.apps = apps
  }

  public func resolve(name: String) -> ResolvedApp? {
    let wanted = Self.key(name)
    guard !wanted.isEmpty else {
      return nil
    }
    return apps.first { Self.key($0.displayName) == wanted }
      ?? apps.first { $0.otherNames.contains { Self.key($0) == wanted } }
  }

  static func key(_ name: String) -> String {
    var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased().hasSuffix(".app") {
      trimmed.removeLast(4)
    }
    return ComputerActionPolicy.fold(trimmed).trimmingCharacters(in: .whitespaces)
  }
}
