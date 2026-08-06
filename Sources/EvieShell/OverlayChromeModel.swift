import EvieCore
import Foundation
import SwiftUI

/// The window's own state, kept separate from the conversation view model.
///
/// Moving, resizing, and hiding the overlay has nothing to do with what Evie is
/// saying, and mixing the two makes both harder to reason about.
///
/// It also holds the small pieces of transient view state that would normally be
/// `@State`. This toolchain has the macOS Command Line Tools without full Xcode,
/// and SwiftUI's `@State` macro plugin ships only with Xcode, so view-local
/// state lives in an observable object instead. See `docs/MACOS_RUNTIME.md`.
@MainActor
final class OverlayChromeModel: ObservableObject {
  @Published private(set) var contentWidth: CGFloat
  @Published private(set) var isUsingDefaultPlacement: Bool
  @Published private(set) var isVisible = false
  /// When false the mark holds a single static frame. Some people simply do not
  /// want a moving thing on screen all day.
  @Published private(set) var animatesLogo: Bool
  /// In call mode the overlay is only the mark and its ring — no field, no cards,
  /// nothing written.
  @Published private(set) var isCallMode = false
  /// True while the pointer is over the overlay, which reveals the handles.
  @Published private(set) var isShowingHandles = false
  /// Height of the artifact list as SwiftUI actually laid it out.
  @Published private(set) var artifactContentHeight: CGFloat = 0

  /// Called while a width handle is dragged, with the total travel since the
  /// gesture began. Sending the total rather than a delta keeps the handle
  /// itself stateless.
  var onWidthDrag: ((CGFloat) -> Void)?
  /// Called once the drag ends, so the value is written to disk only once.
  var onWidthCommit: (() -> Void)?
  var onMeasuredHeight: ((CGFloat) -> Void)?

  init(appearance: EvieAppearancePreferences = EvieAppearancePreferences()) {
    contentWidth = appearance.resolvedOverlayWidth
    isUsingDefaultPlacement = appearance.isUsingDefaultPlacement
    animatesLogo = appearance.animatesLogo
  }

  func apply(_ appearance: EvieAppearancePreferences) {
    contentWidth = appearance.resolvedOverlayWidth
    isUsingDefaultPlacement = appearance.isUsingDefaultPlacement
    animatesLogo = appearance.animatesLogo
  }

  func setCallMode(_ isOn: Bool) {
    guard isOn != isCallMode else {
      return
    }
    isCallMode = isOn
  }

  func setVisible(_ visible: Bool) {
    guard visible != isVisible else {
      return
    }
    isVisible = visible
    if !visible {
      isShowingHandles = false
    }
  }

  func setShowingHandles(_ showing: Bool) {
    guard showing != isShowingHandles else {
      return
    }
    isShowingHandles = showing
  }

  func setArtifactContentHeight(_ height: CGFloat) {
    guard height.isFinite, abs(height - artifactContentHeight) > 0.5 else {
      return
    }
    artifactContentHeight = height
  }
}
