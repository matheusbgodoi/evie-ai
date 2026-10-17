import Foundation

/// Starts and watches the brain that runs on this Mac, for the turns that need
/// it.
///
/// The resolver asks only about a `.localOnDemand` profile, and never about the
/// PC. Everything about the process — the port and memory checks, waiting for
/// `/health`, recognising the server, stopping it when idle (ADR 0015) — is the
/// launcher's, so the resolver needs nothing from it but "serving now" or the
/// reason it is not.
@MainActor
public protocol LocalBrainStarting {
  /// Starts the profile's server unless it already serves the profile's port,
  /// and returns once it answers, with the endpoint it answers on — the one
  /// the turn is sent to. Throws a `LocalizedError` whose description can be
  /// shown as it is.
  func ensureRunning(_ profile: EvieModelProfile) async throws -> URL

  /// Whether what listens on the profile's port is the configured server,
  /// holding to the key it was started with: its endpoint when it is, nil
  /// when nothing listens; throws when another process holds the port. Asked
  /// before every turn on a brain the readiness probe found answering, since
  /// the probe cannot tell who answered.
  func isServing(_ profile: EvieModelProfile) async throws -> URL?

  /// A turn is using the brain now: its idle clock starts again.
  func noteUse()
}
