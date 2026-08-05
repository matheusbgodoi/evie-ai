import CoreGraphics
import Foundation
import Testing

@testable import EvieCore

@Suite("Evie overlay geometry")
struct EvieOverlayGeometryTests {
  private let mainScreen = CGRect(x: 0, y: 0, width: 1_512, height: 916)
  private let secondScreen = CGRect(x: 1_512, y: 200, width: 1_920, height: 1_080)

  @Test("anchors to the bottom centre of the screen under the pointer by default")
  func anchorsByDefault() {
    let frame = EvieOverlayGeometry.resolveFrame(
      preferences: EvieAppearancePreferences(),
      contentHeight: 120,
      screens: [mainScreen, secondScreen],
      pointerScreen: secondScreen
    )

    #expect(frame.width == EvieAppearancePreferences.defaultOverlayWidth)
    #expect(frame.height == 120)
    #expect(frame.midX == secondScreen.midX)
    #expect(frame.minY == secondScreen.minY + EvieOverlayGeometry.bottomMargin)
  }

  @Test("falls back to the first screen when no pointer screen is known")
  func fallsBackToFirstScreen() {
    let frame = EvieOverlayGeometry.resolveFrame(
      preferences: EvieAppearancePreferences(),
      contentHeight: 120,
      screens: [mainScreen, secondScreen],
      pointerScreen: nil
    )

    #expect(frame.midX == mainScreen.midX)
  }

  @Test("honours a saved position instead of re-centring the window")
  func honoursSavedOrigin() {
    var appearance = EvieAppearancePreferences()
    appearance.overlayOrigin = EvieOverlayOrigin(x: 300, y: 500)

    let frame = EvieOverlayGeometry.resolveFrame(
      preferences: appearance,
      contentHeight: 200,
      screens: [mainScreen],
      pointerScreen: mainScreen
    )

    #expect(frame.origin == CGPoint(x: 300, y: 500))
    #expect(frame.height == 200)
  }

  @Test("keeps a saved position that has drifted slightly off screen usable")
  func clampsPartiallyOffscreenOrigin() {
    var appearance = EvieAppearancePreferences()
    appearance.overlayOrigin = EvieOverlayOrigin(x: 1_400, y: -60)

    let frame = EvieOverlayGeometry.resolveFrame(
      preferences: appearance,
      contentHeight: 200,
      screens: [mainScreen],
      pointerScreen: mainScreen
    )

    #expect(mainScreen.contains(frame))
    #expect(frame.maxX <= mainScreen.maxX)
    #expect(frame.minY >= mainScreen.minY)
  }

  @Test("returns to the anchored default when the saved display is gone")
  func recoversFromDisconnectedDisplay() {
    var appearance = EvieAppearancePreferences()
    appearance.overlayOrigin = EvieOverlayOrigin(x: 2_400, y: 800)

    let frame = EvieOverlayGeometry.resolveFrame(
      preferences: appearance,
      contentHeight: 140,
      screens: [mainScreen],
      pointerScreen: mainScreen
    )

    #expect(frame.midX == mainScreen.midX)
    #expect(frame.minY == mainScreen.minY + EvieOverlayGeometry.bottomMargin)
  }

  @Test("never renders shorter than the capsule or taller than the screen allows")
  func clampsHeight() {
    let short = EvieOverlayGeometry.resolveFrame(
      preferences: EvieAppearancePreferences(),
      contentHeight: 4,
      screens: [mainScreen],
      pointerScreen: mainScreen
    )
    #expect(short.height == EvieOverlayGeometry.minimumHeight)

    let tall = EvieOverlayGeometry.resolveFrame(
      preferences: EvieAppearancePreferences(),
      contentHeight: 10_000,
      screens: [mainScreen],
      pointerScreen: mainScreen
    )
    #expect(tall.height <= mainScreen.height)
    #expect(mainScreen.contains(tall))
  }

  @Test("a width wider than the display is reduced to fit it")
  func clampsWidthToScreen() {
    var appearance = EvieAppearancePreferences()
    appearance.overlayWidth = EvieAppearancePreferences.maximumOverlayWidth
    let narrowScreen = CGRect(x: 0, y: 0, width: 800, height: 600)

    let frame = EvieOverlayGeometry.resolveFrame(
      preferences: appearance,
      contentHeight: 120,
      screens: [narrowScreen],
      pointerScreen: narrowScreen
    )

    #expect(frame.width <= narrowScreen.width)
    #expect(narrowScreen.contains(frame))
  }

  @Test("resizing keeps the window centred on the point it already occupied")
  func resizeKeepsCentre() {
    let current = CGRect(x: 400, y: 300, width: 576, height: 200)

    let resized = EvieOverlayGeometry.resizedFrame(
      current: current,
      width: 800,
      screen: mainScreen
    )

    #expect(resized.width == 800)
    #expect(resized.midX == current.midX)
    #expect(resized.minY == current.minY)
    #expect(mainScreen.contains(resized))
  }

  @Test("resizing near an edge slides the window back into the display")
  func resizeStaysOnScreen() {
    let current = CGRect(x: 1_400, y: 300, width: 100, height: 200)

    let resized = EvieOverlayGeometry.resizedFrame(
      current: current,
      width: 900,
      screen: mainScreen
    )

    #expect(mainScreen.contains(resized))
    #expect(resized.width == 900)
  }

  @Test("records a moved window as an explicit custom position")
  func capturesMovedOrigin() {
    var appearance = EvieAppearancePreferences()
    let moved = CGRect(x: 120, y: 640, width: 576, height: 180)

    appearance.captureOrigin(of: moved)

    #expect(appearance.overlayOrigin == EvieOverlayOrigin(x: 120, y: 640))
    #expect(!appearance.isUsingDefaultPlacement)
  }
}
