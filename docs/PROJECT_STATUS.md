# Project status

Last updated: 2026-08-04

## Current phase

**Phase 1 inference validation and Phase 2 native-shell prototyping are in
progress.**

The Phase 0 planning foundation is complete enough to support bounded code work.
VS-001, the first native quick-text vertical slice, is implemented at source level.
The local first-test slice now also has typed configuration and an explicit
development-runtime controller. On this target Mac, TurboFieldfare revision
`7a99f2a635e3adf7ed0720b882d2edb600f2f0da` has been cloned outside Git and its
release repacker/server products have built successfully. The Gemma download and
repack completed; the upstream verifier passed all 37 files, and model discovery,
non-streaming inference, and SSE inference passed on loopback at a declared 64K.
The native shell and server are running for the user's test. Shortcut, focus,
Spaces, display, cancellation, and visual behavior remain manual `QA-001` work.

No Hermes runtime, persistent background service, integration, personal data, or
credential has been installed or configured. TurboFieldfare source, model state,
local configuration, PID state, and logs live under the user's `~/Library`
directories rather than in this repository.

## Implementation snapshot

- `EvieCore` provides backend-neutral messages, phases, artifacts, reducer state,
  configuration, and an `AgentClient` protocol.
- `TurboFieldfareClient` streams Chat Completions from
  `http://127.0.0.1:8080/v1`, requires loopback, supports cancellation, and does
  not send or execute tools. Its byte-level SSE framing preserves empty event
  separators across arbitrary transport fragmentation and CR/LF variants.
- `evie-shell` is a SwiftUI/AppKit menu-bar development executable with a
  transparent floating `NSPanel`, global shortcuts, quick-text entry, native glass
  surfaces, status states, and transient result/error cards.
- The composition root talks directly to TurboFieldfare only for this reversible
  slice. ADR 0006 records why this is not the future trust/lifecycle boundary.
- `EvieConfigurationLoader` applies built-in defaults, an optional versioned local
  JSON file, then supported environment overrides; invalid settings surface an
  actionable startup error and no credential is read or printed.
- `Scripts/evie-runtime` provides an explicit development-only doctor, setup,
  configure, verify, start, stop, status, synthetic smoke, and shell-launch
  workflow. It pins the runtime and 64K launch shape but is not `evied`, a login
  item, an idle-unload policy, or crash recovery.
- `Scripts/test` is a compatibility wrapper for Swift Testing discovery/rpaths
  with the macOS 27 Command Line Tools present on this Mac.
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

One toolchain observation is now established for this exact machine: the pinned
TurboFieldfare release server and repacker built with Apple Command Line Tools,
without a full Xcode installation. Upstream still specifies Xcode 26, so this does
not replace the upstream prerequisite or prove another installation will behave
the same way.

One bounded runtime observation is also established for this machine on AC power:
at 65,536 declared tokens the synthetic non-streaming request completed in 5.393 s
and the immediately following SSE request in 0.882 s. The warmed server had a
3,215 MB physical footprint, the native shell 18 MB, both sampled at 0.0% idle CPU,
and macOS reported 53% system-wide memory free. These tiny responses establish
wiring only; they are not the Phase 1 model/context/energy benchmark.

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

The bounded first-test readiness checks are complete: model repack, upstream
verification, loopback health at 65,536 tokens, model discovery, non-streaming and
SSE synthetic requests, and native process launch passed. These checks establish
readiness only; they are not the Phase 1 performance suite.

## Known blockers

- The bounded first-test measurements exist, but no sustained decode, long-context,
  16K/32K/64K comparison, battery, energy, or quality result exists yet.
- The SwiftPM shell launches and remains resident, but has not been manually
  accepted for shortcuts, focus, Spaces, displays, accessibility, cancellation,
  or rendered response behavior.
- The current shell is not a signed/notarized `.app`, login item, or packaged
  utility.
- The development controller can explicitly health-check/start/stop the pinned
  TurboFieldfare server at `--max-context 65536`, but Evie's application does not
  own lifecycle, idle unload, crash recovery, power policy, or automatic startup.
- OmniVoice performance and the format of the user's existing voice assets have
  not been inspected locally.
- The exact smaller text and vision model candidates must be pinned immediately
  before benchmarking because this area changes quickly.
- Location triggers require a trusted source such as a phone shortcut, Home
  Assistant, or a dedicated companion; the Mac alone does not provide a complete
  personal location event stream.

## Next recommended action

Run the manual `QA-001` shortcut/focus/visual checklist against the already running
local Evie, then stop it with the documented lifecycle command when desired. The
next product code task remains `CORE-002`, followed by `SUP-001`; the development
controller must not be mistaken for the future supervisor. Do not configure email,
WhatsApp, Drive, file mutation, microphone access, or automatic workflow activation
before their permission and validation gates pass.
