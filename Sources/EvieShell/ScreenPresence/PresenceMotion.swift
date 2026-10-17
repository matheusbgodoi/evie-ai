import AppKit
import QuartzCore

/// The curves and springs every presence layer moves with, in one place so the
/// indicator moves as one thing.
///
/// All of it is Core Animation: once an animation is added, the render server
/// interpolates it and this process does no work per frame. That is what lets
/// an indicator that may stay up for a whole agent session cost close to
/// nothing (`docs/MACOS_RUNTIME.md`).
///
/// Every animation starts from the layer's *presentation* value — where it is
/// on screen right now — so any of them can be redirected mid-flight without
/// a jump. None bounces: nothing here is thrown by a gesture, so there is no
/// momentum to carry, and overshoot on a status indicator reads as noise.
///
/// The shared values are `nonisolated(unsafe)` because the layers that read
/// them are not actor-isolated types; every one of them is only ever touched
/// on the main thread, as Core Animation and AppKit require.
enum PresenceMotion {
  /// Entrances and anything that should answer at once.
  nonisolated(unsafe) static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
  /// Movement across the screen that is not a spring: the one-time sweep.
  nonisolated(unsafe) static let easeInOut = CAMediaTimingFunction(controlPoints: 0.77, 0, 0.175, 1)

  /// Set by `--presence-demo --reduced-motion`, so the reduced variants can be
  /// reviewed without changing the user's accessibility settings.
  nonisolated(unsafe) static var forcesReducedMotion = false

  /// Reduce Motion changes only the motion: every state still appears, as
  /// fades instead of travel.
  static var reducesMotion: Bool {
    forcesReducedMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  /// Sets `keyPath` on `layer` to `value` and animates it there with a
  /// critically damped spring of perceptual duration `response`, starting
  /// from wherever the layer currently is on screen.
  static func spring(
    _ layer: CALayer, _ keyPath: String, to value: Any, response: Double, delay: Double = 0
  ) {
    let animation = CASpringAnimation(perceptualDuration: response, bounce: 0)
    animation.duration = animation.settlingDuration
    animate(layer, keyPath, to: value, with: animation, delay: delay)
  }

  /// The same, with a fixed duration and curve.
  static func ease(
    _ layer: CALayer, _ keyPath: String, to value: Any, duration: Double,
    curve: CAMediaTimingFunction = easeOut, delay: Double = 0
  ) {
    let animation = CABasicAnimation()
    animation.duration = duration
    animation.timingFunction = curve
    animate(layer, keyPath, to: value, with: animation, delay: delay)
  }

  /// Sets a value with no animation at all, for state that has to be right
  /// before the layer is first seen.
  static func set(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
  }

  private static func animate(
    _ layer: CALayer, _ keyPath: String, to value: Any, with animation: CABasicAnimation,
    delay: Double
  ) {
    let current = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
    animation.keyPath = keyPath
    animation.fromValue = current
    animation.toValue = value
    if delay > 0 {
      animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
      animation.fillMode = .backwards
    }
    set { layer.setValue(value, forKeyPath: keyPath) }
    // Keyed by the property, so a new animation replaces the one in flight
    // instead of stacking on top of it.
    layer.add(animation, forKey: keyPath)
  }
}
