import Foundation
import Testing

@testable import EvieCore

@Suite("Evie releases")
struct EvieReleaseTests {
  // MARK: - Ordering versions

  /// The bug this exists for: compared as text, "1.10.0" sorts below "1.9.0", so
  /// the update is offered backwards once and then never again.
  @Test("ten comes after nine")
  func comparesNumerically() throws {
    let nine = try #require(EvieVersion("1.9.0"))
    let ten = try #require(EvieVersion("1.10.0"))

    #expect(ten > nine)
    #expect("1.10.0" < "1.9.0")  // the trap, stated
  }

  @Test("a missing component is zero, not missing")
  func padsComponents() throws {
    let short = try #require(EvieVersion("1.2"))
    #expect(short == (try #require(EvieVersion("1.2.0"))))
    #expect(try #require(EvieVersion("1.2.1")) > short)
  }

  @Test("a leading v is decoration")
  func acceptsTagPrefix() throws {
    let prefixed = try #require(EvieVersion("v2.0.0"))
    #expect(prefixed == (try #require(EvieVersion("2.0.0"))))
  }

  /// The rule people write backwards: a pre-release comes *before* the release
  /// it is a pre-release of.
  @Test("a beta is older than the release it precedes")
  func prereleasesSortBelow() throws {
    let beta = try #require(EvieVersion("1.2.0-beta.1"))
    let final = try #require(EvieVersion("1.2.0"))

    #expect(beta < final)
    #expect(try #require(EvieVersion("1.2.0-beta.2")) > beta)
    // And still below the next release entirely.
    #expect(try #require(EvieVersion("1.1.9")) < beta)
  }

  @Test("build metadata does not change the order")
  func ignoresBuildMetadata() throws {
    let stamped = try #require(EvieVersion("1.2.0+abc"))
    #expect(stamped == (try #require(EvieVersion("1.2.0"))))
  }

  /// Refused rather than read as version zero, which would offer "nightly" as an
  /// upgrade to nobody and a downgrade to everybody.
  @Test("a tag that is not a version is refused")
  func rejectsNonVersions() {
    #expect(EvieVersion("nightly") == nil)
    #expect(EvieVersion("") == nil)
    #expect(EvieVersion("1.x.0") == nil)
    #expect(EvieVersion("-1.0") == nil)
  }

  @Test("a version reads back the way it was written")
  func roundTrips() throws {
    #expect(try #require(EvieVersion("v1.2.0-beta.1")).description == "1.2.0-beta.1")
    #expect(try #require(EvieVersion("0.1")).description == "0.1")
  }

  // MARK: - Reading a release

  private func feed(
    tag: String = "v0.2.0",
    assets: [[String: Any]] = [["name": "Evie.app.zip", "size": 9_000_000,
                                "browser_download_url": "https://github.com/o/r/releases/download/v0.2.0/Evie.app.zip"]],
    prerelease: Bool = false
  ) -> [String: Any] {
    ["tag_name": tag, "name": "Evie \(tag)", "body": "notas", "prerelease": prerelease,
     "assets": assets]
  }

  @Test("a normal release is read whole")
  func readsARelease() throws {
    let release = try EvieReleaseFeed.release(from: feed())

    #expect(release.version == EvieVersion("0.2.0"))
    #expect(release.tag == "v0.2.0")
    #expect(release.notes == "notas")
    #expect(release.downloadBytes == 9_000_000)
    #expect(!release.isPrerelease)
  }

  /// The whole point of the strictness: the download address arrives inside the
  /// response, and a response is the wrong place to learn where it is acceptable
  /// to fetch an executable from.
  @Test("a download from anywhere but GitHub is refused")
  func refusesForeignHosts() {
    for address in [
      "https://evil.example.com/Evie.app.zip",
      "https://github.com.evil.example/Evie.app.zip",
      "https://raw.githubusercontent.com.attacker.net/Evie.app.zip",
    ] {
      #expect(throws: (any Error).self) {
        try EvieReleaseFeed.release(
          from: feed(assets: [["name": "Evie.app.zip", "size": 1000, "browser_download_url": address]])
        )
      }
    }
  }

  @Test("a download that is not over TLS is refused")
  func refusesPlainHTTP() {
    #expect(throws: (any Error).self) {
      try EvieReleaseFeed.release(
        from: feed(assets: [[
          "name": "Evie.app.zip", "size": 1000,
          "browser_download_url": "http://github.com/o/r/Evie.app.zip",
        ]])
      )
    }
  }

  @Test("a file far larger than a build is refused before it is fetched")
  func refusesOversizedAssets() {
    #expect(throws: (any Error).self) {
      try EvieReleaseFeed.release(
        from: feed(assets: [[
          "name": "Evie.app.zip", "size": EvieReleaseFeed.maximumDownloadBytes + 1,
          "browser_download_url": "https://github.com/o/r/Evie.app.zip",
        ]])
      )
    }
  }

  /// GitHub attaches source archives to every release on its own, and installing
  /// one would be a confusing way to fail.
  @Test("the app is chosen over the source archives GitHub adds")
  func skipsSourceArchives() throws {
    let release = try EvieReleaseFeed.release(
      from: feed(assets: [
        ["name": "Source code.zip", "size": 500,
         "browser_download_url": "https://github.com/o/r/src.zip"],
        ["name": "Evie.app.zip", "size": 9000,
         "browser_download_url": "https://github.com/o/r/Evie.app.zip"],
      ])
    )

    #expect(release.downloadURL.lastPathComponent == "Evie.app.zip")
  }

  @Test("a release with nothing to install says so")
  func refusesAssetlessReleases() {
    #expect(throws: (any Error).self) {
      try EvieReleaseFeed.release(from: feed(assets: []))
    }
    #expect(throws: (any Error).self) {
      try EvieReleaseFeed.release(
        from: feed(assets: [["name": "notes.txt", "size": 10,
                             "browser_download_url": "https://github.com/o/r/n.txt"]])
      )
    }
  }

  @Test("a tag that is not a version is refused before anything is downloaded")
  func refusesUnusableTags() {
    #expect(throws: (any Error).self) {
      try EvieReleaseFeed.release(from: feed(tag: "nightly"))
    }
  }

  // MARK: - Deciding whether to offer it

  @Test("only a newer version is offered")
  func offersOnlyUpgrades() throws {
    let release = try EvieReleaseFeed.release(from: feed(tag: "v0.2.0"))
    let installed = try #require(EvieVersion("0.1"))

    let same = try #require(EvieVersion("0.2.0"))
    let newer = try #require(EvieVersion("0.3.0"))

    #expect(EvieReleaseFeed.isUpgrade(release, from: installed))
    #expect(!EvieReleaseFeed.isUpgrade(release, from: same))
    #expect(!EvieReleaseFeed.isUpgrade(release, from: newer))
  }

  /// Somebody running a stable build did not ask to test anything.
  @Test("a pre-release is not offered unless it was asked for")
  func withholdsPrereleases() throws {
    let beta = try EvieReleaseFeed.release(from: feed(tag: "v0.3.0-beta.1", prerelease: true))
    let installed = try #require(EvieVersion("0.1"))

    #expect(!EvieReleaseFeed.isUpgrade(beta, from: installed))
    #expect(EvieReleaseFeed.isUpgrade(beta, from: installed, acceptingPrereleases: true))
  }
}
