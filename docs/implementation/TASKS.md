# Evie implementation task ledger

Last updated: 2026-08-05

This is the execution backlog for Evie. It complements `docs/ROADMAP.md`: the
roadmap defines product gates, while this ledger defines bounded implementation
tasks, dependencies, completion evidence, and handoff rules. Task IDs are stable;
completed IDs are never renamed or reused.

## Status vocabulary

| Status | Meaning |
|---|---|
| `PLANNED` | Defined but not ready or not yet claimed. |
| `READY` | Dependencies are satisfied and an agent may claim it. |
| `IN PROGRESS` | Claimed by exactly one owner with a bounded file scope. |
| `BLOCKED` | Cannot proceed; the blocking dependency or decision is recorded. |
| `DEFERRED` | Intentionally postponed by scope or user direction. |
| `DONE` | Implementation and required evidence meet the task's definition of done. |

Documentation status is not runtime status. A task is not `DONE` merely because a
design exists, and target-hardware behavior is not validated until measurements
are recorded with the required metadata.

## Current implementation decision

### VS-001 — Native quick-text vertical slice — `DONE` (source); `QA-001` deferred

The first vertical slice implements the smallest honest end-to-end Evie surface:

```text
global shortcut / menu bar
          |
          v
native NSPanel + quick-text pill + visual waveform
          |
          v
EvieCore backend-neutral contracts
          |
          v
TurboFieldfare OpenAI-compatible streaming client
          |
          v
Gemma 4 26B-A4B IT on loopback
          |
          v
streamed response in a transient glass artifact card
```

Included now:

- Swift Package foundation and the `EvieCore` library;
- native AppKit/SwiftUI application, menu-bar item, and transient `NSPanel`;
- global shortcuts for summon/dismiss and quick text;
- CLUI-CC-inspired native glass pill, waveform, state, and result cards;
- backend-neutral interaction/configuration models;
- streaming Chat Completions client for a manually started TurboFieldfare server;
- cancellation, unavailable-server state, and recoverable error presentation.

Explicitly excluded from VS-001:

- Hermes installation, sessions, tools, memory, or agent loop;
- microphone capture, push-to-talk, wake word, STT, TTS, or OmniVoice;
- starting, stopping, or downloading TurboFieldfare/model assets;
- RAG, vision, Node-RED, accounts, credentials, and personal integrations;
- persistent chat/history and write-capable actions.

Adjacent development tooling now prepares the same text-only path for its first
local test. It does not expand VS-001 into a supervisor or add any excluded user
capability.

The waveform in this slice is a data-driven visual component with no internal
timer, but the application supplies no audio samples yet. It must not claim that
the microphone is listening. Real input and output metering begins at `VOI-002`.

### VS-001 task registry

| ID | Status | Current owner/scope | Depends on | Done when |
|---|---|---|---|---|
| `FND-001` | `DONE` | coordinating agent — `Package.swift`, application entry points | — | SwiftPM declares macOS 15+, `EvieCore`, and `EvieShell`; `swift build` succeeds without installing a model runtime. |
| `CORE-001` | `DONE` | `core_impl` — interaction, message, artifact, and configuration types | `FND-001` | Public models are backend-neutral, `Sendable` where appropriate, and encode the UI states required by this slice without Hermes-specific names. |
| `INF-001` | `DONE` | `core_impl` — `AgentClient` and TurboFieldfare client | `CORE-001` | A loopback-only client streams text deltas, reports typed failures, supports cancellation, and does not log prompt or response bodies by default. |
| `UI-001` | `DONE` | coordinating agent — app lifecycle and menu bar | `FND-001`, `CORE-001` | Evie builds as a menu-bar utility, exposes show/hide/quit controls, and has no ordinary main chat window. |
| `UI-002` | `DONE` | coordinating agent — `NSPanel` host/window behavior | `UI-001` | Source configures a transparent floating panel across Spaces and only makes it key for deliberate text entry; target behavior remains `QA-001`. |
| `UI-003` | `DONE` | coordinating agent — global shortcuts | `UI-001`, `UI-002` | Fixed prototype shortcuts summon/dismiss and open quick text without a broad keyboard monitor; registration failure is presented visibly. |
| `UI-004` | `DONE` | `ui_impl` — glass surfaces, status pill, waveform | `CORE-001` | The compact native-glass pill renders honest idle/loading/streaming/error states; no internal idle waveform timer exists and accessibility settings are handled in source. |
| `UI-005` | `DONE` | `ui_impl` + coordinating integration — quick-text input | `UI-002`, `UI-003`, `UI-004` | Source supports focus, non-empty submit, Escape dismissal, empty-input suppression, and no fake voice state; target focus restoration remains `QA-001`. |
| `UI-006` | `DONE` | `ui_impl` — artifact card and bottom-anchored stack | `UI-004` | Streaming text appears in an expandable card above the pill; copy, dismiss, loading, empty, and error presentation exist without chat history. |
| `APP-001` | `DONE` | coordinating agent — composition root/view model | `INF-001`, `UI-001`–`UI-006` | Quick text drives one cancellable request, deltas update the active card on the main actor, completion settles state, and failure never leaves a false thinking/listening indicator. |
| `QA-001` | `DEFERRED` | user target-hardware acceptance | `APP-001` | On the base M5/24 GB Mac, the user records summon/focus/stream/cancel/error observations against Gemma/TurboFieldfare; performance numbers remain unclaimed until then. |
| `DOC-001` | `DONE` | `task_docs` — this file only | — | The complete staged backlog, dependencies, gates, and multi-agent handoff contract exist in this file. |

### VS-001 exit gate

The slice is **implemented at source level** because `FND-001` through `APP-001`
build and their source checks pass. It may be called **validated on target
hardware** only after `QA-001`. Deferring user-run testing does not permit recording
estimated latency, memory, or UI behavior as measured.

### First-test local runtime handoff — `DONE`

The repository now contains `Scripts/evie-runtime`, an explicit development-only
controller with `doctor`, `setup`, `configure`, `verify`, `start`, `stop`, `status`,
`smoke`, and `launch` commands. It pins TurboFieldfare revision
`7a99f2a635e3adf7ed0720b882d2edb600f2f0da`, model ID
`gemma-4-26b-a4b-it`, and a 65,536-token launch configuration. Runtime source,
model assets, config, process state, and logs stay outside Git under `~/Library`.

Current evidence on the base M5/24 GB target Mac:

| Check | State |
|---|---|
| Pinned TurboFieldfare checkout | Present, clean, and verified at the pinned revision outside Git |
| Release repacker/server build | Passed with macOS 27 Apple Command Line Tools; full Xcode was not required on this machine |
| Gemma download/repack | Passed; installed size verified as 14,291,915,755 bytes across 37 files |
| Upstream install verification | Passed in 10.65 s; receipt written outside Git |
| Loopback health at 64K | Passed; server readiness observed in 3.14 s |
| Synthetic non-streaming + SSE completion | Passed; 5.393 s then 0.882 s in the recorded shell/server measurement run |
| Automated Swift fixtures | 12/12 passed; configuration and fragmented SSE/protocol behavior covered |
| Native development process launch | Passed; shell and server remained resident and healthy |
| UI/manual acceptance | Deferred to `QA-001` |

The Command Line Tools result is a machine-specific observation; upstream still
documents Xcode 26. The bounded first-test result measured a 3,215 MB warm server
and 18 MB shell footprint with 53% system-wide memory free and 0.0% sampled idle
CPU. It does not establish throughput, energy, quality, or long-context behavior.

### VS-003 — Identity, window control, and the animated mark — `DONE` (source); `QA-006` deferred

This slice answers the user's first full review of the running application. The
complete request set, what shipped, and the measurements are in
[`VS_003.md`](VS_003.md).

| ID | Status | Current owner/scope | Depends on | Done when |
|---|---|---|---|---|
| `CORE-006` | `DONE` | `EviePersona`, `EvieCapabilitySnapshot` | `CORE-001` | The hidden system message is generated from an explicit capability snapshot, names the creator and his form of address, never mentions the model or server, and cannot announce a capability whose flag is false. |
| `CFG-001` | `DONE` | `EvieConfiguration`, `Scripts/evie-runtime`, examples | `FND-003` | The default loopback port is outside the IANA registry and below the ephemeral range, and every tracked example moved with it. |
| `CFG-002` | `DONE` | `EviePreferences`, `EviePreferencesStore` | `FND-003` | Appearance, shortcut, and voice preferences round-trip through a versioned `preferences.json` separate from the model configuration, repair a damaged file, fall back to defaults on an unknown schema, and reject an invalid document before writing. |
| `CFG-003` | `DONE` | `EvieVoicePreferences` | `CFG-002` | Call mode implies speech output in the type itself: the setters keep the pair consistent and `validate()` rejects the inconsistent combination. |
| `UI-013` | `DONE` | `EvieMarkView`, `EvieKeyArt`, `EvieVoiceTint` | `UI-004` | The ASCII key replaces the placeholder glyph in three grid densities chosen by rendered size, tilts in 3D through Core Animation, sweeps its shading ramp only during real activity, respects Reduce Motion, and requests voice activation when clicked. |
| `UI-014` | `DONE` | `EvieOverlayGeometry`, `OverlayPanelController`, `OverlayChrome` | `UI-002` | The overlay can be dragged, resized from either edge, and reset to the anchored default; placement persists outside Git and recovers when the saved display is gone. |
| `UI-015` | `DONE` | `OverlayRootView`, `OverlayPanelController` | `UI-006` | The panel height follows the height SwiftUI measured, and the scroll mask fades over a real distance at both edges and only while the list overflows. |
| `UI-016` | `DONE` | shell copy, menu bar, settings | `CORE-006` | No user-visible surface names the model, the inference server, or the loopback host and port. |
| `PERF-001` | `DONE` | `OverlayPanelController`, `EvieMarkView` | `UI-013` | Hiding or occluding the overlay removes the animation timeline from the view tree; idle CPU of the release shell with the overlay visible measured 0.0%. |
| `QA-006` | `DEFERRED` | user target-hardware acceptance | `UI-013`–`UI-016` | On the target display the user accepts dragging, resizing, reset, the fade, mark legibility at 30 points, and the palette in light and dark. |

### VS-004 — Everything configurable — `DONE` (source); `QA-006` deferred

| ID | Status | Depends on | Deliverable and definition of done |
|---|---|---|---|
| `UI-017` | `DONE` | `CFG-002` | A tabbed settings window replaces the single model form: Atalhos, Voz, Aparência, Modelo, Diagnóstico. Every tab writes through the existing atomic stores and reports validation failures in place. |
| `UI-018` | `DONE` | `UI-017` | A shortcut recorder captures a real key combination, shows the conflict set by name when two actions collide, offers per-action disable, and offers reset for one action or for all. |
| `UI-019` | `DONE` | `UI-017`, `CFG-003` | The voice tab presents wake word, push-to-talk, call mode, and speech output, and explains the dependency in place rather than silently reverting a switch. |
| `UI-020` | `DONE` | `UI-017` | The appearance tab exposes overlay width, placement reset, and the logo animation switch, and the diagnostics tab is the only place the endpoint appears. |
| `UI-021` | `DONE` | `UI-018`, `UI-009` | Registered global shortcuts follow the preferences at runtime: re-registration on change, a visible failure when the system refuses a combination, and push-to-talk registered for key release as well. |

### VS-005 — The voice loop — `PLANNED`

| ID | Status | Depends on | Deliverable and definition of done |
|---|---|---|---|
| `PKG-001` | `DONE` | `APP-002` | A reproducible script builds `Evie.app` from the SwiftPM product with a stable bundle identifier, `Info.plist` usage descriptions, and a signature. Without a bundle identity macOS will not grant the microphone, and an ad-hoc signature re-prompts on every rebuild. |
| `VOI-015` | `DONE` | `PKG-001`, `VOI-001` | Real input levels from `AVAudioEngine` drive the ring and the waveform; stopping capture stops both immediately. |
| `VOI-016` | `DONE` | `VOI-015`, `UI-021` | Push-to-talk, the mark, and the wake phrase all enter through one activation path so the three routes cannot drift apart. |
| `VOI-017` | `PLANNED` | `VOI-016` | Local speech recognition produces a transcript that is submitted through the same interaction path as typed text, with partial text marked provisional. |
| `VOI-018` | `PLANNED` | `VOI-007`, `VOI-015` | The existing OmniVoice adapter is connected to native playback with sentence chunking, output metering, cancellation, and barge-in. |
| `VOI-019` | `PLANNED` | `VOI-018`, `CFG-003` | Call mode renders only the mark and its ring, with no transcript on screen, and leaving it restores the written conversation. |

### VS-006 — Sight — `PLANNED`

| ID | Status | Depends on | Deliverable and definition of done |
|---|---|---|---|
| `VIS-007` | `DONE` | `CORE-003` | Native text recognition through Vision, with `RecognizeDocumentsRequest` structure where available, feeding a structured observation. `minimumTextHeightFraction` is set explicitly, because the default silently returns nothing for ordinary screenshot-sized text. |
| `VIS-008` | `DONE` | `VIS-007` | PDFs resolve per page: the embedded text layer when it is trustworthy, rendered pages through recognition when it is not, with the provenance of each page recorded. |
| `VIS-009` | `DONE` | `VIS-007` | Images arrive by drag, paste, or explicit screen capture, with type and size limits, and Retina resolution preserved because downscaling loses diacritics. |
| `VIS-010` | `DONE` | `VIS-009`, `AGT-003` | The observation reaches the model as untrusted evidence that cannot grant authority, and the card separates observed text from interpretation. |


## Dependency map

The critical path is intentionally sequential at capability boundaries:

```text
VS-001 native text loop
  -> supervisor and lifecycle
     -> Hermes agent/tool loop
        -> voice and RAG foundations
           -> read-only integrations and vision
              -> visual automations
                 -> policy-brokered writes
                    -> WhatsApp/remote presence
                       -> operational hardening
```

Voice, retrieval, vision, and connector research may proceed independently after
their contracts exist, but no capability may bypass the policy, provenance, or
lifecycle dependencies listed below.

## Phase A — Foundation and core contracts

| ID | Status | Depends on | Deliverable and definition of done |
|---|---|---|---|
| `FND-002` | `DONE` | `FND-001` | Test targets and deterministic fixture boundaries are established; generated state, private fixtures, and model artifacts remain ignored or outside Git. |
| `FND-003` | `DONE` | `CORE-001` | Typed configuration precedence for defaults, environment, and an ignored local file; the native settings writer atomically preserves the same non-secret schema/mode; invalid values produce actionable errors and deterministic load/save fixtures pass. |
| `FND-004` | `PLANNED` | `FND-002` | Structured local logging with privacy levels and redaction tests; prompt bodies, credentials, voice data, and personal content are excluded by default. |
| `CORE-002` | `READY` | `CORE-001` | Versioned backend-neutral command/event envelope covering state, deltas, artifacts, cancellation, permissions, and errors; unknown future events fail safely. |
| `CORE-003` | `PLANNED` | `CORE-002` | Artifact protocol for text, sources, email/calendar proposals, files, images, workflows, and permission cards; payloads carry provenance/trust metadata. |
| `CORE-004` | `PLANNED` | `CORE-002` | Cancellation, timeout, retry classification, and request identity contracts; stale deltas cannot update a newer interaction. |
| `CORE-005` | `DONE` | `CORE-001` | Nominal read/propose/commit contracts carry bounded provenance/target/revision metadata; opaque non-serializable commit authority is emitted only by an internal factory, fails closed on lifetime/revision/binding mismatch, and delete always requires explicit-user evidence. `CORE-003` artifacts will present these values later; no executor or real tool is implemented. |
| `QA-002` | `DEFERRED` | `CORE-001`, `INF-001` | Eight deterministic TurboFieldfare protocol fixtures now cover SSE fragmentation, CR/LF, malformed/unfinished streams, errors, loopback, and routes; state-transition, cancellation, and redaction coverage still gates full completion. |

## Phase B — Native shell completion

Roadmap mapping: Phase 2. VS-001 provides the text-only foundation; this phase
turns it into a robust long-lived macOS surface.

| ID | Status | Depends on | Deliverable and definition of done |
|---|---|---|---|
| `UI-007` | `PLANNED` | `APP-001`, `CORE-003` | General artifact stack supports pin/expand/copy/open/dismiss and compact task tabs without exposing private preview content by default. |
| `UI-008` | `PLANNED` | `UI-002`–`UI-007` | Keyboard navigation, VoiceOver labels/order, Dynamic Type strategy, Reduce Motion, Reduce Transparency, high contrast, and light/dark behavior are verified. |
| `UI-009` | `DONE` | `UI-003` | Delivered across `CFG-002`, `UI-018`, and `UI-021`: preferences, recorder, conflict display, per-action disable, reset, and runtime re-registration with named failures. |
| `UI-010` | `PLANNED` | `CORE-002`, `UI-007` | Visible worker-loading, offline, permission, cancellation, retry, sleeping, and memory-pressure states never overstate what the system is doing. |
| `UI-011` | `PLANNED` | `UI-007`, `POL-002` | Approval card shows exact action, target, material arguments, revision, expiration, approve/deny controls, and post-action result. |
| `UI-012` | `IN_PROGRESS` | `UI-007`, `AGT-006`, `AUT-009` | VS-002 deliberately opens native History and model Settings windows without changing the default overlay; pinned artifacts, workflows, permissions, semantic-memory/resource controls, and health remain deferred. |
| `APP-002` | `DONE` | `APP-001`, `FND-003` | Continuous completed turns persist as user-only, schema-versioned visible-history records; full history is independent of bounded prompt context, hidden prompts never persist, sessions resume through the native history window, and deletion is explicitly confirmed. |
| `UI-013` | `DONE` | `UI-004` | Delivered in VS-003 as an ASCII key rather than a supplied asset; see the VS-003 registry above. |
| `QA-005` | `DEFERRED` | `APP-002`, `UI-012` | Target-Mac checks cover launch focus, repeated follow-ups, response-completion focus restoration, history resume/relaunch/delete, and live settings behavior. |
| `QA-003` | `DEFERRED` | `UI-008`, `UI-010` | UI/state tests cover focus restoration, Spaces/full-screen, multiple displays, keyboard-only use, accessibility settings, hide/show, and stale asynchronous events. |

## Phase C — Supervisor and model lifecycle

| ID | Status | Depends on | Deliverable and definition of done |
|---|---|---|---|
| `SUP-001` | `PLANNED` | `VS-001`, `CORE-002` | ADR selects Swift service/XPC versus another daemon design using measured complexity, Keychain, process, and power requirements. |
| `SUP-002` | `PLANNED` | `SUP-001` | Implement `evied` control-plane process with a versioned local IPC endpoint and no ML dependency in its address space. |
| `SUP-003` | `PLANNED` | `SUP-002`, `CORE-002` | UI/daemon request-event IPC supports reconnect, protocol-version rejection, cancellation, backpressure, and bounded message sizes. |
| `SUP-004` | `PLANNED` | `SUP-002` | Generic worker manifest/protocol defines start, health, ready, cancel, stop, timeout, resource class, and idle-unload behavior. |
| `SUP-005` | `PLANNED` | `SUP-004`, `INF-001` | TurboFieldfare process adapter can use a user-configured executable/model path, verify loopback health, stop gracefully, and never download or upgrade assets implicitly. |
| `SUP-006` | `PLANNED` | `SUP-004` | Crash/timeout recovery uses bounded retries and circuit breaking; one dead worker cannot terminate UI or unrelated workers. |
| `SUP-007` | `PLANNED` | `SUP-005` | Two-stage Gemma policy clears retained KV/prefix state, then unloads the process; AC and battery defaults are configurable and visible. |
| `SUP-008` | `PLANNED` | `SUP-002`, `SUP-007` | React to memory pressure, thermal state, Low Power Mode, AC/battery, sleep/wake, and app termination without a polling loop. |
| `SUP-009` | `PLANNED` | `FND-004`, `SUP-003` | Redacted health/audit events include request IDs, worker revision, duration, decision, and error class without private content. |
| `SUP-010` | `PLANNED` | `SUP-002`, `SUP-006` | Optional user-scoped startup uses supported macOS service registration, has one-step disable/uninstall, and does not keep heavy workers alive. |
| `SUP-011` | `PLANNED` | `SUP-003`–`SUP-010` | Menu-bar emergency stop cancels work, stops audio/workers, and prevents automatic restart until explicitly re-enabled. |
| `QA-004` | `DEFERRED` | `SUP-011` | Lifecycle tests cover cold/warm start, cancel, crash, sleep/wake, memory pressure, low battery, unavailable model, corrupted output, shutdown, and recovery. |

## Phase D — Gemma/TurboFieldfare and Hermes agent plane

Only Gemma/TurboFieldfare is used as the text model unless a later documented user
decision changes scope. Hermes is the future orchestration runtime, not another
model, and remains excluded from VS-001.

| ID | Status | Depends on | Deliverable and definition of done |
|---|---|---|---|
| `INF-002` | `PLANNED` | `INF-001`, `SUP-005` | Pin TurboFieldfare/model revisions and record reproducible launch configuration for 65,536 declared tokens with Q4 weights/router Q8/KV FP16. |
| `INF-003` | `DEFERRED` | `INF-002` | Target-M5 harness records 16K/32K/64K cold/warm startup, prompt/decode rate, RSS/peak, idle CPU, energy conditions, correctness, and exact revisions. |
| `INF-004` | `PLANNED` | `INF-001`, `CORE-004` | Request budgeting truncates/pages oversized results, protects system/tool budget, and reports overflow rather than silently losing the user's instruction. |
| `INF-005` | `DONE` | `INF-001` | Development-only runtime controller pins TurboFieldfare/model/context, keeps all runtime state outside Git, resumes setup safely, verifies the install, owns explicit doctor/start/stop/status, and passed model discovery plus synthetic non-streaming/SSE smoke requests at 64K on the target Mac. |
| `AGT-001` | `PLANNED` | `SUP-003`, `INF-002` | Pin Hermes Agent and create an Evie profile with all runtime state outside Git and no enabled personal tools. |
| `AGT-002` | `PLANNED` | `AGT-001` | Verify TurboFieldfare's OpenAI/schema subset against Hermes core requests at 64K; incompatibilities have fixtures and adapter decisions. |
| `AGT-003` | `PLANNED` | `AGT-002`, `CORE-005` | Minimal tool-search surface exposes only task-relevant read/propose tools; shell and unrestricted filesystem tools are absent by default. |
| `AGT-004` | `PLANNED` | `SUP-003`, `AGT-001` | Translate Hermes sessions/tool events into `CORE-002` events without leaking backend-specific protocol into SwiftUI. |
| `AGT-005` | `PLANNED` | `AGT-003`, `AGT-004` | Deterministic known intents bypass Hermes; ambiguous multi-step tasks go to Gemma through Hermes; routing reason is auditable. |
| `AGT-006` | `PLANNED` | `AGT-002`, `INF-004` | Session persistence, retrieval of prior turns, compression, and active-context budgeting retain complete local history outside the prompt. |
| `AGT-007` | `PLANNED` | `AGT-003`, `SEC-003` | Adversarial tool/content fixtures cannot expand scope, forge approval, reveal secrets, or convert untrusted text into authority. |

## Phase E — Local voice loop

| ID | Status | Depends on | Deliverable and definition of done |
|---|---|---|---|
| `VOI-001` | `PLANNED` | `SUP-003`, `UI-010` | The native shell owns microphone permission/session, selected input device, explicit mute, and no-retention default; workers never request microphone permission. |
| `VOI-002` | `PLANNED` | `VOI-001`, `UI-004` | `AVAudioEngine` metering drives a real input waveform with bounded update rate; stopping capture immediately stops both indicator and animation. |
| `VOI-003` | `PLANNED` | `UI-003`, `VOI-001` | Push-to-talk handles key-down/up, cancellation, device loss, permission denial, and focus changes without retaining raw audio by default. |
| `VOI-004` | `PLANNED` | `SUP-004`, `VOI-003` | Backend-neutral STT worker accepts bounded PCM/audio, emits partial/final transcripts and confidence metadata where available, and unloads on idle. |
| `VOI-005` | `DEFERRED` | `VOI-004` | Brazilian Portuguese STT candidates are measured on names, dates, mixed English, rooms/noise, cold/warm latency, memory, and energy before selection. |
| `VOI-006` | `PLANNED` | `VOI-004`, `APP-001` | Final transcript submits through the same interaction path as quick text; partial text is clearly provisional and cannot authorize an action. |
| `VOI-007` | `DONE` | `CORE-001` | Source-only backend-neutral TTS contracts and a one-shot adapter targeting the inspected OmniVoice 0.3.12 CLI contract validate absolute local executable/model/cache/reference paths, send private JSONL only through stdin, request supported-library offline resolution in a minimal environment, isolate and cancel/timeout the child process group, enforce `0700`/`0600`, cap output at 64 MiB, validate RIFF/WAVE structure, and perform best-effort cleanup without running the OmniVoice UI. Eight synthetic tests pass; this is not a network sandbox or operational worker. |
| `VOI-008` | `PLANNED` | `VOI-007`, `SEC-001` | Authorized TTS voice references/prompts live outside Git with restrictive permissions; UI lists friendly aliases without exposing raw paths unnecessarily and can delete a profile explicitly. |
| `VOI-009` | `PLANNED` | `VOI-007`, `VOI-002` | Native playback exposes first-audio/loading/speaking states and real output metering; sentence chunking preserves order and cancellation. |
| `VOI-010` | `PLANNED` | `VOI-003`, `VOI-009` | Hard stop and barge-in cancel capture/inference/TTS consistently; stale audio cannot continue after cancellation. |
| `VOI-011` | `DEFERRED` | `VOI-003`, `SUP-008`, `OPS-001` | A local dataset/trainer for “E aí, ívi”/“Ei, ívi” creates a Core ML wake classifier only after held-out false-accept/reject and 8–24 hour energy testing; visible mute and opt-out are permanent. |
| `VOI-012` | `PLANNED` | `SUP-007`, `VOI-009` | Warm-window policy keeps OmniVoice only as long as justified; Low Power Mode and memory pressure unload voice workers first. |
| `VOI-013` | `PLANNED` | `VOI-001`, `SEC-001` | Optional speaker enrollment extracts local embeddings from several approved phrases, encrypts the profile with a Keychain-backed key, deletes raw audio by default, supports one-step removal, and is never accepted as commit authorization. |
| `VOI-014` | `PLANNED` | `SUP-004`, `VOI-007` | Before TTS activation, pin and verify a trusted executable/model/tokenizer manifest and version probe, remove orphaned request directories at supervised startup, and expose worker health/idle unload without claiming process-level network isolation. |

## Phase F — Local memory and RAG

| ID | Status | Depends on | Deliverable and definition of done |
|---|---|---|---|
| `RAG-001` | `PLANNED` | `SUP-004`, `CORE-003` | ADR selects QMD adapter or a lighter embedded pipeline using measured startup/RSS, supported file types, provenance, deletion, and maintenance cost. |
| `RAG-002` | `PLANNED` | `RAG-001`, `SEC-002` | User-selected collection registry stores scoped roots/bookmarks and excludes hidden/sensitive paths by default. |
| `RAG-003` | `PLANNED` | `RAG-002` | Immutable-source extraction creates staged normalized text plus source hash/type/time; originals are never silently changed. |
| `RAG-004` | `PLANNED` | `RAG-003` | SQLite metadata and keyword index support deterministic update/delete/rebuild with schema migration and collection isolation. |
| `RAG-005` | `PLANNED` | `SUP-004`, `RAG-003` | On-demand embedding worker batches work, records model revision/dimensions, unloads on idle, and can rebuild incompatible vectors. |
| `RAG-006` | `PLANNED` | `RAG-004`, `RAG-005` | Hybrid BM25/vector retrieval returns bounded ranked chunks with source identity, offsets/page when known, scores, and trust metadata. |
| `RAG-007` | `DEFERRED` | `RAG-006` | Optional reranker is added only if measured retrieval quality improves enough to justify cold latency and memory. |
| `RAG-008` | `PLANNED` | `RAG-006`, `AGT-003` | Read-only retrieval tool injects bounded evidence as untrusted data and lets responses open/cite exact local sources. |
| `RAG-009` | `PLANNED` | `RAG-003`–`RAG-006`, `SUP-008` | Incremental/scheduled indexing observes AC/idle policy, cancel/retry, progress, and resource ceilings. |
| `RAG-010` | `PLANNED` | `RAG-008`, `UI-007` | Source card shows collection, file/page/section, relevance, open action, and missing/stale status without revealing unrelated excerpts. |
| `RAG-011` | `PLANNED` | `RAG-004`, `RAG-005` | One-step per-collection delete/rebuild removes derived data and confirms that source documents remain intact. |

## Phase G — Vision specialist

| ID | Status | Depends on | Deliverable and definition of done |
|---|---|---|---|
| `VIS-001` | `DEFERRED` | `SUP-004` | Pin a local VLM only after screenshot, Portuguese OCR, document, chart, UI, and photo fixtures plus memory/latency ceilings are defined. |
| `VIS-002` | `PLANNED` | `CORE-003`, `SUP-004` | Backend-neutral vision request/result contract carries image identity, OCR, layout, entities, description, uncertainty, and provenance. |
| `VIS-003` | `PLANNED` | `VIS-002`, `SEC-002` | Explicit image/file/screenshot intake validates type/size/scope, strips unintended metadata where appropriate, and requires Screen Recording only for explicit capture. |
| `VIS-004` | `PLANNED` | `VIS-001`–`VIS-003` | On-demand VLM worker health-checks, cancels, times out, unloads, and never receives personal action credentials/tools. |
| `VIS-005` | `PLANNED` | `VIS-004`, `AGT-003` | Gemma receives the structured observation as untrusted evidence, retains task intent, and alone decides follow-up reasoning/tool proposals. |
| `VIS-006` | `PLANNED` | `VIS-005`, `UI-007` | Image artifact card distinguishes observed text, interpretation, uncertainty, and source; pixel/OCR prompt injections cannot grant authority. |

## Phase H — Read-only personal integrations

| ID | Status | Depends on | Deliverable and definition of done |
|---|---|---|---|
| `SEC-001` | `PLANNED` | `SUP-002` | Keychain broker stores/retrieves named secrets without returning them to the model, UI logs, shell history, or Git. |
| `SEC-002` | `PLANNED` | `CORE-005` | Scoped-resource registry defines allowed accounts, folders, collections, and operations with fail-closed defaults and user-visible review. |
| `SEC-003` | `PLANNED` | `CORE-003`, `FND-004` | Trust/provenance envelopes and redacted audit records are enforced at every web, email, message, document, image, and tool boundary. |
| `INT-001` | `PLANNED` | `SEC-001`–`SEC-003`, `AGT-003` | Common connector protocol separates read/propose/commit, timeout/rate/error classes, provenance, and account identity. |
| `INT-002` | `PLANNED` | `INT-001` | Free web discovery through DDGS plus bounded local-browser extraction returns URL/title/time/source and treats page content as untrusted. |
| `INT-003` | `PLANNED` | `INT-001` | Google OAuth setup requests minimum initial read scopes, stores refresh material locally, shows account/scope, and documents revoke/reconnect. |
| `INT-004` | `PLANNED` | `INT-003` | Gmail read/search tool pages and truncates results, identifies thread/message provenance, and has no send/modify scope. |
| `INT-005` | `PLANNED` | `INT-003` | Calendar list/read tool preserves timezone, calendar identity, recurrence, and invitation trust; it cannot create/edit/delete. |
| `INT-006` | `PLANNED` | `INT-003` | Drive search/read exports supported formats into bounded temporary data, preserves source links, and has no mutation scope. |
| `INT-007` | `PLANNED` | `INT-001`, `SEC-002` | Apple integration ADR selects EventKit/AppleScript/IMAP/CalDAV per capability; each permission and failure mode is independently documented. |
| `INT-008` | `PLANNED` | `INT-001`, `SEC-002` | Scoped local file search/read has allowlisted roots, symlink/path traversal defenses, byte limits, provenance, and no mutation operation. |
| `INT-009` | `PLANNED` | `INT-002`, `INT-004`–`INT-006`, `RAG-008` | Read-only morning briefing combines bounded sources, labels unavailable inputs, cites origins, and causes no remote/local mutation. |

## Phase I — Visual deterministic automation

| ID | Status | Depends on | Deliverable and definition of done |
|---|---|---|---|
| `AUT-001` | `PLANNED` | `SUP-002`, `SEC-001` | Pin and run Node-RED natively as a separately permissioned local service with documented state, startup, shutdown, idle cost, logs, and recovery. |
| `AUT-002` | `PLANNED` | `AUT-001`, `SEC-002` | Narrow Node-RED client exposes only list/inspect/validate/import-disabled/diff/approval-gated enable-disable/trigger/status operations. |
| `AUT-003` | `PLANNED` | `AUT-002` | Versioned Evie flow schema requires owner, purpose, trigger, actions, retries, rollback, sensitivity, enabled state, and reviewed revision. |
| `AUT-004` | `PLANNED` | `AGT-003`, `AUT-003` | Gemma can produce a candidate flow as data; validation rejects unsupported nodes, embedded secrets, broad commands, missing limits, and enabled drafts. |
| `AUT-005` | `PLANNED` | `AUT-004`, `UI-007` | Visual flow preview explains trigger/branches/actions/errors and shows a revision diff before any activation request. |
| `AUT-006` | `PLANNED` | `AUT-002`–`AUT-005`, `POL-002` | Valid drafts import disabled, activation uses exact-revision approval, and changed/stale drafts require reapproval. |
| `AUT-007` | `PLANNED` | `AUT-006` | Deterministic schedules, intervals, webhooks, file events, email/message events, and trusted-location inputs have typed schemas and bounded retries. |
| `AUT-008` | `PLANNED` | `AUT-007`, `SEC-003` | Execution history is redacted/auditable; retry, partial failure, disable, rollback, and connector outage behavior are visible. |
| `AUT-009` | `PLANNED` | `AUT-008`, `UI-012` | Optional workflow catalog/run history displays active revision, credentials by alias only, next run, last outcome, disable, and rollback. |

## Phase J — Policy-brokered write actions

| ID | Status | Depends on | Deliverable and definition of done |
|---|---|---|---|
| `POL-001` | `PLANNED` | `CORE-005`, `SEC-001`–`SEC-003` | Typed capability broker independently validates actor, exact target, scope, operation, sensitivity, revision, expiry, and policy before side effects. |
| `POL-002` | `PLANNED` | `POL-001`, `UI-011` | Approval is local, explicit, request-bound, expiring, single-use, and invalidated by any material argument/revision change. |
| `POL-003` | `PLANNED` | `POL-002`, `SUP-009` | Commit protocol provides idempotency keys, precondition checks, final target result, audit reference, and recoverable compensation where possible. |
| `WRT-001` | `PLANNED` | `POL-003`, `INT-004` | Email draft and confirmed-send are separate operations; recipient/subject/attachments/body preview are exact and send is never scheduled autonomously by default. |
| `WRT-002` | `PLANNED` | `POL-003`, `INT-005` | Calendar proposal and confirmed create/edit are separate; timezone, calendar, guests, recurrence, conferencing, and conflicts are previewed. |
| `WRT-003` | `PLANNED` | `POL-003`, `INT-008` | File move manifest is confined to configured staging roots, checks source hashes/collisions, prefers reversible moves/trash, and returns undo information. |
| `WRT-004` | `PLANNED` | `POL-003`, `AUT-006` | Workflow activation/disable uses the approved exact flow revision and records before/after state with rollback. |

## Phase K — WhatsApp and remote presence

| ID | Status | Depends on | Deliverable and definition of done |
|---|---|---|---|
| `MSG-001` | `BLOCKED` | explicit dedicated-number decision | Record the dedicated account/number boundary and risk acceptance; the primary personal number is not used for experimentation. |
| `MSG-002` | `PLANNED` | `MSG-001`, `SUP-004`, `SEC-001` | Pin a Baileys bridge behind a process adapter; QR/session material stays in protected local state and never reaches Git/model/logs. |
| `MSG-003` | `PLANNED` | `MSG-002`, `INT-001` | Strict sender/chat allowlist maps inbound messages to provenance-rich untrusted events; unknown senders receive no automated response. |
| `MSG-004` | `PLANNED` | `MSG-003`, `POL-003` | Outbound messages require exact recipient/content approval and bounded rate/idempotency; autonomous initiation is disabled by default. |
| `MSG-005` | `PLANNED` | `MSG-003`, `VOI-004` | Inbound voice notes use the same local STT pipeline, retain no raw audio by default, and cannot authorize actions. |
| `MSG-006` | `PLANNED` | `MSG-004`, `VOI-007`–`VOI-009` | Optional spoken replies use an explicitly selected voice and exact outbound approval before media creation/send. |
| `MSG-007` | `PLANNED` | `MSG-002`–`MSG-006` | Protocol failure isolates the channel; health, reconnect limits, unlink/revoke, credential deletion, and fallback local use are documented and tested. |

## Phase L — Operations and product hardening

| ID | Status | Depends on | Deliverable and definition of done |
|---|---|---|---|
| `OPS-001` | `PLANNED` | `SUP-010`, `UI-008` | Reproducible app bundle/signing/notarization approach, entitlements, permissions text, local install, upgrade, and uninstall are documented. |
| `OPS-002` | `PLANNED` | `SUP-009`, `UI-012` | Health surface reports component state/revision/uptime/last error/resource class without secrets or private content. |
| `OPS-003` | `PLANNED` | `FND-004`, `SUP-009` | Log rotation/retention/export/redaction and one-step purge are implemented and documented. |
| `OPS-004` | `PLANNED` | `RAG-011`, `AUT-008`, `AGT-006` | Backup/restore distinguishes irreplaceable settings from recreatable indexes/caches and excludes credentials unless protected separately. |
| `OPS-005` | `PLANNED` | all pinned components | Dependency/model update workflow runs relevant evaluation gates, records migration/rollback, and never silently upgrades an operational install. |
| `OPS-006` | `PLANNED` | `SUP-011`, all integrations | Incident runbook stops workers/workflows, mutes capture, revokes accounts, unlinks WhatsApp, rotates secrets, purges derived data, and restores known-good state. |
| `OPS-007` | `DEFERRED` | operational phases | Long-run acceptance demonstrates crash recovery, sleep/wake, battery policy, upgrades, logs, and routine use with maintenance cost below measured time saved. |

## Cross-cutting quality gates

These gates apply to every task even when not repeated in its row:

1. **Build evidence:** agents run the narrowest relevant compile/unit/static checks.
   User-deferred manual or target-hardware tests are recorded as deferred, never
   silently treated as passed.
2. **Security:** no secret, credential, personal content, model weight, voice
   sample, runtime index, or private log enters Git. New capabilities default to
   read-only or proposal-only.
3. **Honest state:** UI status reflects observed runtime events. A visual animation
   must not claim microphone, model, tool, or action activity that did not occur.
4. **Lifecycle:** every heavy worker has health, ready, cancel, timeout, stop, idle
   unload, crash recovery, and resource documentation before it is operational.
5. **Accessibility:** keyboard operation and assistive settings are part of UI
   completion, not an optional polish pass.
6. **Privacy:** raw audio is not retained by default; prompts/results and personal
   source bodies are excluded from diagnostic logs.
7. **Documentation:** behavior/architecture changes update the relevant design,
   `CHANGELOG.md`, `docs/PROJECT_STATUS.md`, and `docs/WORKLOG.md` in the same
   commit, as required by `AGENTS.md`.
8. **Reproducibility:** measured claims include hardware, OS, power mode, component
   revisions, configuration, date, cold/warm state, and commands without secrets.

## Multi-agent execution and handoff protocol

### Claiming a task

1. Read `AGENTS.md` and its required documentation sequence.
2. Inspect `git status -sb`; existing changes belong to another agent unless scope
   ownership says otherwise.
3. Select only a `READY` task whose dependencies are `DONE`, or a task explicitly
   assigned by the coordinating agent.
4. Record task ID, owner, branch, exact files, expected checks, and start time in
   the coordinating message/worklog. Only one agent owns a file at a time.
5. Change task status to `IN PROGRESS` in the same change set when practical. If a
   shared-worktree coordinator owns this ledger, notify it instead of racing edits.

### While implementing

- Keep the public/backend boundary stable; do not leak Hermes, TurboFieldfare,
  OmniVoice, Node-RED, or connector-specific types into UI contracts.
- Do not absorb adjacent tasks because they appear easy. Propose or claim a new ID.
- Do not rewrite another agent's uncommitted files, stage the whole worktree, or
  run destructive Git commands.
- Use explicit paths when staging. A commit contains one coherent task or tightly
  coupled dependency group and its documentation.
- New durable decisions with meaningful alternatives require an ADR rather than a
  silent implementation choice.

### Completion evidence

A task handoff must include:

```markdown
Task: <ID and title>
Status: <DONE | BLOCKED | IN PROGRESS>
Owner/branch: <agent and branch>
Commit: <SHA or pending>
Files changed: <explicit paths>
Checks run: <commands and exact result>
Measured results: <or "none; not measured">
Decisions: <ADR/reference or "none">
Security/privacy notes: <scopes, logs, local state>
Known limitations/blockers: <specific and reproducible>
Working-tree leftovers: <owner of every uncommitted path>
Exact next action: <one bounded task ID and first command/file>
```

`DONE` requires code plus its narrow automated evidence and synchronized
documentation. If the user will run a manual/hardware test later, mark that
separate QA task `DEFERRED`; do not block truthful completion of source work and do
not claim runtime validation.

### Resuming after another AI/model

The incoming agent must be able to continue without conversation history:

1. Read `docs/PROJECT_STATUS.md`, this ledger, the latest worklog/changelog entries,
   relevant design docs, and ADRs.
2. Reconcile documented ownership with `git status`, branches, and recent commits.
3. Re-run the last narrow check before modifying an unfinished component.
4. Continue the recorded exact next action or explicitly document why it changed.
5. Preserve pending user-run QA tasks and all estimates as estimates.

## Immediate queue after VS-001

Do not start these until the current slice is coherently integrated:

1. Keep `QA-001` deferred until the user chooses to run the target-hardware UI
   checks.
2. Implement `CORE-002`, the versioned command/event envelope required by IPC.
3. Begin `SUP-001` with a narrow daemon/IPC decision spike.
4. Implement `SUP-002`–`SUP-005` so Evie can own lifecycle without coupling the UI
   to TurboFieldfare.
5. Add Hermes only at `AGT-001`; do not fold it into the current client or UI.
6. Start microphone/STT/TTS work only at Phase E, after honest state and lifecycle
   foundations exist.
