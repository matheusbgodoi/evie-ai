# Project status

Last updated: 2026-08-04

## Current phase

**Phase 1 inference validation and Phase 2 native-shell prototyping are in
progress.**

The Phase 0 planning foundation is complete enough to support bounded code work.
VS-001, the first native quick-text vertical slice, is implemented at source level
and compiles with Swift 6. Target-Mac UI behavior and real Gemma inference remain
deferred to `QA-001`; this status does not claim operational validation.

This repository has not installed or downloaded TurboFieldfare, model weights,
Hermes, a background service, an integration, or credentials.

## Implementation snapshot

- `EvieCore` provides backend-neutral messages, phases, artifacts, reducer state,
  configuration, and an `AgentClient` protocol.
- `TurboFieldfareClient` streams Chat Completions from
  `http://127.0.0.1:8080/v1`, requires loopback, supports cancellation, and does
  not send or execute tools.
- `evie-shell` is a SwiftUI/AppKit menu-bar development executable with a
  transparent floating `NSPanel`, global shortcuts, quick-text entry, native glass
  surfaces, status states, and transient result/error cards.
- The composition root talks directly to TurboFieldfare only for this reversible
  slice. ADR 0006 records why this is not the future trust/lifecycle boundary.
- Conversation context exists only in process memory. There is no prompt/result
  logging or persistent history.
- The reusable waveform is present but receives no audio data; microphone capture,
  STT, and TTS are not implemented and the UI says so.

See `docs/implementation/VS_001.md` and the task ledger for exact boundaries and
handoff evidence.

## Current conclusion

The project is viable on a base Apple M5 MacBook Pro with 24 GB unified memory if
heavy components are isolated and loaded on demand.

The preferred first technical hypothesis is:

- Hermes Agent as the tool and session runtime;
- TurboFieldfare serving Gemma 4 26B-A4B IT at a declared 64K context;
- FP16 KV cache for the baseline; prior Q4 work failed upstream quality/speed gates,
  and Q8/hybrid KV is deferred unless measurements justify custom kernels;
- a native macOS overlay and supervisor that remain lightweight while idle;
- separate on-demand workers for vision, RAG indexing/reranking, STT, and
  OmniVoice TTS;
- Node-RED for deterministic visual workflows;
- a read/propose/commit permission boundary for every integration.

This remains a hypothesis until the Phase 1 benchmarks pass.

## Decisions accepted for planning

- The product name is **Evie**, pronounced "ee-vee"/"ívi".
- The default interaction is not a chat window. It is a transient voice/command
  overlay with expandable result cards; full history is secondary.
- The high-quality Gemma model is preserved as the primary candidate instead of
  being replaced prematurely by a smaller model.
- Simple known commands should bypass an LLM when a deterministic action exists.
- Vision and TTS are specialist workers, not permanent parts of the main model.
- Heavy processes must support idle unload and pressure-aware eviction.
- Real credentials and personal state are configured locally but never committed.
- All future commits must maintain status, worklog, changelog, and relevant design
  documentation.
- The first executable uses a backend-neutral core plus a direct, loopback-only
  TurboFieldfare adapter; supervisor/Hermes integration remains a later phase.
- A UI state must be backed by observed activity. VS-001 never claims microphone,
  tool, or external-action activity.

See the ADR index for decision status.

## Open validation gates

1. Measure TurboFieldfare on the exact base M5/24 GB machine at 16K, 32K, and 64K:
   peak/resident memory, prompt processing, first-token latency, decode rate,
   correctness, idle resource use, and cold/warm startup.
2. Confirm Hermes core tool schemas are accepted by TurboFieldfare's supported JSON
   Schema subset and complete multi-step calls reliably.
3. Compare the primary Gemma with at least one 4B-class and one 9B-class local
   model on the Evie evaluation suite.
4. Benchmark local STT candidates on Brazilian Portuguese and noisy microphone
   input.
5. Benchmark OmniVoice MPS cold start, warm generation, peak memory, real-time
   factor, and sentence chunking on this Mac.
6. Select a local VLM only after image/OCR tasks and resource ceilings are defined.
7. Validate the source-implemented bottom-centered overlay and global command
   shortcuts without productizing them yet; focus, Spaces, full-screen,
   multiple-display, and accessibility behavior still require target QA.
8. Validate Node-RED draft/import/disable/approve/enable behavior through a narrow
   adapter without exposing unrestricted administration to the model.

## Known blockers

- No measured base-M5 TurboFieldfare numbers exist in this repository yet.
- The SwiftPM shell has compiled but has not been launched or manually accepted on
  the target Mac in this milestone.
- The current shell is not a signed/notarized `.app`, login item, or packaged
  utility.
- TurboFieldfare must be started manually with a model path and
  `--max-context 65536`; Evie does not yet own health/start/stop/idle unload.
- OmniVoice performance and the format of the user's existing voice assets have
  not been inspected locally.
- The exact smaller text and vision model candidates must be pinned immediately
  before benchmarking because this area changes quickly.
- Location triggers require a trusted source such as a phone shortcut, Home
  Assistant, or a dedicated companion; the Mac alone does not provide a complete
  personal location event stream.

## Next recommended action

Keep `QA-001` deferred until the user is ready. The next bounded code task is
`CORE-002`, the versioned command/event envelope required by local IPC; then
`SUP-001` can select the supervisor/IPC shape before model health, start/stop,
cancellation, and idle unload move out of the UI process. Do not configure email,
WhatsApp, Drive, file mutation, microphone access, or automatic workflow activation
before their permission and validation gates pass.
