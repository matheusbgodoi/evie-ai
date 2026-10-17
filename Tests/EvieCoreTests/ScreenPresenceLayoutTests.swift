import CoreGraphics
import Foundation
import Testing

@testable import EvieCore

@Suite("Screen presence layout")
struct ScreenPresenceLayoutTests {
  // A 14-inch MacBook Pro at 1512×982 points. Its visible frame starts under a
  // 33-point menu bar, in the display-local top-left coordinates the presence
  // layers draw in.
  private let usableArea = CGRect(x: 0, y: 33, width: 1_512, height: 949)
  private let pillSize = CGSize(width: 320, height: 44)

  // MARK: - The pill

  @Test("the pill sits centred 8 points under the top of the usable area")
  func pillDefaultsToTopCentre() {
    let frame = ScreenPresenceLayout.pillFrame(
      size: pillSize, usableArea: usableArea, avoiding: nil)

    #expect(frame == CGRect(x: 596, y: 41, width: 320, height: 44))
  }

  @Test("a target well clear of the pill leaves it at the top")
  func distantTargetKeepsPillAtTop() {
    let target = CGRect(x: 700, y: 400, width: 120, height: 30)

    let frame = ScreenPresenceLayout.pillFrame(
      size: pillSize, usableArea: usableArea, avoiding: target)

    #expect(frame.minY == 41)
  }

  @Test("a target under the pill moves it to the bottom, 8 points above the usable edge")
  func overlappingTargetMovesPillToBottom() {
    let target = CGRect(x: 700, y: 50, width: 80, height: 20)

    let frame = ScreenPresenceLayout.pillFrame(
      size: pillSize, usableArea: usableArea, avoiding: target)

    #expect(frame == CGRect(x: 596, y: 982 - 8 - 44, width: 320, height: 44))
  }

  @Test("a target within 24 points of the pill counts as overlapping it")
  func clearanceIsPartOfTheOverlap() {
    // The pill ends at y = 85; this target starts 20 points below it.
    let near = CGRect(x: 700, y: 105, width: 80, height: 20)
    // And this one 30 points below it.
    let clear = CGRect(x: 700, y: 115, width: 80, height: 20)

    #expect(
      ScreenPresenceLayout.pillFrame(size: pillSize, usableArea: usableArea, avoiding: near).minY
        > 41)
    #expect(
      ScreenPresenceLayout.pillFrame(size: pillSize, usableArea: usableArea, avoiding: clear).minY
        == 41)
  }

  @Test("a target that would overlap the pill at either edge leaves it at the top")
  func tallTargetKeepsPillAtTop() {
    let target = CGRect(x: 600, y: 40, width: 300, height: 940)

    let frame = ScreenPresenceLayout.pillFrame(
      size: pillSize, usableArea: usableArea, avoiding: target)

    #expect(frame.minY == 41)
  }

  @Test("the pill is placed on whole points even on an odd-width display")
  func pillLandsOnWholePoints() {
    let odd = CGRect(x: 0, y: 25, width: 1_365, height: 743)

    let frame = ScreenPresenceLayout.pillFrame(size: pillSize, usableArea: odd, avoiding: nil)

    #expect(frame.minX == frame.minX.rounded())
  }

  // MARK: - The ghost cursor

  @Test("a short trip uses the fastest spring, a long one the slowest")
  func cursorResponseIsClamped() {
    let short = ScreenPresenceLayout.cursorTravel(
      from: CGPoint(x: 100, y: 100), to: CGPoint(x: 110, y: 100))
    let long = ScreenPresenceLayout.cursorTravel(
      from: .zero, to: CGPoint(x: 3_000, y: 2_000))

    #expect(short.responseX == 0.3)
    #expect(long.responseX == 0.6)
  }

  @Test("between the bounds the cursor spring grows with distance")
  func cursorResponseGrowsWithDistance() {
    // 600 points: 0.25 + 600 / 3000 = 0.45.
    let travel = ScreenPresenceLayout.cursorTravel(
      from: CGPoint(x: 0, y: 0), to: CGPoint(x: 360, y: 480))

    #expect(abs(travel.responseX - 0.45) < 1e-9)
  }

  @Test("the vertical spring is 10% slower than the horizontal one, giving the path an arc")
  func verticalSpringIsSlower() {
    let travel = ScreenPresenceLayout.cursorTravel(
      from: CGPoint(x: 0, y: 0), to: CGPoint(x: 360, y: 480))

    #expect(abs(travel.responseY - travel.responseX * 1.1) < 1e-9)
  }

  @Test("the cursor starts from the real pointer when it is on the same display")
  func cursorStartsAtPointer() {
    let start = ScreenPresenceLayout.cursorStart(
      target: CGPoint(x: 800, y: 500),
      pointer: CGPoint(x: 200, y: 300),
      displaySize: CGSize(width: 1_512, height: 982)
    )

    #expect(start == CGPoint(x: 200, y: 300))
  }

  @Test("without a pointer on the display the cursor starts 60 points below-left of the target")
  func cursorStartsBelowLeftOfTarget() {
    let start = ScreenPresenceLayout.cursorStart(
      target: CGPoint(x: 800, y: 500),
      pointer: nil,
      displaySize: CGSize(width: 1_512, height: 982)
    )

    #expect(start == CGPoint(x: 740, y: 560))
  }

  @Test("a start point that would fall off the display is kept on it")
  func cursorStartIsKeptOnTheDisplay() {
    let start = ScreenPresenceLayout.cursorStart(
      target: CGPoint(x: 20, y: 960),
      pointer: nil,
      displaySize: CGSize(width: 1_512, height: 982)
    )

    #expect(start == CGPoint(x: 0, y: 982))
  }

  // MARK: - The reticle

  @Test("the reticle's arms are 16 points, or a quarter of the shorter side of a small target")
  func reticleArmLength() {
    #expect(ScreenPresenceLayout.reticleArm(for: CGSize(width: 200, height: 120)) == 16)
    #expect(ScreenPresenceLayout.reticleArm(for: CGSize(width: 200, height: 40)) == 10)
    #expect(ScreenPresenceLayout.reticleArm(for: .zero) == 0)
  }
}
