# System architecture

Status: target architecture proposed; VS-001 native/direct-client seam implemented
for validation.

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

## VS-001 implementation boundary

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
reducer types. SwiftUI does not parse SSE or authorize backend output. The
application composition root is the only place that chooses the concrete
TurboFieldfare adapter.

This direct connection is accepted only for VS-001 under
[ADR 0006](adr/0006-direct-turbo-vertical-slice.md). It starts no process, executes
no tools, persists no session, carries no credential, and rejects non-loopback
hosts. The separately started server must use `--max-context 65536`; the client
cannot increase a server launched at its 16K default.

The waveform view is data-driven but receives no microphone or output-audio samples
in this slice. Voice states exist in the stable event vocabulary for future workers,
not as a claim that voice is operational.

## Always-on control plane

### Evie macOS UI

A SwiftUI/AppKit menu-bar utility owns the overlay, microphone feedback, audio
playback presentation, result cards, approvals, and optional history window. It
must not load ML models directly.

VS-001 implements this as a SwiftPM development executable using an accessory
application policy, AppKit status item, borderless nonactivating `NSPanel`, native
vibrancy, Carbon hotkeys, and SwiftUI content. Signed `.app` packaging, login-item
registration, shortcut preferences, and target behavior across Spaces/displays are
not yet implemented or accepted.

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

VS-001 can stream from the server when the user starts it manually, but does not
yet provide single-owner enforcement, health polling, start/stop, crash recovery,
or warm/idle policy.

### STT worker

Receives a bounded audio file/stream and emits timestamped text plus confidence
metadata when available. The first implementation can use a Hermes command provider;
the native UI may later call the same adapter for partial transcription.

### TTS worker

Receives text, voice reference/profile, and output path/stream. OmniVoice CLI is
the baseline cold implementation. A persistent Python provider is allowed only if
benchmark evidence justifies model reuse or streaming.

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

## Runtime data locations

Proposed macOS layout, subject to implementation ADR:

```text
~/Library/Application Support/Evie/   config, state, sessions, indexes
~/Library/Caches/Evie/                recreatable caches and extracted pages
~/Library/Logs/Evie/                  redacted rotating logs
~/Library/LaunchAgents/               user-scoped service definitions
macOS Keychain                        secrets and refresh tokens where supported
```

Model weights may use a user-selected models directory. Personal sources and voice
references require explicit paths and never live in the Git checkout by default.

## Failure containment

- A VLM/TTS/RAG worker crash must not kill the UI or primary session.
- A Node-RED outage must not prevent direct voice/text interaction.
- A WhatsApp outage must not prevent local use.
- A model timeout must be cancellable and return the UI to an honest error state.
- A malformed tool result must not be rendered as an authorized action.
- If policy state is unavailable, commit actions fail closed.
