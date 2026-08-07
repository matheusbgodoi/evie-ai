import SwiftUI

/// The status line along the bottom of a settings pane.
///
/// Five panes drew this by hand, twelve identical lines each, and the copies had
/// already begun to drift: the settings window rendered the icon hierarchically
/// and the four other panes did not. Feedback that changes shape depending on
/// which pane a person is looking at reads as a different kind of message, so
/// there is one of these now and changing how it looks is one edit.
struct SettingsFeedbackBar: ViewModifier {
  /// A message and a flag rather than a shared type, because each view model
  /// declares its own `Feedback`. Promoting one of them into something the other
  /// four import would trade this duplication for a worse coupling.
  let message: String?
  let isError: Bool

  func body(content: Content) -> some View {
    content.safeAreaInset(edge: .bottom) {
      if let message {
        Label(
          message,
          systemImage: isError
            ? "exclamationmark.triangle.fill"
            : "checkmark.circle.fill"
        )
        .font(.callout)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(isError ? .red : .secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.bar)
      }
    }
  }
}

extension View {
  /// Puts the pane's last message at the bottom, or nothing when there is none.
  func settingsFeedback(_ message: String?, isError: Bool) -> some View {
    modifier(SettingsFeedbackBar(message: message, isError: isError))
  }
}
