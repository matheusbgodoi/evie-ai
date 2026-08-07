import Darwin
import EvieCore
import Foundation

/// One scheduled run at a time, across processes.
///
/// The model behind Evie is a single worker: two turns at once do not run twice
/// as fast, they run one after the other with both callers waiting. Schedules
/// make that easy to hit — 8:00 and 8:00 is a perfectly ordinary pair of times
/// to choose, and a folder trigger can fire while a clock one is still thinking.
///
/// The decision is to **skip**, not to queue. A queue would mean the second run
/// starts when the first ends, which for a turn that takes tens of seconds means
/// a summary of the morning's mail arriving well after the morning has started —
/// and it would hold a process alive doing nothing but waiting, which is the one
/// thing this whole design refuses. Skipping loses one run of something that, by
/// construction, runs again. The skip is written to the log so it is not silent.
///
/// `flock` rather than a file whose presence means "busy": the lock belongs to
/// the open descriptor, so a run that crashes, is killed, or is terminated at
/// logout releases it. A marker file would survive that and block every
/// subsequent run until somebody deleted it by hand.
final class EvieScheduleLock {
  private let descriptor: Int32

  static var defaultFileURL: URL {
    EvieConfigurationLoader.defaultFileURL
      .deletingLastPathComponent()
      .appendingPathComponent("State", isDirectory: true)
      .appendingPathComponent("schedule-run.lock", isDirectory: false)
  }

  /// Held on success, `nil` when another run has it.
  init?(fileURL: URL = EvieScheduleLock.defaultFileURL) {
    try? FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let descriptor = open(fileURL.path, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0 else {
      return nil
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      return nil
    }
    self.descriptor = descriptor
  }

  deinit {
    // Released explicitly rather than left to process exit, so the lock's life
    // is the run's life. The same process could one day run a schedule for a
    // reason other than having been woken to do only that.
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }
}
