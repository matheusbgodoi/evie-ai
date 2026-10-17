import AppKit
import SwiftUI

/// URLs are external input, not proof of a user gesture. Their capture route
/// opens this review; only its button can request the existing capture path.
@MainActor
final class NativeCaptureConsentController: NSObject, NSWindowDelegate {
  private var window: NSWindow?
  private var onConfirm: (() -> Void)?
  private var onDismiss: ((Bool) -> Void)?
  private var observers: [NSObjectProtocol] = []
  private let notificationCenter: NotificationCenter

  var isPresented: Bool { window != nil }

  init(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
    self.notificationCenter = notificationCenter
    super.init()
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification]
    {
      observers.append(
        notificationCenter.addObserver(
          forName: name, object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.dismiss(resumingListening: false)
          }
        })
    }
  }

  func present(onConfirm: @escaping () -> Void, onDismiss: @escaping (Bool) -> Void) {
    guard window == nil else { return }
    self.onConfirm = onConfirm
    self.onDismiss = onDismiss
    let created = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 488, height: 250),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    created.title = "Evie · Captura solicitada"
    created.identifier = NSUserInterfaceItemIdentifier("evie-native-capture-consent")
    created.isReleasedWhenClosed = false
    created.delegate = self
    created.contentView = NSHostingView(
      rootView: NativeCaptureConsentView(
        onCancel: { [weak self] in self?.dismiss() },
        onConfirm: { [weak self] in self?.confirm() }))
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
      let frame = screen.visibleFrame
      created.setFrameOrigin(
        NSPoint(x: frame.midX - created.frame.width / 2, y: frame.midY - created.frame.height / 2))
    } else {
      created.center()
    }
    window = created
    NSApp.activate()
    created.makeKeyAndOrderFront(nil)
  }

  func dismiss(resumingListening: Bool = true) {
    guard let window else { return }
    let callback = onDismiss
    onConfirm = nil
    onDismiss = nil
    self.window = nil
    window.delegate = nil
    window.close()
    callback?(resumingListening)
  }

  func shutdown() {
    dismiss(resumingListening: false)
    for observer in observers {
      notificationCenter.removeObserver(observer)
    }
    observers.removeAll()
  }

  func confirm() {
    guard isPresented, let callback = onConfirm else { return }
    dismiss(resumingListening: false)
    callback()
  }

  func windowWillClose(_ notification: Notification) {
    dismiss()
  }
}

private struct NativeCaptureConsentView: View {
  let onCancel: () -> Void
  let onConfirm: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Capturar a tela para a próxima pergunta?", systemImage: "viewfinder")
        .font(.headline)
      Text("Um atalho ou link pediu uma captura. A Evie só vai olhar depois da sua confirmação.")
      Text(
        "A tela sob o ponteiro fica na próxima pergunta, sem enviá-la automaticamente. O indicador de captura permanece visível."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancelar", action: onCancel)
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("evie-native-capture-cancel")
        Button("Capturar tela", action: onConfirm)
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("evie-native-capture-confirm")
      }
    }
    .padding(24)
    .frame(width: 440)
  }
}
