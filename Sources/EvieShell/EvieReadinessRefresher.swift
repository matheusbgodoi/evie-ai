import AppKit
import EvieCore
import Network
import Synchronization

/// Re-probes the brain at the two moments a cached readiness answer is most
/// likely wrong: when Evie comes to the front, which is when a question is
/// about to be asked, and when the network changes — Wi-Fi to Ethernet, a
/// sleep and wake, Tailscale going up or down — which is when the PC can appear
/// or vanish.
///
/// Each refresh is three small `GET`s to the PC (measured 2026-10-16: 37 ms,
/// 69 ms and 31 ms over the tailnet), or one loopback `GET` for the Mac brain,
/// and none of them can load a model. Doing it here means a turn finds the
/// answer already in the cache instead of paying the probe — and, when the PC
/// is off, its 3 s `/health` deadline — before the first token.
///
/// The cost when nothing happens is nothing: `NWPathMonitor` and the
/// notification are both event-driven, with no timer.
@MainActor
final class EvieReadinessRefresher {
  private let cache: ModelReadinessCache
  private let profile: EvieModelProfile
  private let pathMonitor = NWPathMonitor()
  private var activationObserver: (any NSObjectProtocol)?

  /// - Parameter profile: the profile in use at launch. A profile edited in
  ///   Settings later is not refreshed here, but it is never served this one's
  ///   answer either: the cache keys every result by the exact profile.
  init(cache: ModelReadinessCache, profile: EvieModelProfile) {
    self.cache = cache
    self.profile = profile
  }

  func start() {
    refresh()

    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.refresh()
      }
    }

    // The monitor reports the current path as soon as it starts. That one is
    // not a change, and the launch refresh above already covers it.
    let initialPath = OnceFlag()
    let cache = cache
    let profile = profile
    pathMonitor.pathUpdateHandler = { _ in
      guard !initialPath.consume() else { return }
      Task {
        await cache.refresh(profile)
      }
    }
    pathMonitor.start(queue: DispatchQueue(label: "com.matheusbgodoi.evie.network-path"))
  }

  func stop() {
    pathMonitor.cancel()
    if let activationObserver {
      NotificationCenter.default.removeObserver(activationObserver)
    }
    activationObserver = nil
  }

  private func refresh() {
    let cache = cache
    let profile = profile
    Task {
      await cache.refresh(profile)
    }
  }
}

/// True the first time it is consumed, false every time after.
private final class OnceFlag: Sendable {
  private let pending = Mutex(true)

  func consume() -> Bool {
    pending.withLock { pending in
      defer { pending = false }
      return pending
    }
  }
}
