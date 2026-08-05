# Project status

Last updated: 2026-08-05

## Current phase

**Phase 1 inference validation and Phase 2 native-shell prototyping are in
progress.**

VS-003 through VS-006 are implemented at source level.

Evie now has her own identity rather than presenting as a front end for a local
server: the hidden persona names her creator and how he is addressed, no surface
mentions the model or the inference server, and the loopback port moved to 38433
so it cannot collide with another project. The overlay can be moved, resized, and
reset; its height follows what SwiftUI actually measured, which is what fixed the
clipped background fade. The placeholder glyph became an ASCII key that tilts in
three dimensions and lights up only while something real is happening — idle CPU
with the overlay visible measured 0.0%, down from 8.1% in the first attempt.

Everything configurable is now reachable: a five-tab settings window covering
shortcuts, voice, appearance, model, and diagnostics, with every shortcut
recordable, disableable, and resettable, and conflicts or system refusals named in
place.

`Evie.app` exists with a stable bundle identifier. That was the hard blocker for
every permission Evie will ever need — measured, an unbundled binary touching the
microphone hangs forever rather than failing. The microphone and speech
recognition are implemented on top of it, but no audio has been transcribed: that
needs a grant which is deliberately left for the user.

She can also read. Images and PDFs, including scanned ones, are read through the
system's own text recognition with no model downloaded, verified end to end
against the model in Portuguese and against a document attempting prompt
injection.

The first half of filesystem access exists: a reader contained by the kernel
rather than by path-string checks, with the escapes proven by test. Nothing can
grant it a folder yet, so it is unreachable from the interface — that is the next
piece.

The Phase 0 planning foundation is complete enough to support bounded code work.
VS-001 and VS-002 are implemented at source level: the native shell now supports
continuous quick text, complete local visible-history records, resume/delete UI,
and non-secret model settings while retaining the transient overlay as default.
The local first-test slice now also has typed configuration and an explicit
development-runtime controller. On this target Mac, TurboFieldfare revision
`7a99f2a635e3adf7ed0720b882d2edb600f2f0da` has been cloned outside Git and its
release repacker/server products have built successfully. The Gemma download and
repack completed; the upstream verifier passed all 37 files, and model discovery,
non-streaming inference, and SSE inference passed on loopback at a declared 64K.
The VS-002 release shell has been rebuilt and relaunched against the healthy local
server. Model discovery, a synthetic non-streaming response, and SSE `[DONE]`
passed again. Shortcut, focus-after-completion, Spaces, display, history, settings,
cancellation, and visual behavior remain manual `QA-001`/`QA-005` work.

No Hermes runtime, persistent background service, account integration, or
credential has been installed or configured. Completed conversations are now
personal local state under `Application Support/Evie/Conversations`; they remain
outside Git and hidden prompts are never stored. TurboFieldfare source, model
state, configuration, PID state, and logs also remain under `~/Library`.

## Implementation snapshot

- `EvieCore` provides backend-neutral messages, phases, artifacts, reducer state,
  configuration, and an `AgentClient` protocol.
- `TurboFieldfareClient` streams Chat Completions from
  `http://127.0.0.1:8080/v1`, requires loopback, supports cancellation, and does
  not send or execute tools. Its byte-level SSE framing preserves empty event
  separators across arbitrary transport fragmentation and CR/LF variants.
- `evie-shell` is a SwiftUI/AppKit menu-bar development executable with a
  transparent floating `NSPanel`, launch-focused and repeatable quick text, native
  glass result cards, a deliberate history window, and a model-settings window.
- The composition root talks directly to TurboFieldfare only for this reversible
  slice. ADR 0006 records why this is not the future trust/lifecycle boundary.
- `EvieConfigurationLoader` applies built-in defaults, an optional versioned local
  JSON file, then supported environment overrides; invalid settings surface an
  actionable startup error and no credential is read or printed.
- `CORE-005` nominal read/propose/commit contracts now make authority opaque and
  non-serializable, bound serialized identifiers/collections/depth/bytes and plan
  lifetime, revalidate revision/binding, redact material metadata, and require
  explicit-user evidence for delete. There is deliberately no real tool executor
  yet.
- `Scripts/evie-runtime` provides an explicit development-only doctor, setup,
  configure, verify, start, stop, status, synthetic smoke, and shell-launch
  workflow. It pins the runtime and 64K launch shape but is not `evied`, a login
  item, an idle-unload policy, or crash recovery.
- `Scripts/test` is a compatibility wrapper for Swift Testing discovery/rpaths
  with the macOS 27 Command Line Tools present on this Mac.
- Complete visible conversations persist as schema-versioned per-session JSON with
  `0700`/`0600` permissions and atomic replacement. Model context is bounded from
  an in-memory copy independently, and termination waits for pending history
  writes. History scanning contains a malformed/unavailable failure to that
  individual file, retains readable sessions, and shows only an opaque
  unavailable-record count. There is still no semantic memory, prompt/result
  diagnostic logging, or RAG.
- The reusable waveform and the new reactive ring are present but receive no audio
  data; microphone capture, STT, TTS invocation/playback, and a configured personal
  voice are not active, and the UI says so. Clicking the mark asks for voice and is
  told plainly that voice is not wired yet.
- `EviePersona` generates the hidden system message from an explicit capability
  snapshot, so a capability cannot be described in prose without being built. Every
  flag is currently false except plain text.
- `EviePreferences` stores appearance, eight configurable shortcut actions, and the
  voice switches in a `preferences.json` separate from the model configuration. The
  call-mode/speech dependency is enforced in the type. No settings UI reaches it yet.
- `EvieOverlayGeometry` resolves the panel rectangle from preferences and connected
  displays; the overlay can be dragged, resized, and reset, and recovers to the
  anchored default when the saved display is disconnected.
- Current research pins a deny-by-default Hermes candidate, QMD/DDGS directions,
  and a native “E aí, ívi” wake-word path. None is installed or enabled by Evie.
- A backend-neutral TTS protocol and defensive source-only OmniVoice batch adapter are
  source implemented and synthetically tested. They do not load a model, generate
  real audio, inspect a voice profile, verify the configured executable identity,
  network-sandbox it, or connect to UI/playback yet.

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

The researched agent candidate is Hermes `v2026.8.3` at
`3c27eb6234bf91b8ceee9e9071591b31e9b148cb`, behind `evied` with native dangerous
toolsets disabled. The retrieval candidate is QMD `v2.5.3` behind an on-demand
collection-isolating worker; DDGS `v9.9.3` is the first no-key web-search prototype.
All pins remain uninstalled hypotheses until their gates pass.

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
- Visible completed conversations persist locally and are opened deliberately;
  hidden prompts, semantic memory, and action authority are excluded from history.
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
6. Text recognition is settled and measured; see `docs/VISION.md`. What remains
   open is image *understanding* — a chart, a screenshot, a photograph. Two routes
   exist and neither is pinned: the system vision model, measured at +15 MB in
   this process because it runs in a daemon, and the 0.81 GB projector for the
   model already installed, which would need the inference server to accept
   multimodal input.
7. Validate the source-implemented bottom-centered overlay and global command
   shortcuts without productizing them yet; focus, Spaces, full-screen,
   multiple-display, and accessibility behavior still require target QA.
8. Validate Node-RED draft/import/disable/approve/enable behavior through a narrow
   adapter without exposing unrestricted administration to the model.
9. Run `QA-005` for repeated follow-ups, restart/resume, deletion, environment-
   managed settings, and response-completion focus behavior.

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
- `Evie.app` exists but its signature is ad-hoc, which has no stable designated
  requirement, so the first permission granted will not survive a rebuild until
  `Scripts/evie-app identity` is run and the certificate is trusted for code
  signing in Keychain Access. That step cannot be scripted.
- The application is not notarized and is not a login item.
- No audio has been transcribed. Speech recognition is implemented and the system
  reports Brazilian Portuguese available with a one-time language pack, but
  accuracy, latency after that download, barge-in, and energy cost are unmeasured.
- Evie cannot speak, cannot reach folders, and cannot search the web. The
  preferences for the first exist and save; the interface says they are inactive.
- Nothing in VS-003 has been accepted by eye on the target display. Dragging,
  resizing, the reset control, the corrected fade, the legibility of the ASCII key
  at 30 points, and the light/dark palette are all `QA-006`.
- The development controller can explicitly health-check/start/stop the pinned
  TurboFieldfare server at `--max-context 65536`, but Evie's application does not
  own lifecycle, idle unload, crash recovery, power policy, or automatic startup.
- OmniVoice performance and the format of the user's existing voice assets have
  not been inspected locally.
- The target Mac has OmniVoice/Whisper tooling and model caches, and the source
  adapter validates the separate cached Higgs tokenizer requirement. No real Evie
  audio request, microphone permission, TTS output, STT benchmark, or personal
  voice-reference inspection has occurred.
- Before activation, the OmniVoice worker still needs a trusted pinned
  executable/model manifest, a version probe, startup cleanup of orphaned private
  temporary directories, and supervisor lifecycle integration.
- The exact smaller text and vision model candidates must be pinned immediately
  before benchmarking because this area changes quickly.
- Location triggers require a trusted source such as a phone shortcut, Home
  Assistant, or a dedicated companion; the Mac alone does not provide a complete
  personal location event stream.

## Next recommended action

Three things, in this order.

**`VOI-018` — let her speak.** The OmniVoice adapter exists, is defensively
written, and is connected to nothing. Native playback with sentence chunking,
output metering, cancellation, and barge-in closes the voice loop and removes the
last switch in Settings that describes something unbuilt.

**`SEC-002` and `INT-008` — let her read the Mac.** This is the user's own
standing request; she currently answers that folders are not connected, which is
accurate but is the gap he most wants closed. `docs/FILESYSTEM.md` carries the
full design. Reading is worth shipping before any write capability exists, and
there is deliberately no commit tool in the schema.

**`QA-006` — the human pass.** Nothing in the last four slices has been accepted
by eye. Dragging, resizing, the reset control, the corrected fade, the legibility
of the ASCII key at 30 points, and the palette in light and dark are all unproven.

Do not configure email, WhatsApp, Drive, file mutation, automatic microphone, or
workflow activation before their permission and validation gates pass.
