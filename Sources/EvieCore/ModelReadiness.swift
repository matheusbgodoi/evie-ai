/// How far a model endpoint is from answering, cheapest check first.
///
/// Only the rung exists so far: a turn carries it in `TurnOptions` so its
/// deadlines can match the model's state. The probe that measures it — `/health`,
/// then `/v1/models` with the key, never a POST — arrives in v2 S2b. Until then
/// every turn is sent with no rung, which keeps the configured request timeout.
public enum ReadinessRung: Sendable, Equatable {
  case unreachable
  case keyMissing
  case keyRejected
  case modelUnknown
  /// Known and authorised, but not loaded: the first request will wait for the
  /// load (measured 33–45 s for qwen-daily on the PC).
  case modelCold
  case ready
}
