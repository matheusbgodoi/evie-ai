import Foundation

/// Exercises the real microphone/recognizer lifecycle without observing its text.
/// Requires an existing microphone grant; this diagnostic never requests consent.
@MainActor
enum NativeWakeLifecycleCheck {
  struct Report: Encodable {
    let success: Bool
    let microphonePermissionGranted: Bool
    let pendingArmWasInterrupted: Bool
    let staleArmResurrected: Bool
    let normalArmSucceeded: Bool
    let disarmedAfterNormalArm: Bool
    let failureCode: String?
  }

  static func run() async -> Report {
    guard EvieAudioCapture.currentPermission().allowsCapture else {
      return unavailable("microphonePermissionRequired")
    }
    guard EvieAudioCapture.isBundled else {
      return unavailable("applicationBundleRequired", microphoneGranted: true)
    }
    let listener = EvieWakeListener()
    guard listener.isSupported else {
      return unavailable("nativeRecognitionUnavailable", microphoneGranted: true)
    }

    var began = false
    var finished = false
    let pendingArm = Task { @MainActor in
      began = true
      await listener.arm(phrases: "Evie")
      finished = true
    }
    // Let arm enter a real asynchronous preparation step before revoking it.
    // A scheduler that finishes arming first is reported as unverified, not a pass.
    for _ in 0..<100 where !began {
      await Task.yield()
    }
    let interrupted = began && !finished && !listener.isArmed
    listener.disarm()
    await pendingArm.value
    let resurrected = listener.isArmed
    listener.disarm()

    await listener.arm(phrases: "Evie")
    let normallyArmed = listener.isArmed
    listener.disarm()
    let normallyDisarmed = !listener.isArmed
    let success = interrupted && !resurrected && normallyArmed && normallyDisarmed
    let failure: String?
    if !interrupted {
      failure = "pendingArmNotObserved"
    } else if resurrected {
      failure = "staleArmResurrected"
    } else if !normallyArmed {
      failure = "normalArmFailed"
    } else if !normallyDisarmed {
      failure = "normalDisarmFailed"
    } else {
      failure = nil
    }
    return Report(
      success: success,
      microphonePermissionGranted: true,
      pendingArmWasInterrupted: interrupted,
      staleArmResurrected: resurrected,
      normalArmSucceeded: normallyArmed,
      disarmedAfterNormalArm: normallyDisarmed,
      failureCode: failure
    )
  }

  private static func unavailable(_ code: String, microphoneGranted: Bool = false) -> Report {
    Report(
      success: false,
      microphonePermissionGranted: microphoneGranted,
      pendingArmWasInterrupted: false,
      staleArmResurrected: false,
      normalArmSucceeded: false,
      disarmedAfterNormalArm: true,
      failureCode: code
    )
  }
}
