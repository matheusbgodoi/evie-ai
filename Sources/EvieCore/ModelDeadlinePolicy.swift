import Foundation

/// How long one turn may wait at each stage before it is given up on.
public struct ModelTurnDeadlines: Sendable, Equatable {
  /// The longest silence between bytes, as `URLRequest.timeoutInterval`.
  public var idleGap: TimeInterval
  /// From sending the request to its response headers.
  public var headers: Duration
  /// From the headers to the first reasoning, answer or tool-call token.
  public var firstToken: Duration

  public init(idleGap: TimeInterval, headers: Duration, firstToken: Duration) {
    self.idleGap = idleGap
    self.headers = headers
    self.firstToken = firstToken
  }
}

/// The deadlines a turn gets, chosen from what is known about the model.
///
/// **The headers deadline is not a connection check.** Measured 2026-10-16
/// against the PC gateway (llama.cpp behind gateway-edge, qwen-daily loaded):
/// the response headers arrived together with the first streamed chunk, 0.793 s
/// and 1.319 s into two requests whose prefill took 443 ms and 654 ms. The
/// server holds the headers until prefill ends, so the wait for headers *is* the
/// wait for the first token, and a screenshot's prefill on the PC's CPU
/// projector is 31–40 s. A deadline of a few seconds would cancel every turn
/// with an image; a dead PC is the readiness probe's to catch (`/health`, 3 s).
/// So a ready model gets the first-token allowance for its headers too, and the
/// separate first-token deadline still covers a server that sends its headers
/// early and then stalls.
public struct ModelDeadlinePolicy: Sendable, Equatable {
  static let maximumTurnSeconds: TimeInterval = 900
  private static let longPromptThresholdTokens = 16_384
  /// The idle gap once the model is known to be loaded.
  public var idleGap: TimeInterval
  /// The idle gap while it loads: llama-swap blocks the request for the whole
  /// load, measured 33–45 s for qwen-daily and up to 112 s for other aliases.
  public var coldIdleGap: TimeInterval
  /// Headers and first token for a text turn. The first call after idle was
  /// measured at 14.7 s.
  public var textResponse: Duration
  /// Headers and first token when the turn carries an image.
  public var imageResponse: Duration
  /// Headers while the model loads, matching llama-swap's 520 s health timeout
  /// with room to spare.
  public var coldHeaders: Duration

  public init(
    idleGap: TimeInterval,
    coldIdleGap: TimeInterval,
    textResponse: Duration,
    imageResponse: Duration,
    coldHeaders: Duration
  ) {
    self.idleGap = idleGap
    self.coldIdleGap = coldIdleGap
    self.textResponse = textResponse
    self.imageResponse = imageResponse
    self.coldHeaders = coldHeaders
  }

  public static let standard = ModelDeadlinePolicy(
    idleGap: 120,
    coldIdleGap: 600,
    textResponse: .seconds(60),
    imageResponse: .seconds(120),
    coldHeaders: .seconds(600)
  )

  /// With no rung — every turn until the readiness probe and the resolver
  /// exist — each stage keeps the configured request timeout. That was the only
  /// deadline before, and the loopback model's long prefills fit inside it.
  /// Above 16K estimated input tokens, reserve bounded prefill time as well.
  /// Zero preserves existing callers; readiness probes keep their own deadlines.
  public func deadlines(
    readiness: ReadinessRung?,
    carriesImage: Bool,
    configuration: EvieConfiguration,
    inputTokens: Int = 0
  ) -> ModelTurnDeadlines {
    let response = carriesImage ? imageResponse : textResponse
    let base: ModelTurnDeadlines
    switch readiness {
    case nil:
      let configured = configuration.requestTimeout
      base = ModelTurnDeadlines(
        idleGap: configured,
        headers: .seconds(configured),
        firstToken: .seconds(configured)
      )
    case .modelCold:
      base = ModelTurnDeadlines(idleGap: coldIdleGap, headers: coldHeaders, firstToken: response)
    case .ready, .unreachable, .keyMissing, .keyRejected, .modelUnknown:
      base = ModelTurnDeadlines(idleGap: idleGap, headers: response, firstToken: response)
    }
    guard inputTokens > Self.longPromptThresholdTokens else { return base }

    // Observed: ~3.14 ms/token for the Mac's 128K prefill, ~1.67 ms/token
    // for an uncached 150K PC prefill. Six ms/token plus 30 s is conservative
    // scheduling headroom, not a prediction or a universal tokenizer guarantee.
    // Explicit profile timeout and the existing resource ceiling still bound it.
    let reserve = min(
      Self.maximumTurnSeconds, configuration.requestTimeout, 30 + Double(inputTokens) * 0.006)
    return ModelTurnDeadlines(
      idleGap: max(base.idleGap, reserve),
      headers: max(base.headers, .seconds(reserve)),
      firstToken: max(base.firstToken, .seconds(reserve))
    )
  }
}

extension URLSessionConfiguration {
  /// The session every model client uses.
  ///
  /// Ephemeral, with no URL cache, because request bodies carry the conversation
  /// and sometimes a screenshot, and neither belongs on disk. The resource
  /// timeout caps a whole turn at fifteen minutes — longer than the largest
  /// thinking turn (16384 tokens at the measured ~48 tok/s is under six minutes)
  /// plus a cold load.
  public static var evieModel: URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForResource = ModelDeadlinePolicy.maximumTurnSeconds
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return configuration
  }
}
