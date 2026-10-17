import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import EvieCore
import Speech

/// One line of the first-run guide: how to read its state, and what its button
/// does.
///
/// Every row — a system permission, the gateway key, the brain's connection
/// test — conforms to this, so the view and its model never learn what kind of
/// row they are drawing.
@MainActor
protocol PermissionGuideItem {
  /// The row as it stands now. Called on every refresh, so it must not block
  /// and must never show a prompt.
  func row(given record: PermissionGuideRecord) -> PermissionGuideRow

  func refreshStatus()
  func observeRowChanges(_ onChange: @escaping @MainActor () -> Void)

  /// Runs the row's button.
  ///
  /// - Returns: the permission whose one system prompt this just used, so the
  ///   guide remembers it was spent and offers System Settings from then on; nil
  ///   when nothing was requested.
  func perform(_ action: PermissionGuideRow.Action) async -> EviePermission?
}

extension PermissionGuideItem {
  func refreshStatus() {}
  func observeRowChanges(_ onChange: @escaping @MainActor () -> Void) {}
}

/// A row for one macOS privacy permission.
@MainActor
struct SystemPermissionItem: PermissionGuideItem {
  let permission: EviePermission
  /// The coordinator's own capture object, so the microphone is asked for
  /// through the one path that knows the order of operations matters.
  let audioCapture: EvieAudioCapture

  func row(given record: PermissionGuideRecord) -> PermissionGuideRow {
    .permission(
      permission,
      status: Self.status(of: permission),
      alreadyRequested: record.requested.contains(permission)
    )
  }

  func perform(_ action: PermissionGuideRow.Action) async -> EviePermission? {
    switch action.kind {
    case .openSettings(let url):
      NSWorkspace.shared.open(url)
      return nil
    case .request:
      await request()
      return permission
    case .importPCKey, .testConnection:
      // Not a permission row's button.
      return nil
    }
  }

  /// Every probe here answers immediately and never prompts.
  static func status(of permission: EviePermission) -> EviePermissionStatus {
    switch permission {
    case .microphone:
      switch EvieAudioCapture.currentPermission() {
      case .granted: .granted
      case .notDetermined: .notDetermined
      case .denied, .restricted: .denied
      }
    case .speechRecognition:
      switch SFSpeechRecognizer.authorizationStatus() {
      case .authorized: .granted
      case .notDetermined: .notDetermined
      case .denied, .restricted: .denied
      @unknown default: .denied
      }
    case .screenRecording:
      CGPreflightScreenCaptureAccess() ? .granted : .notGranted
    case .accessibility:
      AXIsProcessTrusted() ? .granted : .notGranted
    case .postEvents:
      CGPreflightPostEventAccess() ? .granted : .notGranted
    }
  }

  private func request() async {
    switch permission {
    case .microphone:
      _ = await audioCapture.requestPermission()
    case .speechRecognition:
      _ = await Self.requestSpeechRecognition()
    case .screenRecording:
      // Shows the prompt the first time and returns at once every time after,
      // which is why the row stops offering this button once it has been used.
      _ = CGRequestScreenCaptureAccess()
    case .accessibility:
      // The key's string value rather than `kAXTrustedCheckOptionPrompt`: the
      // constant is imported as a mutable global, which Swift 6 reports as
      // unsafe shared state, and the release build treats warnings as errors.
      _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    case .postEvents:
      _ = CGRequestPostEventAccess()
    }
  }

  /// `nonisolated` on purpose. The completion handler runs on a queue of the
  /// framework's choosing; formed inside a main-actor method it would inherit
  /// that isolation, and Swift asserts the executor and kills the process when
  /// it runs elsewhere — the same trap `EvieAudioBufferSink` exists to avoid.
  private nonisolated static func requestSpeechRecognition() async
    -> SFSpeechRecognizerAuthorizationStatus
  {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status)
      }
    }
  }
}

/// The "Chave do PC" row. The rules and the import are EvieCore's
/// (`EvieGuidePCKeyStep`); this only puts them in the list.
@MainActor
struct PCKeyItem: PermissionGuideItem {
  let step: EvieGuidePCKeyStep

  func refreshStatus() { step.refreshStatus() }
  func observeRowChanges(_ onChange: @escaping @MainActor () -> Void) {
    step.onStatusChanged = onChange
  }

  func row(given record: PermissionGuideRecord) -> PermissionGuideRow {
    step.row
  }

  /// The macOS prompt this waits on is the keychain's, not a privacy
  /// permission's, so nothing is recorded as spent: the import can be tried
  /// again after a refusal.
  func perform(_ action: PermissionGuideRow.Action) async -> EviePermission? {
    if action.kind == .importPCKey {
      await step.importKey()
    }
    return nil
  }
}

/// The "Cérebro" row, which runs Testar conexão (`EvieGuideBrainStep`).
@MainActor
struct BrainConnectionItem: PermissionGuideItem {
  let step: EvieGuideBrainStep

  func row(given record: PermissionGuideRecord) -> PermissionGuideRow {
    step.row
  }

  func perform(_ action: PermissionGuideRow.Action) async -> EviePermission? {
    if action.kind == .testConnection {
      await step.testConnection()
    }
    return nil
  }
}
