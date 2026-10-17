import Darwin
import Foundation

/// One start of the Mac brain, shared by every turn waiting on it, and
/// cancelled once none of them still wants it.
///
/// A wake loads about 8 GB and can take most of the 90 s the launcher allows,
/// so "Acordando o cérebro do Mac…" followed by Cancelar must stop it: the
/// start runs in a task of its own (two turns asking at once share it), and
/// waiting on a task's value does not pass the waiter's cancellation on. When
/// the last turn waiting gives up, the start is cancelled; whatever it spawned
/// is its own to stop. A turn that asks while an abandoned start is still
/// winding down waits for it, then starts afresh, so it never inherits a
/// cancellation it did not ask for.
@MainActor
public final class LocalBrainWake<Value: Sendable> {
  private struct Run {
    let id: UUID
    let task: Task<Value, any Error>
    var waiting: Set<UUID> = []
    var abandoned = false
  }

  private var current: Run?

  public init() {}

  /// Whether a start is under way, abandoned or not.
  public var isRunning: Bool {
    current != nil
  }

  /// The started value: from the start under way, or from `operation`,
  /// started now. Throws `CancellationError` when this caller was cancelled
  /// and no other was still waiting.
  public func value(
    starting operation: @escaping @MainActor @Sendable () async throws -> Value
  ) async throws -> Value {
    while let run = current, run.abandoned {
      _ = await run.task.result
    }
    let run = current ?? begin(operation)
    let caller = UUID()
    current?.waiting.insert(caller)
    return try await withTaskCancellationHandler {
      try await run.task.value
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.abandon(run.id, by: caller)
      }
    }
  }

  private func begin(_ operation: @escaping @MainActor @Sendable () async throws -> Value) -> Run {
    let id = UUID()
    let task = Task { @MainActor [weak self] in
      // Cleared before any waiter resumes, so none of them can join a start
      // that has already ended.
      defer {
        if self?.current?.id == id {
          self?.current = nil
        }
      }
      return try await operation()
    }
    let run = Run(id: id, task: task)
    current = run
    return run
  }

  private func abandon(_ id: UUID, by caller: UUID) {
    guard var run = current, run.id == id else {
      return
    }
    run.waiting.remove(caller)
    if run.waiting.isEmpty {
      run.abandoned = true
      run.task.cancel()
    }
    current = run
  }
}

/// How the Mac brain's server is stopped: SIGTERM, then SIGKILL once the
/// grace is over.
///
/// Every wait is a `Task.sleep`, which suspends: the brain is stopped from the
/// idle timer and at quit, both on the main actor, and a server that ignores
/// SIGTERM used to hold it for up to seven seconds of `usleep`, with the
/// overlay frozen. A stop also runs to the end when the task that asked for it
/// is cancelled — a cancelled wake stops the child it spawned — because a stop
/// cut short would leave the 8 GB behind.
public struct LocalBrainShutdown: Sendable {
  public enum Wait: Sendable, Equatable {
    /// Wait after SIGKILL too, to know the process is gone: the idle timer,
    /// a failed start.
    case untilGone
    /// At quit: wait the grace, send SIGKILL, and go. Evie is exiting, and
    /// the kernel delivers SIGKILL without her.
    case graceOnly
  }

  /// Measured 2026-10-16: uvicorn exits within 0.35 s of SIGTERM.
  public let grace: Duration
  public let afterKill: Duration
  public let pollInterval: Duration

  public static let standard = LocalBrainShutdown(
    grace: .seconds(5),
    afterKill: .seconds(2),
    pollInterval: .milliseconds(50)
  )

  public init(grace: Duration, afterKill: Duration, pollInterval: Duration) {
    self.grace = grace
    self.afterKill = afterKill
    self.pollInterval = pollInterval
  }

  /// Whether the process is known to be gone at the end. `signal` sends one
  /// signal to the server; `isAlive` is read between sleeps, never in a loop
  /// of its own.
  public func stop(
    signal: @escaping @Sendable (Int32) -> Void,
    isAlive: @escaping @Sendable () -> Bool,
    waiting: Wait
  ) async -> Bool {
    // An unstructured task does not inherit the caller's cancellation, which
    // would turn every sleep below into an immediate throw.
    await Task {
      signal(SIGTERM)
      if await waitForExit(isAlive, within: grace) {
        return true
      }
      signal(SIGKILL)
      guard waiting == .untilGone else {
        return false
      }
      return await waitForExit(isAlive, within: afterKill)
    }.value
  }

  private func waitForExit(_ isAlive: @Sendable () -> Bool, within limit: Duration) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
      if !isAlive() {
        return true
      }
      try? await Task.sleep(for: pollInterval)
    }
    return !isAlive()
  }
}
