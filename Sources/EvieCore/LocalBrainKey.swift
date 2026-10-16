import Darwin
import Foundation

/// Where the Mac brain's per-launch key is kept: `brain.key`, beside
/// `brain.pid` in `Application Support/Evie/Runtime` (ADR 0017).
///
/// Loopback is reachable by every process of every user on this Mac, and by a
/// web page through DNS rebinding, so the server is started with a key that
/// exists for that launch only: made by whoever starts it (the launcher or
/// `Scripts/evie-brain`), handed to it in its environment, written here for
/// this user alone, and removed when the server stops. It is never in the
/// keychain, the configuration, an argv or a log, and nothing reads it but the
/// model client and the readiness probe, for the brain's own loopback port.
public struct LocalBrainKeyFile: Sendable, Equatable {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  /// `~/Library/Application Support/Evie/Runtime/brain.key`, the file the
  /// launcher and the script share.
  public static var standard: LocalBrainKeyFile {
    LocalBrainKeyFile(
      url: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent(
          "Library/Application Support/Evie/Runtime/brain.key", isDirectory: false)
    )
  }

  /// 32 bytes from the system's cryptographic generator, as 64 lowercase hex
  /// digits: printable, so it fits an `Authorization` header as it is.
  public static func makeKey() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<32).map { _ in
      let byte = UInt8.random(in: .min ... .max, using: &generator)
      return String(byte, radix: 16).leftPadded(to: 2)
    }.joined()
  }

  /// Writes `key` readable and writable by this user only (0600), replacing
  /// any earlier key. The file is created with that mode, never widened later,
  /// and renamed into place, so no reader sees half a key.
  public func write(_ key: String) throws {
    let temporary = url.deletingLastPathComponent()
      .appendingPathComponent(".brain.key.\(UUID().uuidString)", isDirectory: false)
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let bytes = Array(key.utf8)
    let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    close(descriptor)
    guard written == bytes.count else {
      unlink(temporary.path)
      throw POSIXError(.EIO)
    }
    guard rename(temporary.path, url.path) == 0 else {
      let code = POSIXErrorCode(rawValue: errno) ?? .EIO
      unlink(temporary.path)
      throw POSIXError(code)
    }
  }

  /// The key, or nil unless the file is a regular file (not a symlink) owned
  /// by this user, unreadable by anyone else, holding one key and at most a
  /// trailing newline. Anything else was not written by Evie or her script.
  public func read() -> String? {
    var status = stat()
    guard lstat(url.path, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == getuid(),
      status.st_mode & 0o077 == 0,
      status.st_size <= 128,
      let contents = try? String(contentsOf: url, encoding: .utf8)
    else {
      return nil
    }
    let key = contents.hasSuffix("\n") ? String(contents.dropLast()) : contents
    guard key.count == 64, key.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
      return nil
    }
    return key
  }

  public func remove() {
    unlink(url.path)
  }
}

extension String {
  fileprivate func leftPadded(to length: Int) -> String {
    count >= length ? self : String(repeating: "0", count: length - count) + self
  }
}
