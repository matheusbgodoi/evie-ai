/// Streams recorded from the PC gateway, so the decoder is tested against what
/// the server really sends rather than against what its documentation says.
///
/// Recorded 2026-10-16 from this Mac against
/// `https://models.example.invalid/v1/chat/completions`, model
/// `qwen-daily` (llama.cpp `b1-749f688` behind gateway-edge), `max_tokens` 64,
/// `stream_options.include_usage` on. Each chunk below is a verbatim line of the
/// recording; the only edit is that runs of identical-shape reasoning chunks were
/// cut down to a few, and the `timings` object is shortened. No header of the
/// request — the key included — is in a recording, which holds only the
/// response body.
///
/// What the recordings settled:
/// - with thinking on, the trace arrives as `delta.reasoning_content`, one token
///   per chunk, and the answer follows in `delta.content` with no `<think>` tag;
/// - with thinking off and a tool declared, the call arrives as
///   `delta.tool_calls[{index, id, type, function:{name, arguments}}]` in the first
///   fragment, then `{index, function:{arguments}}` fragments, and finishes with
///   `finish_reason:"tool_calls"`;
/// - the first chunk is always a role-only delta with `content:null`;
/// - usage comes in its own chunk with `choices:[]`, after the finish reason;
/// - the response headers arrived together with the first chunk (0.793 s and
///   1.319 s into the two requests, against `prompt_ms` of 443 and 654): the
///   headers wait for prefill to finish, which is why the headers deadline cannot
///   be a few seconds (see `ModelDeadlinePolicy`).
enum GatewayStreamFixtures {
  /// `chat_template_kwargs: {enable_thinking: true, reasoning_effort: "low",
  /// preserve_thinking: false}`, asked "Quanto é 2+2?".
  static let thinkingLow = sse([
    #"{"choices":[{"finish_reason":null,"index":0,"delta":{"role":"assistant","content":null}}],"created":1792173315,"id":"chatcmpl-l9EbWU6cgUcYGVZVBLh2o5ANgwxcA8KJ","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk"}"#,
    #"{"choices":[{"finish_reason":null,"index":0,"delta":{"reasoning_content":"The"}}],"created":1792173315,"id":"chatcmpl-l9EbWU6cgUcYGVZVBLh2o5ANgwxcA8KJ","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk"}"#,
    #"{"choices":[{"finish_reason":null,"index":0,"delta":{"reasoning_content":" user"}}],"created":1792173315,"id":"chatcmpl-l9EbWU6cgUcYGVZVBLh2o5ANgwxcA8KJ","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk"}"#,
    #"{"choices":[{"finish_reason":null,"index":0,"delta":{"reasoning_content":" is"}}],"created":1792173315,"id":"chatcmpl-l9EbWU6cgUcYGVZVBLh2o5ANgwxcA8KJ","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk"}"#,
    #"{"choices":[{"finish_reason":null,"index":0,"delta":{"reasoning_content":" asking"}}],"created":1792173315,"id":"chatcmpl-l9EbWU6cgUcYGVZVBLh2o5ANgwxcA8KJ","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk"}"#,
    #"{"choices":[{"finish_reason":null,"index":0,"delta":{"reasoning_content":" é"}}],"created":1792173315,"id":"chatcmpl-l9EbWU6cgUcYGVZVBLh2o5ANgwxcA8KJ","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk"}"#,
    #"{"choices":[{"finish_reason":null,"index":0,"delta":{"reasoning_content":"\n"}}],"created":1792173316,"id":"chatcmpl-l9EbWU6cgUcYGVZVBLh2o5ANgwxcA8KJ","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk"}"#,
    #"{"choices":[{"finish_reason":null,"index":0,"delta":{"content":"4"}}],"created":1792173316,"id":"chatcmpl-l9EbWU6cgUcYGVZVBLh2o5ANgwxcA8KJ","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk"}"#,
    #"{"choices":[{"finish_reason":null,"index":0,"delta":{"content":"."}}],"created":1792173316,"id":"chatcmpl-l9EbWU6cgUcYGVZVBLh2o5ANgwxcA8KJ","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk"}"#,
    #"{"choices":[{"finish_reason":"stop","index":0,"delta":{}}],"created":1792173316,"id":"chatcmpl-l9EbWU6cgUcYGVZVBLh2o5ANgwxcA8KJ","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk"}"#,
    #"{"choices":[],"created":1792173316,"id":"chatcmpl-l9EbWU6cgUcYGVZVBLh2o5ANgwxcA8KJ","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk","usage":{"completion_tokens":43,"prompt_tokens":57,"total_tokens":100,"prompt_tokens_details":{"cached_tokens":0}},"timings":{"cache_n":0,"prompt_n":57,"prompt_ms":442.65,"predicted_n":43,"predicted_ms":717.096,"draft_n":34,"draft_n_accepted":27}}"#,
    "[DONE]",
  ])

  /// What `thinkingLow` must decode to.
  static let thinkingLowReasoning = "The user is asking é\n"
  static let thinkingLowAnswer = "4."

  /// `chat_template_kwargs: {enable_thinking: false}`, one `calculate` tool,
  /// `parallel_tool_calls: false`, asked "Quanto é 17*23? Use a ferramenta.".
  static let toolCallThinkingOff = sse([
    #"{"choices":[{"finish_reason":null,"index":0,"delta":{"role":"assistant","content":null}}],"created":1792173317,"id":"chatcmpl-GHDI0SwQh36wKO5GWPFJcsSqzQSUyM1U","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk"}"#,
    #"{"choices":[{"finish_reason":null,"index":0,"delta":{"tool_calls":[{"index":0,"id":"rbFw91QB0xhGyuSWJSOUcR55cLs4lJgj","type":"function","function":{"name":"calculate","arguments":"{"}}]}}],"created":1792173317,"id":"chatcmpl-GHDI0SwQh36wKO5GWPFJcsSqzQSUyM1U","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk"}"#,
    #"{"choices":[{"finish_reason":null,"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"expression\":\""}}]}}],"created":1792173317,"id":"chatcmpl-GHDI0SwQh36wKO5GWPFJcsSqzQSUyM1U","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk"}"#,
    #"{"choices":[{"finish_reason":null,"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"1"}}]}}],"created":1792173317,"id":"chatcmpl-GHDI0SwQh36wKO5GWPFJcsSqzQSUyM1U","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk"}"#,
    #"{"choices":[{"finish_reason":null,"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"7"}}]}}],"created":1792173317,"id":"chatcmpl-GHDI0SwQh36wKO5GWPFJcsSqzQSUyM1U","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk"}"#,
    #"{"choices":[{"finish_reason":null,"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"*"}}]}}],"created":1792173317,"id":"chatcmpl-GHDI0SwQh36wKO5GWPFJcsSqzQSUyM1U","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk"}"#,
    #"{"choices":[{"finish_reason":null,"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"2"}}]}}],"created":1792173317,"id":"chatcmpl-GHDI0SwQh36wKO5GWPFJcsSqzQSUyM1U","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk"}"#,
    #"{"choices":[{"finish_reason":null,"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"3"}}]}}],"created":1792173317,"id":"chatcmpl-GHDI0SwQh36wKO5GWPFJcsSqzQSUyM1U","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk"}"#,
    #"{"choices":[{"finish_reason":null,"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\""}}]}}],"created":1792173317,"id":"chatcmpl-GHDI0SwQh36wKO5GWPFJcsSqzQSUyM1U","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk"}"#,
    #"{"choices":[{"finish_reason":null,"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"}"}}]}}],"created":1792173317,"id":"chatcmpl-GHDI0SwQh36wKO5GWPFJcsSqzQSUyM1U","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk"}"#,
    #"{"choices":[{"finish_reason":"tool_calls","index":0,"delta":{}}],"created":1792173318,"id":"chatcmpl-GHDI0SwQh36wKO5GWPFJcsSqzQSUyM1U","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk"}"#,
    #"{"choices":[],"created":1792173318,"id":"chatcmpl-GHDI0SwQh36wKO5GWPFJcsSqzQSUyM1U","model":"qwen-daily","system_fingerprint":"b1-749f688","object":"chat.completion.chunk","usage":{"completion_tokens":30,"prompt_tokens":298,"total_tokens":328,"prompt_tokens_details":{"cached_tokens":0}},"timings":{"cache_n":0,"prompt_n":298,"prompt_ms":653.651,"predicted_n":30,"predicted_ms":447.56,"draft_n":20,"draft_n_accepted":20}}"#,
    "[DONE]",
  ])

  static let toolCallID = "rbFw91QB0xhGyuSWJSOUcR55cLs4lJgj"
  static let toolCallArguments = #"{"expression":"17*23"}"#

  /// Frames each payload the way the gateway does: `data: ` and a blank line.
  static func sse(_ payloads: [String]) -> String {
    payloads.map { "data: \($0)\n\n" }.joined()
  }
}
