import Foundation

/// Starts the brain that runs on this Mac, when a turn needs it.
///
/// The resolver asks only for a `.localOnDemand` profile whose server is not
/// already answering, and never for the PC. Starting it is the launcher's whole
/// job — the port check, the memory check, waiting for `/health`, stopping it
/// when idle (v2 S3) — so the resolver needs nothing from it but "running now, at
/// this address" or the reason it is not.
@MainActor
public protocol LocalBrainStarting {
  /// Returns once the server answers, with the endpoint it answers on; throws
  /// a `LocalizedError` whose description can be shown as it is.
  func ensureRunning() async throws -> URL
}

/// The launcher until v2 S3 ships one: there is nothing on this Mac Evie can
/// start yet, and it says so instead of letting the turn time out against a
/// port nobody listens on.
///
/// A Mac brain someone started by hand still answers: the resolver only calls a
/// launcher when the readiness probe found nothing serving.
public struct EvieLocalBrainNotInstalled: LocalBrainStarting {
  public struct Failure: LocalizedError, Equatable {
    public init() {}

    public var errorDescription: String? {
      "O cérebro do Mac ainda não está instalado nesta versão da Evie."
    }
  }

  public init() {}

  public func ensureRunning() async throws -> URL {
    throw Failure()
  }
}
