# System architecture

Status: the target architecture below is still the target. What is built is the
native shell with a direct loopback client, an agent loop with read-only tools and
one proposing writer, retrieval, voice in both directions, vision through the
system daemon, typed commands, and a self-update path. The `evied` supervisor does
not exist; the application composition root is doing its job for now.

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
 │ Gemma /  │ │ RAG local│ │ tools and │ │ macOS    │ │ STT/TTS │
 │ Turbo    │ │ retrieval│ │ adapters  │ │ Shortcuts│ │ + vision│
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
[ADR 0006](adr/0006-direct-turbo-vertical-slice.md). The client still carries no
credential and rejects non-loopback hosts, and it still never executes a tool.

Three of the original abstinences no longer hold, and they are worth naming rather
than leaving as an out-of-date boundary:

- the application now starts a process — the voice engine, and only when a trained
  voice is asked for;
- it now executes tools, in `EvieAgentLoop`, outside the transport;
- one of those tools proposes a filesystem change, which a person then approves.

What has not changed is the invariant those abstinences were protecting: no tool
the model can call changes anything. `propose_change` records a proposal and
returns a result saying plainly that nothing happened. Prompt injection reaches a
card, not a filesystem.

**The loop no longer withdraws its tools on the last pass.** It used to, so the
model would have to produce words, and this server rejects a tool call naming a
tool that was not declared: `/web` died with
`GemmaToolCallParserError.unknownTool("search_web")` at status 500, because the
conversation the model was reading is nothing but tool calls and another one is
the obvious continuation. The withdrawal caused the failure it existed to prevent.
The tools stay declared on every pass now and the last pass declines them — each
call gets a result saying no lookups remain, and then a user turn asks for an
answer from what was found. A user turn, because this server refuses `developer`
guidance once a conversation has started, measured twice in this project; and the
tool results alone were verified to be insufficient, since with nothing else said
the model simply asked again and the turn still ended empty. Verified end to end
on the question that failed: four searches, 81 s, and an answer that says what it
could not find rather than an error (`10c4da2`).

The adjacent `Scripts/evie-runtime` development tool can explicitly prepare and
manage the inference process for testing, but it is not linked into the
application. The server must use `--max-context 65536`; the client cannot increase
a server launched at its 16K default.

```text
~/Library/Application Support/Evie/
  Conversations/<uuid>.json    visible user/assistant history, 0600
  Media/                        attachments kept with the conversation that used them
  Skills/                       markdown instructions the user can write by hand
  vault-index.json              cached passage embeddings, rebuilt from the vault
  config.json                   non-secret model preferences, 0600
  preferences.json              appearance, shortcuts, voice, web, wake, updates
  schedules.json                the scheduled questions and their triggers, 0600
```

The schedules themselves live in `~/Library/LaunchAgents`, one plist each, and
their logs in `~/Library/Logs/Evie`. The plist carries the trigger and the
schedule's identifier; the prompt stays in the `0600` store, because that
directory is readable by anything running as this user.

Media belongs to the conversation that attached it: deleting the conversation
deletes the files, and anything a crash left behind is swept at launch, because a
folder of pictures nobody can reach is how a disk quietly fills.

The UI keeps a complete visible session for persistence while constructing a
separate bounded copy for each inference request. Hidden prompts are always
reconstructed in memory. See [ADR 0008](adr/0008-local-conversation-history.md).

The waveform view is driven by real microphone and playback levels. Voice states in
the event vocabulary now describe activity that happens.

## Module and file map

Two targets. `EvieCore` is dependency-free, has no AppKit, and holds everything
that can be reasoned about without a window. `EvieShell` owns the window, the
system frameworks, and every process Evie starts.

`EvieCore`, by what it is for:

| Area | Types |
|---|---|
| Transport and loop | `AgentClient`, `TurboFieldfareClient`, `EvieAgentLoop`, `EvieToolCallAccumulator`, `EvieTool` |
| Conversation | `ChatMessage`, `EvieConversation`, `EvieConversationStore`, `EvieConversationExport`, `EvieInteraction`, `EvieArtifact`, `EvieRichText` |
| Commands | `EvieCommand`, `EvieSearchCommands`, `EviePlan`, `EviePlanPrompts` |
| Retrieval and grounding | `EvieVaultRetriever`, `EvieVaultPassage`, `EviePassageRanker`, `EvieQueryTerms`, `EvieGrounding`, `EvieAnswerProvenance`, `EvieWebSearch`, `EvieWebPassages` |
| Files | `EvieRootRegistry`, `EvieFileToolbox`, `EvieScopedFileReader`, `EvieDocumentReader`, `EvieFileWriter`, `EvieFileChange`, `EvieChangeIntent` |
| Mail and calendar | `EvieMailCalendar`, `EvieAppleScripts`, `EvieMailCalendarTool`, `EvieMailMessage`, `EvieCalendarEvent` |
| Arithmetic | `EvieCalculator`, `EvieCalculatorTool` |
| Schedules | `EvieSchedule`, `EvieScheduleTrigger`, `EvieScheduleAgent`, `EviePropertyList` |
| Knowledge and identity | `EvieMemory`, `EvieSkill`, `EviePersona`, `EvieCapabilityContracts` |
| Voice | `EvieTTS`, `OmniVoiceBatchTTSAdapter`, `EvieSpeechGate`, `EvieSilenceTrim`, `EvieWakePhrase`, `EvieWakeGate` |
| Settings and release | `EvieConfiguration`, `EvieConfigurationLoader`, `EvieConfigurationStore`, `EviePreferences`, `EviePreferencesStore`, `EvieShortcut`, `EvieRelease` |
| Presentation-adjacent | `EvieOverlayGeometry`, `EvieThinkingWave` |
| Process | `SecureProcessRunner` |

`EvieShell`, by what it owns:

| Area | Types |
|---|---|
| Composition and windows | `EvieShellApp`, `AppCoordinator`, `OverlayPanelController`, `SettingsWindowController`, `ConversationHistoryWindowController`, `GlobalHotKeyController` |
| Overlay state | `OverlayViewModel` plus `+Turn`, `+History`, `+Plan`, `+Search`; `OverlayChromeModel` |
| Other view models | `ConversationHistoryViewModel`, `EviePreferencesViewModel`, `ModelSettingsViewModel`, `EvieRootsViewModel`, `EvieMemoryViewModel`, `EvieSkillsViewModel`, `EvieVoiceLibraryViewModel` |
| Audio | `EvieAudioCapture`, `EvieLevelMeter`, `EvieSpeechTranscription`, `EvieSpeechOutput`, `EvieOmniVoiceClient`, `EvieVoiceEngineLauncher`, `EvieWakeListener` |
| Reading the world | `EvieVaultIndex`, `EvieVisionDescriber`, `EvieDocumentAttachment`, `EvieMediaStore`, `EvieWebClient`, `EvieSkillStore`, `EvieMailCalendarClient` |
| Schedules | `EvieLaunchAgents`, `EvieScheduleStore`, `EvieScheduleRunner`, `EvieScheduleLock`, `EvieScheduleNotifier`, `EvieSchedulesViewModel` |
| Diagnostics | `EvieDiagnostic`, `EvieDiagnosticRegistry`, `EvieDiagnostics` plus its five subject files |
| Updating | `EvieUpdater`, `EvieBundleSignature` |
| Views | `Views/`, plus `EvieOverlayView`, `QuickTextEntryView`, `ConversationHistoryView` |

`OverlayViewModel` was one file of 2,278 lines holding cards, attachments,
commands, plans, proposals, persistence and the request lifecycle. It is now five:
the type keeps its state and lifecycle, and the four extensions it already
contained became `+Turn` (the turn machinery), `+History` (paging earlier turns),
`+Plan` (the `/plano` runner) and `+Search` (`/buscar` and `/web`). Nothing else
changed, which is why the test suite was the check that it worked. The cost is
that members the extensions reach are `internal` rather than `fileprivate`, since
`fileprivate` is scoped to a file and there are now five of them.

The diagnostics went the same way and for a sharper reason.
`applicationDidFinishLaunching` was 370 lines of `CommandLine.arguments.contains`
before it got round to launching anything, followed by 850 lines of the checks
those branches called, and `--help` was not writable without a second list of
flags kept by hand. Each check now declares its flag, how it is written, one line
of what it does, and how many arguments must follow; dispatch is a lookup over
that list and `--help` is the same list read out loud, so the two cannot drift.
The implementations live in five files by subject and the delegate is 71 lines
(`4a08c98`, `Sources/EvieShell/EvieDiagnosticRegistry.swift`). Three properties
were preserved deliberately: the order flags are tested in, which decides who
wins when two are on one line; the rule that a flag written without its arguments
does not match at all and the application launches normally; and the main-actor
isolation, since several checks hold the main actor for tens of seconds on
purpose.

## Always-on control plane

### Evie macOS UI

A SwiftUI/AppKit menu-bar utility owns the overlay, microphone feedback, audio
playback presentation, result cards, approvals, and optional history window. It
must not load ML models directly.

This is a SwiftPM executable packaged as an accessory `.app` with a stable bundle
identifier: AppKit status item, borderless nonactivating `NSPanel`, native
vibrancy, Carbon hotkeys, SwiftUI content, a history window, and a settings
window. Being an accessory application has consequences the code has to respect —
there is no Dock tile to click, so an `NSOpenPanel.runModal()` that takes
activation for the whole application and hands it back to whatever the system
considers frontmost is indistinguishable from the settings window closing. The
settings pickers are sheets on the asking window for that reason; the overlay's
own attach button stays modal deliberately, because a sheet on a small floating
panel would look wrong and ⌥Space brings the overlay back.

Login-item registration and target behaviour across Spaces/displays are still not
implemented or accepted.

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

What shipped is a local HTTP engine on `127.0.0.1:3900` rather than the one-shot
CLI adapter, started by `EvieVoiceEngineLauncher` when a trained voice is asked
for and never at login. `EvieSpeechOutput` synthesises the answer in blocks and
plays them through an `AVAudioEngine`, synthesising the next block while the
current one plays. `docs/VOICE.md` carries the measurements.

`VOI-007` also implements the backend-neutral request/audio/error contract and a
one-shot adapter targeting the inspected `omnivoice-infer-batch` 0.3.12 contract.
It sends text/reference transcript as JSONL on stdin, requires explicit absolute
executable/model/Hugging Face cache/reference paths, asks supported libraries to
resolve offline in a minimal child environment, and launches in an isolated
process group. Cancellation/timeout terminate descendants; private request
directories/WAVs are `0700`/`0600`, outputs are capped at 64 MiB and structurally
validated as RIFF/WAVE, and cleanup is best effort on failure or discard. The
configured executable is trusted local code: this adapter neither network-sandboxes
it nor verifies its version/hash yet — which is still true of the HTTP engine that
superseded it. That adapter itself remains unwired: playback, the voice library,
and real inference all go through the engine instead.

### Vision worker

There is no vision worker. `EvieVisionDescriber` calls the system's own on-device
model, which runs in a system daemon, so no weights enter Evie's address space and
nothing is downloaded. It is kept beside the text reader rather than replacing it:
the description gives the structure of a chart and the reader gives the exact
characters, and neither alone is enough. See `docs/VISION.md`.

### Retrieval

`EvieVaultIndex` embeds passages once with the system's contextual embedding model
and caches the result, re-embedding only what changed. There is no separate
process and no reranker model. `docs/RAG.md` records why an inverted index was not
built.

## Deterministic automation plane

Node-RED was the plan and is not the answer. The constraint is nothing resident,
nothing in Docker, and processing spent only when the tool is used; Node-RED is a
Node.js HTTP server with a browser editor, and residency is the whole point of it.

The recommendation is macOS Shortcuts — the visual editor the user already owns,
driven by the tool loop Evie already has, with no resident process of her own.
`docs/AUTOMATIONS.md` records what was measured, including the parts that do not
work: `shortcuts sign` reads the file extension rather than the content, so exit 0
means the bytes parsed and nothing more; installing a shortcut is one human click,
which is the approval gate the old design was going to build as policy, enforced
instead by the operating system; and a shortcut that wants to ask the user
produces no output and never exits, which is indistinguishable from a slow one.

Nothing event-driven survives the constraint. No webhooks, no MQTT, no inbound
mail, no phone-pushed location: anything event-driven needs something listening,
and nothing that listens is non-resident.

The narrow workflow API the old design proposed — list, inspect, validate, import
as disabled, diff, request approval, enable, trigger, read redacted logs — remains
the right shape for whatever is eventually built, and none of it is written.

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

## Update path

`EvieRelease` models a GitHub release, `EvieUpdater` performs three separate
presses — look, download, install — and `EvieBundleSignature` decides whether the
download may replace the running copy. Nothing is installed silently and nothing
is installed that was not signed with the same key as the copy already running.
What the two checks catch, and what was measured against tampered bundles, is in
`docs/SECURITY.md`.

## Failure containment

- A VLM/TTS/RAG worker crash must not kill the UI or primary session.
- A Node-RED outage must not prevent direct voice/text interaction.
- A WhatsApp outage must not prevent local use.
- A model timeout must be cancellable and return the UI to an honest error state.
- A malformed tool result must not be rendered as an authorized action.
- If policy state is unavailable, commit actions fail closed.
