/// What the PC gateway's readiness endpoints answer, so the probe is tested
/// against the server's real shapes rather than its documentation.
///
/// Recorded 2026-10-16 from this Mac against
/// `https://models.example.invalid` (gateway-edge in front of
/// llama-swap), with `qwen-daily` resident and every other alias unloaded. The
/// key was read from the keychain into a shell variable and never printed; no
/// recording holds a request header. What the recordings settled:
///
/// - `GET /health` sits at the **origin** and needs no key: 200 in 37 ms with the
///   body below. `GET /v1/health` is a 404 — the gateway answers `/health`
///   itself, before llama-swap.
/// - `GET /v1/models` and `GET /running` both need the key. Without it, or with
///   a wrong one, both answer 401 with `unauthorizedBody`.
/// - Each `/v1/models` entry carries the load state twice: llama-swap's own
///   `status.value` and the gateway's `metadata.loadState` plus `active`. An
///   alias that shares the resident model's weights (`qwen-uncensored`, whose
///   `physicalModelId` is `qwen-daily`) reports "loaded" too.
/// - `/running` lists only what is resident; an unloaded alias is simply absent.
enum GatewayReadinessFixtures {
  static let health = #"{"status": "ok", "upstream": "http://127.0.0.1:8080"}"#

  static let unauthorizedBody =
    #"{"error":"unauthorized: invalid or missing API key","src":"llama-swap"}"#

  /// `GET /v1/models`, verbatim except that the four entries were re-indented.
  static let models = #"""
    {"data":[
    {"id":"gemma-write","object":"model","created":1792175177,"owned_by":"llama-swap","name":"Gemma 4 26B-A4B (write)","meta":{"llamaswap":{"type":"model"}},"status":{"value":"unloaded"},"metadata":{"contextWindow":131072,"maxTokens":32768,"reasoning":false,"nativeReasoning":false,"tools":false,"vision":false,"displayName":"Gemma 4 26B-A4B","physicalModelId":"gemma-write","loadState":"unloaded","active":false}},
    {"id":"ornith-turbo","object":"model","created":1792175177,"owned_by":"llama-swap","name":"Ornith-1.5-35B-A3B (turbo)","meta":{"llamaswap":{"type":"model"}},"status":{"value":"unloaded"},"metadata":{"contextWindow":196608,"maxTokens":32768,"reasoning":false,"nativeReasoning":true,"tools":true,"vision":true,"displayName":"Ornith-1.5-35B-A3B","physicalModelId":"ornith-turbo","loadState":"unloaded","active":false}},
    {"id":"qwen-daily","object":"model","created":1792175177,"owned_by":"llama-swap","name":"Qwen3.8-27B (daily)","meta":{"llamaswap":{"type":"model"}},"status":{"value":"loaded"},"metadata":{"contextWindow":200704,"maxTokens":32768,"reasoning":true,"nativeReasoning":false,"tools":true,"vision":true,"displayName":"Qwen3.8-27B","behaviorProfile":"standard","behaviorProfileLabel":"Standard","behaviorProfileDefault":true,"physicalModelId":"qwen-daily","loadState":"loaded","active":true}},
    {"id":"qwen-uncensored","object":"model","created":1792175177,"owned_by":"llama-swap","name":"Qwen3.8-27B","meta":{"llamaswap":{"type":"model"}},"status":{"value":"loaded"},"metadata":{"contextWindow":200704,"maxTokens":32768,"reasoning":true,"nativeReasoning":false,"tools":true,"vision":true,"displayName":"Qwen3.8-27B","behaviorProfile":"uncensored","behaviorProfileLabel":"Uncensored","physicalModelId":"qwen-daily","loadState":"loaded","active":true}}
    ],"object":"list"}
    """#

  /// `GET /running`, verbatim except that `cmd` — the 40-line llama-server
  /// command line, with the PC's model paths — is cut to the
  /// binary's name.
  static let running = #"""
    {"running":[{"model":"qwen-daily","state":"ready","cmd":"llama-server","proxy":"http://127.0.0.1:5801","ttl":0,"name":"Qwen3.8-27B (daily)","description":""}]}
    """#

  /// A plain OpenAI-style list with no load state at all, the shape a server
  /// without llama-swap's metadata answers. Not a recording: it is the gateway's
  /// entry with `status` and `metadata` removed.
  static let modelsWithoutLoadState = #"""
    {"data":[{"id":"qwen-daily","object":"model","created":1792175177,"owned_by":"llama-swap"}],"object":"list"}
    """#
}

/// What a loopback mlx-vlm server answers, from the installed 0.7.8 source
/// (`mlx_vlm/server/app.py`, `health_check`), read 2026-10-16. Not a recording:
/// no local brain was running. The real body has more runtime fields; the probe
/// reads only `loaded_model`.
enum LocalBrainHealthFixtures {
  static func health(loadedModel: String?) -> String {
    let loaded = loadedModel.map { "\"\($0)\"" } ?? "null"
    return #"{"status":"healthy","loaded_model":"# + loaded
      + #","loaded_adapter":null,"loaded_models":[],"loaded_context_size":null}"#
  }
}
