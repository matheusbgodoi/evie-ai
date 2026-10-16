import AppKit
import EvieCore

/// The first-run checklist's state, shared by the guide window and the
/// "Permissões" pane in Settings so both always show the same answer.
@MainActor
final class PermissionGuideViewModel: ObservableObject {
  @Published private(set) var rows: [PermissionGuideRow] = []
  /// False for a bare `swift build` binary. TCC would attribute every request
  /// to the terminal that launched it, so the guide shows the state but offers
  /// no buttons.
  let isBundled: Bool

  private let items: [any PermissionGuideItem]
  private let store: PermissionGuideStore
  private var record: PermissionGuideRecord
  /// Never removed: the coordinator owns one of these for the life of the
  /// process.
  private var activationObserver: (any NSObjectProtocol)?

  init(items: [any PermissionGuideItem], store: PermissionGuideStore, isBundled: Bool) {
    self.items = items
    self.store = store
    self.isBundled = isBundled
    record = store.load()
    refresh()

    // macOS posts nothing when a switch flips in System Settings. Coming back
    // from there means clicking Evie, which activates her, so activation is
    // when the rows are read again — no polling.
    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.refresh()
      }
    }
  }

  /// The rows the guide shows, in the order it shows them.
  ///
  /// The one place a row is added.
  static func standardItems(audioCapture: EvieAudioCapture) -> [any PermissionGuideItem] {
    // TODO(S7-brain-rows): append the "Chave do PC" row and the "Cérebro" row
    // here. Both exist as EvieCore calls since v2 S2d: the import is
    // `EvieModelKeys.live.importPCConfigurationKey(into:)` (with the
    // explanation of the macOS prompt shown before the button, as in
    // Configurações › Cérebro), and Testar conexão is
    // `ModelReadinessProbe.connectionReport(for:)`. See docs/MACOS_RUNTIME.md,
    // "First-run guide".
    EviePermission.allCases.map { permission in
      SystemPermissionItem(permission: permission, audioCapture: audioCapture)
    }
  }

  /// Opens by itself until it has been closed once, and never for a copy that
  /// cannot be granted anything.
  var opensAtLaunch: Bool {
    isBundled && !record.dismissed
  }

  var allSatisfied: Bool {
    rows.allSatisfy { $0.mark == .satisfied }
  }

  func refresh() {
    rows = items.map { $0.row(given: record) }
  }

  func perform(_ action: PermissionGuideRow.Action, onRow rowID: PermissionGuideRow.ID) async {
    // `rows` is built from `items` in order, so a row's position is its item's.
    guard isBundled, let index = rows.firstIndex(where: { $0.id == rowID }) else {
      return
    }
    if let spent = await items[index].perform(action) {
      record.requested.insert(spent)
      persist()
    }
    refresh()
  }

  func markDismissed() {
    guard !record.dismissed else {
      return
    }
    record.dismissed = true
    persist()
  }

  /// A record that fails to save costs one extra look at the checklist on the
  /// next launch, which is not worth interrupting anyone over.
  private func persist() {
    try? store.save(record)
  }
}
