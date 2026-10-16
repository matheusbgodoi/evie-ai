import Darwin
import Foundation
import Synchronization
import Testing

@testable import EvieCore

/// Waking the Mac brain for the turns that wait on it, and giving up on the
/// wake when none of them still wants it ("Acordando o cérebro do Mac…" and
/// then Cancelar must not load 8 GB anyway).
@MainActor
@Suite("Local brain wake")
struct LocalBrainWakeTests {
  @Test("every turn waiting on a wake shares one start")
  func turnsShareOneStart() async throws {
    let wake = LocalBrainWake<Int>()
    let gate = Gate()
    let starts = Counter()
    let operation: @MainActor @Sendable () async throws -> Int = {
      starts.value += 1
      await gate.wait()
      return 38_480
    }

    let first = Task { try await wake.value(starting: operation) }
    let second = Task { try await wake.value(starting: operation) }
    await Self.settle()
    gate.open()

    #expect(try await first.value == 38_480)
    #expect(try await second.value == 38_480)
    #expect(starts.value == 1)
    #expect(!wake.isRunning)
  }

  @Test("cancelling the only turn waiting cancels the start")
  func lastWaiterCancelsTheStart() async {
    let wake = LocalBrainWake<Int>()
    let started = Gate()
    let startCancelled = Flag()
    let turn = Task {
      try await wake.value {
        started.open()
        do {
          try await Task.sleep(for: .seconds(30))
        } catch {
          startCancelled.value = true
          throw error
        }
        return 1
      }
    }
    await started.wait()

    turn.cancel()
    let result = await turn.result

    #expect(startCancelled.value)
    #expect(throws: CancellationError.self) { try result.get() }
    #expect(!wake.isRunning)
  }

  @Test("a start another turn still waits for keeps going when one gives up")
  func otherWaitersKeepTheStart() async throws {
    let wake = LocalBrainWake<Int>()
    let started = Gate()
    let finish = Gate()
    let startCancelled = Flag()
    let operation: @MainActor @Sendable () async throws -> Int = {
      started.open()
      await finish.wait()
      startCancelled.value = Task.isCancelled
      return 7
    }
    let leaving = Task { try await wake.value(starting: operation) }
    let staying = Task { try await wake.value(starting: operation) }
    await started.wait()
    await Self.settle()

    leaving.cancel()
    await Self.settle()
    finish.open()

    #expect(try await staying.value == 7)
    _ = await leaving.result
    #expect(!startCancelled.value)
  }

  @Test("after an abandoned start, the next turn waits for it to wind down and starts afresh")
  func nextTurnWaitsForTheAbandonedStart() async throws {
    let wake = LocalBrainWake<Int>()
    let started = Gate()
    let windDown = Gate()
    let events = Events()
    let starts = Counter()
    let operation: @MainActor @Sendable () async throws -> Int = {
      starts.value += 1
      let number = starts.value
      events.list.append("start \(number)")
      if number == 1 {
        started.open()
        do {
          try await Task.sleep(for: .seconds(30))
        } catch {
          events.list.append("cancelled 1")
          // Stopping the child it spawned takes a moment.
          await windDown.wait()
          events.list.append("wound down 1")
          throw error
        }
      }
      return number
    }
    let abandoned = Task { try await wake.value(starting: operation) }
    await started.wait()
    abandoned.cancel()
    await Self.settle()

    let next = Task { try await wake.value(starting: operation) }
    await Self.settle()
    #expect(events.list == ["start 1", "cancelled 1"])
    windDown.open()

    #expect(try await next.value == 2)
    #expect(events.list == ["start 1", "cancelled 1", "wound down 1", "start 2"])
  }

  /// Lets every job already queued on the main actor run.
  private static func settle() async {
    for _ in 0..<20 {
      await Task.yield()
    }
  }
}

/// Stopping the Mac brain: SIGTERM, SIGKILL after the grace, and every wait a
/// suspension rather than a sleep that holds the main actor — the server is
/// stopped from the idle timer and at quit, both on the main actor.
@MainActor
@Suite("Local brain shutdown")
struct LocalBrainShutdownTests {
  private let shutdown = LocalBrainShutdown(
    grace: .milliseconds(100),
    afterKill: .milliseconds(50),
    pollInterval: .milliseconds(5)
  )

  @Test("the standard grace is five seconds, then two to see SIGKILL land")
  func standardDurations() {
    #expect(LocalBrainShutdown.standard.grace == .seconds(5))
    #expect(LocalBrainShutdown.standard.afterKill == .seconds(2))
  }

  @Test("a server that exits on SIGTERM is sent nothing else")
  func exitsOnTerm() async {
    let server = FakeServer(diesOn: SIGTERM)

    let gone = await shutdown.stop(
      signal: server.signal, isAlive: server.isAlive, waiting: .untilGone)

    #expect(gone)
    #expect(server.signals == [SIGTERM])
  }

  @Test("a server that ignores SIGTERM is killed once the grace is over")
  func killedAfterTheGrace() async {
    let server = FakeServer(diesOn: SIGKILL)
    let started = ContinuousClock.now

    let gone = await shutdown.stop(
      signal: server.signal, isAlive: server.isAlive, waiting: .untilGone)

    #expect(gone)
    #expect(server.signals == [SIGTERM, SIGKILL])
    #expect(ContinuousClock.now - started >= shutdown.grace)
  }

  @Test("the main actor keeps running while a stop waits for the exit")
  func waitingDoesNotHoldTheMainActor() async {
    // The server exits only once a job on the main actor has run: a stop
    // that slept on the main actor would wait out the grace and kill it.
    let server = FakeServer(diesOn: nil)
    Task { @MainActor in server.exitNow() }

    let gone = await shutdown.stop(
      signal: server.signal, isAlive: server.isAlive, waiting: .untilGone)

    #expect(gone)
    #expect(server.signals == [SIGTERM])
  }

  @Test("at quit the wait ends with the grace: SIGKILL is sent and not waited on")
  func quitWaitsOnlyTheGrace() async {
    let server = FakeServer(diesOn: nil)

    let gone = await shutdown.stop(
      signal: server.signal, isAlive: server.isAlive, waiting: .graceOnly)

    #expect(!gone)
    #expect(server.signals == [SIGTERM, SIGKILL])
    #expect(server.checksAfterKill == 0)
  }

  @Test("a stop runs to the end even when the task that asked for it is cancelled")
  func cancellationDoesNotCutAStopShort() async {
    let server = FakeServer(diesOn: SIGKILL)
    let shutdown = shutdown
    let stopping = Task {
      await shutdown.stop(signal: server.signal, isAlive: server.isAlive, waiting: .untilGone)
    }
    stopping.cancel()

    let gone = await stopping.value

    #expect(gone)
    #expect(server.signals == [SIGTERM, SIGKILL])
  }
}

/// A process that dies on one signal (or on `exitNow`) and records what it was
/// sent and how often it was checked after SIGKILL.
private final class FakeServer: Sendable {
  private struct State {
    var alive = true
    var signals: [Int32] = []
    var checksAfterKill = 0
  }

  private let diesOn: Int32?
  private let state = Mutex(State())

  init(diesOn: Int32?) {
    self.diesOn = diesOn
  }

  var signals: [Int32] { state.withLock { $0.signals } }
  var checksAfterKill: Int { state.withLock { $0.checksAfterKill } }

  var signal: @Sendable (Int32) -> Void {
    { [self] number in
      state.withLock {
        $0.signals.append(number)
        if number == diesOn {
          $0.alive = false
        }
      }
    }
  }

  var isAlive: @Sendable () -> Bool {
    { [self] in
      state.withLock {
        if $0.signals.contains(SIGKILL) {
          $0.checksAfterKill += 1
        }
        return $0.alive
      }
    }
  }

  func exitNow() {
    state.withLock { $0.alive = false }
  }
}

@MainActor
private final class Counter {
  var value = 0
}

@MainActor
private final class Flag {
  var value = false
}

@MainActor
private final class Events {
  var list: [String] = []
}

/// Opens once; every waiter, before or after, goes through.
@MainActor
private final class Gate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func open() {
    isOpen = true
    let waiting = waiters
    waiters = []
    waiting.forEach { $0.resume() }
  }

  func wait() async {
    if isOpen {
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }
}
