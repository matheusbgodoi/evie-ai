import AppKit
import EvieCore

/// Opens an application for `open_app`, by the bundle id the policy resolved
/// and checked — never by the name the model wrote (ADR 0016).
@MainActor
final class AppLauncher: ComputerAppLaunching {
  enum LaunchError: LocalizedError {
    case notInstalled

    var errorDescription: String? {
      "Esse app não está instalado neste Mac."
    }
  }

  func open(bundleID: String, url: URL?) async throws -> ComputerAppIdentity {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      throw LaunchError.notInstalled
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    let app: NSRunningApplication
    if let url {
      app = try await NSWorkspace.shared.open(
        [url], withApplicationAt: appURL, configuration: configuration)
    } else {
      app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }
    return ComputerAppIdentity(
      bundleID: app.bundleIdentifier,
      name: app.localizedName ?? app.bundleIdentifier ?? bundleID,
      processID: app.processIdentifier
    )
  }
}

/// The applications on this Mac, for the policy's name lookup.
///
/// Read from the application folders one level deep (so `Utilities` is
/// included), the Finder, and whatever regular app is running from
/// elsewhere. Each entry carries the name the Finder shows ("Notas"), which
/// wins, and the bundle's own names ("Notes") and file name as others. Read
/// once per session: installing an app mid-session is rare, and a lookup
/// must not walk the disk inside the policy's synchronous check.
enum InstalledApps {
  static let folders = [
    "/Applications", "/Applications/Utilities", "/System/Applications",
    "/System/Applications/Utilities", NSHomeDirectory() + "/Applications",
  ]
  static let extras = ["/System/Library/CoreServices/Finder.app"]

  static func catalog() -> ComputerAppCatalog {
    var seen: Set<String> = []
    var apps: [ResolvedApp] = []
    func add(_ url: URL) {
      guard let app = entry(at: url), seen.insert(app.bundleID).inserted else {
        return
      }
      apps.append(app)
    }
    let manager = FileManager.default
    for folder in folders {
      let contents =
        (try? manager.contentsOfDirectory(
          at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)) ?? []
      for url in contents.sorted(by: { $0.path < $1.path }) where url.pathExtension == "app" {
        add(url)
      }
    }
    for path in extras {
      add(URL(fileURLWithPath: path))
    }
    for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
      if let url = running.bundleURL {
        add(url)
      }
    }
    return ComputerAppCatalog(apps: apps)
  }

  private static func entry(at url: URL) -> ResolvedApp? {
    guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else {
      return nil
    }
    let fileName = url.deletingPathExtension().lastPathComponent
    var shown = FileManager.default.displayName(atPath: url.path)
    if shown.lowercased().hasSuffix(".app") {
      shown.removeLast(4)
    }
    let others = [
      bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String,
      bundle.infoDictionary?["CFBundleDisplayName"] as? String,
      bundle.infoDictionary?["CFBundleName"] as? String,
      fileName,
    ].compactMap { $0 }.filter { $0 != shown }
    return ResolvedApp(bundleID: bundleID, displayName: shown, otherNames: others)
  }
}
