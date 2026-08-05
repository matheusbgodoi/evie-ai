# System architecture

Status: target architecture proposed; VS-002 native/direct-client shell with local
visible history and settings implemented for validation.

## Design principles

1. Local processing and local state by default.
2. Heavy models are workers, not the always-on application.
3. Deterministic operations bypass an LLM where possible.
4. Model output proposes actions; a policy boundary authorizes them.
5. External content is data, never authority.
6. Components communicate through stable local contracts and remain replaceable.
7. The visible product is a native voice/command HUD, not a chat transcript.
8. Every background component has a measurable idle cost and an unload path.

## Logical view

```text
                global shortcut / wake phrase / menu bar
                                  │
                                  ▼
                    ┌─────────────────────────┐
                    │ Evie macOS UI           │
                    │ pill, waveforms, cards  │
                    └────────────┬────────────┘
                                 │ local IPC events/commands
                                 ▼
                    ┌─────────────────────────┐
                    │ evied supervisor        │
                    │ lifecycle + routing     │
                    │ policy + audit          │
                    └───┬─────────┬────────┬──┘
                        │         │        │
             ┌──────────▼──┐  ┌──▼─────┐  └───────────────┐
             │ Hermes Evie │  │ direct │                  │
             │ profile     │  │ intents│                  │
             └──────┬──────┘  └──┬─────┘                  │
                    │            │                         │
       ┌────────────┼────────────┼──────────────┐          │
       │            │            │              │          │
 ┌─────▼────┐ ┌─────▼────┐ ┌─────▼─────┐ ┌─────▼────┐ ┌───▼─────┐
 │ Gemma /  │ │ RAG local│ │ tools and │ │ Node-RED │ │ STT/TTS │
 │ Turbo    │ │ retrieval│ │ adapters  │ │ workflows│ │ + vision│
 └──────────┘ └──────────┘ └───────────┘ └──────────┘ └─────────┘
```

## VS-001/VS-002 implementation boundary

The first executable intentionally implements only this temporary path:

```text
Carbon global shortcut / AppKit status item
                    |
                    v
       SwiftUI views in a floating NSPanel
                    |
                    v
       OverlayViewModel -> AgentClient
                    |
                    v
  TurboFieldfareClient -> loopback Chat Completions SSE
```

`EvieCore` owns backend-neutral message, phase, failure, usage, artifact, and
reducer types, plus nominal read/propose/commit capability contracts. SwiftUI does
not parse SSE or authorize backend output. The
application composition root is the only place that chooses the concrete
TurboFieldfare adapter.

The commit-authority contract is deliberately non-serializable and constructible
only inside EvieCore's future trusted broker path. It currently has no executor;
adding a filesystem/network implementation to the direct UI client remains
forbidden.

This direct connection is accepted only for the current prototype under
[ADR 0006](adr/0006-direct-turbo-vertical-slice.md). The application starts no
process, executes no tools, carries no credential, and rejects non-loopback hosts.
VS-002 adds only a native visible-conversation store and non-secret configuration
writer; neither can authorize model actions. The adjacent `Scripts/evie-runtime`
development tool can explicitly prepare and manage the process for testing, but it
is not linked into the application. The server must use `--max-context 65536`; the
client cannot increase a server launched at its 16K default.

```text
~/Library/Application Support/Evie/
  Conversations/<uuid>.json    visible user/assistant history, 0600
  config.json                   non-secret model preferences, 0600
```

The UI keeps a complete visible session for persistence while constructing a
separate bounded copy for each inference request. Hidden prompts are always
reconstructed in memory. See [ADR 0008](adr/0008-local-conversation-history.md).

The waveform view is data-driven but receives no microphone or output-audio samples
in this slice. Voice states exist in the stable event vocabulary for future workers,
not as a claim that voice is operational.

## Always-on control plane

### Evie macOS UI

A SwiftUI/AppKit menu-bar utility owns the overlay, microphone feedback, audio
playback presentation, result cards, approvals, and optional history window. It
must not load ML models directly.

VS-002 implements this as a SwiftPM development executable using an accessory
application policy, AppKit status item, borderless nonactivating `NSPanel`, native
vibrancy, Carbon hotkeys, SwiftUI content, a deliberate history window, and a
model-settings window. Signed `.app` packaging, login-item registration, shortcut
preferences, and target behavior across Spaces/displays are not yet implemented
or accepted.

### `evied` supervisor

Responsibilities:

- receive typed, push-to-talk, wake-word, message, and workflow events;
- choose deterministic intent, Hermes session, or specialist worker;
- start, health-check, cancel, idle, and stop child processes;
- enforce one authoritative permission decision before commit actions;
- translate backend-specific output into stable UI events;
- track AC/battery state, memory pressure, and idle timers;
- redact and append audit events;
- recover from a dead worker without restarting the UI.

Implementation candidates are a small Swift service or a Rust daemon with a Swift
UI client. Phase 2 must compare development complexity, process control, Keychain,
power APIs, and distribution before selecting one.

### Local IPC

Prefer a Unix domain socket or XPC if both ends are native Apple components. The
protocol should be versioned and backend-neutral. Representative events:

```text
voice.listening
voice.level
voice.partial_transcript
voice.transcribing
agent.thinking
tool.started
tool.permission_required
tool.completed
assistant.text_delta
tts.loading
tts.speaking
artifact.created
workflow.draft_created
system.sleeping
system.error
```

## Agent plane

Hermes runs in a dedicated `evie` profile with:

- a local OpenAI-compatible primary provider;
- context compression configured below the 64K hard limit;
- Tool Search enabled for MCP/plugin integrations;
- minimal toolsets per entry surface;
- read/propose/commit tools exposed separately;
- cron dangerous-command mode denied;
- memory and sessions stored outside this repository.

The supervisor may bypass Hermes for a fully specified deterministic intent. It
must not reproduce a second general-purpose agent loop unless Hermes proves
incompatible during benchmarks.

## Worker plane

### Primary text worker

Initial candidate: TurboFieldfare serving Gemma 4 26B-A4B IT on loopback with 64K
declared context. One process owns the model. The supervisor serializes use and
applies warm/idle policy.

VS-001 can stream from the server when it is started separately. The development
controller provides bounded single-owner checks, health, and explicit start/stop
for first-test readiness. It does not provide application-owned health events,
automatic restart, crash recovery, idle unload, power policy, or a stable IPC
contract; those remain supervisor responsibilities.

### STT worker

Receives a bounded audio file/stream and emits timestamped text plus confidence
metadata when available. The first implementation can use a Hermes command provider;
the native UI may later call the same adapter for partial transcription.

### TTS worker

Receives text, voice reference/profile, and output path/stream. OmniVoice CLI is
the baseline cold implementation. A persistent Python provider is allowed only if
benchmark evidence justifies model reuse or streaming.

`VOI-007` now implements the backend-neutral request/audio/error contract and a
one-shot adapter targeting the inspected `omnivoice-infer-batch` 0.3.12 contract.
It sends text/reference transcript as JSONL on stdin, requires explicit absolute
executable/model/Hugging Face cache/reference paths, asks supported libraries to
resolve offline in a minimal child environment, and launches in an isolated
process group. Cancellation/timeout terminate descendants; private request
directories/WAVs are `0700`/`0600`, outputs are capped at 64 MiB and structurally
validated as RIFF/WAVE, and cleanup is best effort on failure or discard. The
configured executable is trusted local code: this adapter neither network-sandboxes
it nor verifies its version/hash yet. No UI composition, playback, voice-profile
store, or real inference is implemented, and no OmniVoice daemon/app remains
active.

### Vision worker

Loads only when an image is attached or a vision tool is called. It returns a
structured observation containing description, OCR, layout, entities, uncertainty,
and source-image identity. The text agent decides what the observation means.

### Retrieval workers

Embedding and optional reranking are separate from the always-on store. SQLite and
keyword indexes can remain open; model processes can load for a query or scheduled
indexing and then unload.

## Deterministic automation plane

Node-RED owns event-driven workflows. Its responsibilities are timing, webhooks,
state transitions, retries, and connector calls that do not require semantic
judgment. The LLM is a bounded node used only for tasks such as classification,
summarization, extraction, or drafting.

Evie receives only a narrow workflow API:

- list and inspect;
- validate a candidate;
- create/import as disabled;
- compare a draft with the active revision;
- request approval;
- enable/disable after approval;
- trigger an approved flow;
- read execution status and redacted logs.

## Configuration and development runtime

The native shell resolves model configuration in this order:

1. compiled non-secret defaults;
2. versioned JSON at `~/Library/Application Support/Evie/config.json` (or another
   absolute path selected through `EVIE_CONFIG_FILE`);
3. supported non-secret environment overrides.

Invalid model configuration produces a visible startup error. The loader does not
read credentials or print configuration. Secrets remain a future Keychain/broker
concern, never part of the model endpoint file.

The model settings window writes the same schema with atomic replacement and mode
`0600`, then swaps the direct client's non-secret settings for the next request.
Environment variables still override the file after a future relaunch. Endpoint,
model identity, and context remain visible but read-only in this initial settings
surface.

[ADR 0007](adr/0007-local-development-runtime.md) accepts this development-only
layout:

```text
~/Library/Application Support/Evie/
  Runtimes/turbo-fieldfare/           pinned upstream checkout and build products
  Models/gemma4.gturbo/               installed/repacked model assets
  State/                              development PID state
  config.json                         versioned non-secret model configuration
  Conversations/                      visible local conversation records
~/Library/Logs/Evie/
  turbo-fieldfare-server.log          user-only development server log
```

All directories are outside Git and created with a user-only umask. There is no
LaunchAgent or implicit startup. The server log is operational output, not an
audit/history store, and prompts/results must not be added to it by Evie.

The target Mac built the pinned TurboFieldfare release products with macOS 27
Apple Command Line Tools alone. That is a local observation, not a replacement for
upstream's documented Xcode 26 requirement. The eventual supervisor may migrate
these paths and lifecycle commands through a documented upgrade rather than
depending on the development script.

The broader target layout still reserves `~/Library/Caches/Evie/` for recreatable
caches, macOS Keychain for future secrets, and explicitly selected paths for
personal sources and voice references. None of those capabilities is implemented
by this slice.

## Failure containment

- A VLM/TTS/RAG worker crash must not kill the UI or primary session.
- A Node-RED outage must not prevent direct voice/text interaction.
- A WhatsApp outage must not prevent local use.
- A model timeout must be cancellable and return the UI to an honest error state.
- A malformed tool result must not be rendered as an authorized action.
- If policy state is unavailable, commit actions fail closed.
