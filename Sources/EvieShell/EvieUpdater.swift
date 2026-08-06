import AppKit
import EvieCore
import Foundation

/// Finds, checks, and installs a newer Evie published as a GitHub release.
///
/// Nothing here happens on its own beyond one HTTPS GET. Checking is a
/// preference; downloading is a button; installing is a second button. That is
/// the same propose-then-confirm shape the rest of Evie uses, and it matters
/// more here than anywhere else, because the thing being confirmed is replacing
/// the application with bytes from the network.
///
/// The trust chain has exactly two links and neither is optional: TLS to GitHub
/// decides *what arrives*, and `EvieBundleSignature` decides *whether it runs*.
/// A release feed that has been tampered with, or a GitHub account that has been
/// taken over, still cannot produce a bundle signed with this Mac's certificate.
@MainActor
final class EvieUpdater: ObservableObject {
  static let owner = "matheusbgodoi"
  static let repository = "evie-ai"

  /// At most once a day, so a check is something that happens quietly rather
  /// than every time a window opens.
  static let checkInterval: TimeInterval = 24 * 60 * 60

  enum State: Equatable {
    case idle
    case checking
    case upToDate
    case available(EvieRelease)
    case downloading(fraction: Double)
    case readyToInstall(EvieRelease)
    case failed(String)
  }

  @Published private(set) var state: State = .idle
  @Published private(set) var lastChecked: Date?

  private var staged: URL?

  /// The version of the bundle actually running.
  ///
  /// Nil when Evie is run as a bare executable rather than as an app, which is
  /// how the diagnostics run: there is no release to compare against, and
  /// offering to replace a debug build with a release would be wrong.
  static var installedVersion: EvieVersion? {
    guard
      let string = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    else {
      return nil
    }
    return EvieVersion(string)
  }

  static var isRunningFromBundle: Bool {
    Bundle.main.bundleURL.pathExtension == "app"
  }

  // MARK: - Looking

  /// Asks GitHub what the newest release is.
  func check(force: Bool = false) async {
    if !force, let lastChecked, Date().timeIntervalSince(lastChecked) < Self.checkInterval {
      return
    }
    guard let installed = Self.installedVersion, Self.isRunningFromBundle else {
      state = .failed("Esta cópia da Evie não é um app instalado, então não há o que atualizar.")
      return
    }

    state = .checking
    do {
      let release = try await fetchLatest()
      lastChecked = Date()
      state =
        EvieReleaseFeed.isUpgrade(release, from: installed)
        ? .available(release)
        : .upToDate
    } catch {
      state = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
    }
  }

  private func fetchLatest() async throws -> EvieRelease {
    var request = URLRequest(url: EvieReleaseFeed.url(owner: Self.owner, repository: Self.repository))
    request.timeoutInterval = 20
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("Evie", forHTTPHeaderField: "User-Agent")
    // Nothing identifying is sent. This is a plain public read, and saying so in
    // the code is worth as much as saying it in the interface.
    request.httpShouldHandleCookies = false

    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    switch status {
    case 200:
      break
    case 404:
      // The single most likely cause, and the one that is impossible to guess
      // from "404".
      throw UpdateError.notPublished
    case 403, 429:
      throw UpdateError.rateLimited
    default:
      throw UpdateError.refused(status)
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw EvieReleaseFeed.FeedError.malformed
    }
    return try EvieReleaseFeed.release(from: object)
  }

  // MARK: - Fetching

  /// Downloads a release, checks who signed it, and stages it next to the
  /// installed copy. Nothing is replaced until `install` is called.
  func download(_ release: EvieRelease) async {
    state = .downloading(fraction: 0)
    do {
      let archive = try await fetch(release)
      defer { try? FileManager.default.removeItem(at: archive) }
      let bundle = try expand(archive)
      try EvieBundleSignature.verify(
        candidateAt: bundle,
        matchesSignerOf: Bundle.main.bundleURL
      )
      staged = bundle
      state = .readyToInstall(release)
    } catch {
      discardStaged()
      state = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
    }
  }

  private func fetch(_ release: EvieRelease) async throws -> URL {
    var request = URLRequest(url: release.downloadURL)
    request.timeoutInterval = 300
    request.setValue("Evie", forHTTPHeaderField: "User-Agent")

    let (temporary, response) = try await URLSession.shared.download(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      try? FileManager.default.removeItem(at: temporary)
      throw UpdateError.refused((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    // Checked against what actually arrived rather than what the feed claimed,
    // since the claim is the thing being verified.
    let attributes = try? FileManager.default.attributesOfItem(atPath: temporary.path)
    let bytes = (attributes?[.size] as? Int) ?? 0
    guard bytes <= EvieReleaseFeed.maximumDownloadBytes else {
      try? FileManager.default.removeItem(at: temporary)
      throw EvieReleaseFeed.FeedError.tooLarge(bytes)
    }
    return temporary
  }

  /// Unpacks the archive with `ditto`, which is the only unpacker that preserves
  /// what a signature is computed over.
  ///
  /// Foundation's own unzipping drops extended attributes and symlink structure,
  /// which breaks the seal on a perfectly good bundle — the verification would
  /// then fail for the wrong reason, and the natural fix would be to weaken the
  /// verification. So the correct tool is used instead.
  private func expand(_ archive: URL) throws -> URL {
    let directory = try FileManager.default.url(
      for: .itemReplacementDirectory,
      in: .userDomainMask,
      // Same volume as the installed copy, which `replaceItemAt` requires.
      appropriateFor: Bundle.main.bundleURL,
      create: true
    )

    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-x", "-k", archive.path, directory.path]
    ditto.standardOutput = FileHandle.nullDevice
    ditto.standardError = FileHandle.nullDevice
    try ditto.run()
    ditto.waitUntilExit()
    guard ditto.terminationStatus == 0 else {
      try? FileManager.default.removeItem(at: directory)
      throw UpdateError.corruptArchive
    }

    // Exactly one app at the top level, and nothing else. An archive that
    // unpacks to several bundles, or to a path that climbed out of the
    // directory, is refused rather than searched for something plausible.
    let contents =
      (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
      .filter { !$0.hasPrefix(".") && $0 != "__MACOSX" } ?? []
    guard contents.count == 1, let name = contents.first, name.hasSuffix(".app") else {
      try? FileManager.default.removeItem(at: directory)
      throw UpdateError.corruptArchive
    }
    return directory.appendingPathComponent(name, isDirectory: true)
  }

  // MARK: - Replacing

  /// Swaps the staged copy in and restarts.
  ///
  /// The running image is already mapped, so replacing the bundle underneath it
  /// is safe; what is not safe is doing it without relaunching, which would
  /// leave the old code running against new resources.
  func install() {
    guard let staged else {
      state = .failed("Não há nada preparado para instalar.")
      return
    }
    let destination = Bundle.main.bundleURL
    do {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
    } catch {
      state = .failed("Não consegui substituir o app: \(error.localizedDescription)")
      return
    }
    self.staged = nil

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in
      Task { @MainActor in
        NSApp.terminate(nil)
      }
    }
  }

  /// Throws away a staged copy, so refusing an update does not leave a second
  /// Evie sitting on the disk.
  func discardStaged() {
    if let staged {
      try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
    }
    staged = nil
  }

  enum UpdateError: LocalizedError, Equatable {
    case notPublished
    case rateLimited
    case refused(Int)
    case corruptArchive

    var errorDescription: String? {
      switch self {
      case .notPublished:
        "Não achei nenhuma release publicada. Se o repositório for privado, "
          + "ninguém além de você consegue baixar — publique-o para distribuir."
      case .rateLimited:
        "O GitHub pediu para eu esperar antes de perguntar de novo."
      case .refused(let status):
        "O GitHub respondeu \(status)."
      case .corruptArchive:
        "O arquivo baixado não contém um app da Evie."
      }
    }
  }
}
