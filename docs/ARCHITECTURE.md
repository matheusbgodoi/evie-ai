# Current delivery architecture — 2026-10-17

Research sessions ([ADR 0020](adr/0020-expiring-research-shortcut-sessions.md)),
current-conversation brain selection (0021), enabled capabilities with real TCC
requests (0022), optional direct App Intents (0023, superseded for local builds
by [public URL/Shortcuts integration (0029)](adr/0029-native-shortcuts-with-stable-local-signing.md)), local provider
configuration/private release history (0024), native voice calibration (0025),
[adaptive context and compaction (0026)](adr/0026-adaptive-conversation-context-and-compaction.md)
and [pinned public web transport (0027)](adr/0027-pinned-public-web-transport.md)
amend the historical target below. The application composition root remains
`AppCoordinator`; no `evied` supervisor or additional resident model service was
introduced. PC inference is external, the Mac brain and optional clone worker
remain on demand, and native STT/TTS use public OS services.

## Current conversation and model boundary

`EvieBrainResolver` resolves each turn, including an explicit model change within
the same conversation. `EvieTurnPlan` reserves output/framing before preparing
the input budget. The PC operational context is 200,704 tokens. LensVLM's
qualified operational context is 131,072 tokens on both client and local runtime,
with eight-bit KV, prefill step 512, a 256 MiB allocator cache limit and a
900-second profile timeout. The synthetic 127,527-token input plus 38-token
output retrieved five of five target items; minimum sampled free memory was
2.4 GiB and MLX-reported peak memory 13.8 GiB over 392.31 seconds. The architectural 262,144
ceiling is not the operating setting. Conditions and limits belong in
[MODEL_TUNING](MODEL_TUNING.md).

`OverlayViewModel.conversationPrefix` normalizes picture replay, waits for pending
context resets and calls its per-view-model `EvieConversationCompaction` actor.
Older messages are summarized near the budget threshold; the full visible
conversation is never replaced. The current tail remains intact. The four-entry
in-memory summary cache is bound to conversation/profile/model/budget and a
fingerprint including visual provenance. Request/conversation IDs and task
cancellation reject stale progress/results. A visual source stays visual-derived
through summarization, so compaction cannot restore tool or auto-approval access.
See [context contract and real-model evidence](CONVERSATION_CONTEXT.md).

`ModelClientFactory.live` trusts only HTTPS hosts saved in the external local
configuration and credentials bound to that exact host. Saving a key persists
only the captured endpoint and credential reference into the latest file; drafts
are rebased field by field to preserve current unsaved edits. Runtime settings
are not bundled. `EvieLocalBrainLauncher` separates process identity (safe stop)
from exact model/KV/prefill/cache compatibility (safe reuse), authenticates health,
and reconciles configuration on next use. The optional allocator bootstrap uses
public `mlx.core.set_cache_limit` before the unmodified CLI, with one sequence.
Real boundaries are documented in [settings validation](MODEL_SETTINGS_VALIDATION.md)
and [launcher validation](LOCAL_BRAIN_VALIDATION.md).

## Native URL and voice lifecycle boundaries

The application delegate parses one bounded cold-launch request or delivers to
the live coordinator. `evie://open` opens UI; `evie://prepare?text=...` prepares
a reviewed draft without replacing existing text or submitting; `evie://capture`
opens single-use capture confirmation. The parser rejects unknown routes and
extra authority. Native URLs preserve the emergency-stop wake latch. Confirmation
closes before rechecking live guards and invoking the existing capture path;
sleep, inactive session, close, cancel, stop and shutdown revoke it synchronously.

Voice input has a generation across device/transcriber preparation, audio startup
and final transcription. PTT release revokes preparation before an audio tap
exists; stale continuations stop audio and cannot deliver old text. Preparation
and capture review exclude competing voice/research admission. A canceled normal
PTT preparation returns wake listening; emergency stop remains latched. The
exact coordinator methods have fifteen controlled lifecycle regression cases,
including two causal negative controls. The real capture controller has its own
[notification/lifecycle regression](NATIVE_CAPTURE_VALIDATION.md). These fixtures
complement the installed native microphone and transcription checks.

## Current capture and web boundaries

Research isolates capture-only clipboard inference from answer entry/selection;
both have revocable consent leases. No continuous research capture is added.
The public web fetcher validates all DNS addresses before every connection and
redirect, pins approved addresses, bounds decoded streaming bytes/time, and
runs without browser cookies, persistent cache or inherited proxies. This
boundary is separate from explicitly configured private model servers. Page
content is data and cannot authorize another action or network destination.

## Integration freeze and evidence

This is the final integration candidate's source contract. Full-suite execution,
adopted-runtime signed artifact checks, resource measurements,
installation and sanitized publication are separate gates. Their current status
is [PROJECT_STATUS](PROJECT_STATUS.md); pending gates are not completed by this
architecture description.

# Historical target architecture

The sections below preserve the original target and earlier vertical-slice
boundaries for traceability. Statements about missing executors, loopback-only
models or a future supervisor are historical, superseded by the current delivery
architecture and ADRs above. They do not describe the final integrated v2 runtime.

## Research shortcut sessions (2026-10-16)

`EvieResearchSession` holds a transient objective, destination and 15-minute
consent lease; it serializes runs and refuses expired or revoked deliveries.
`ResearchModeController` owns its consent window, cancellation, expiry timer and
bounded in-memory measurements. Two configurable actions use the existing
shortcut recorder and persistence. Clipboard turns use `EvieResearchAnswer`
with one image and no tools/history. Control turns reuse `ComputerUseHost`, with
`researchShortcut` as a start-only gesture and a grant deadline capped by the
research lease. Chat/voice/capture submissions cannot race research. Sleep and
user-session deactivation stop it. No worker or continuous capture is added.
The selected brain is pinned for each consent session, then resolved afresh
when the next session is armed. See [ADR 0020](adr/0020-expiring-research-shortcut-sessions.md)
and [research methods](RESEARCH_MODE.md).

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
  ModelClientFactory -> OpenAICompatibleClient
                    |
                    v
  ModelTransportPolicy -> Chat Completions SSE
  (loopback http, or https to the allowlisted PC with its bound key)
```

`EvieCore` owns backend-neutral message, phase, failure, usage, artifact, and
reducer types, plus nominal read/propose/commit capability contracts. SwiftUI does
not parse SSE or authorize backend output. The
application composition root is the only place that chooses the concrete
adapter, and it builds it through `ModelClientFactory`; the client's initialiser
is internal to EvieCore, so no call site can choose its own policy or key source.

The commit-authority contract is deliberately non-serializable and constructible
only inside EvieCore's future trusted broker path. It currently has no executor;
adding a filesystem/network implementation to the direct UI client remains
forbidden.

This direct connection was accepted for the prototype under
[ADR 0006](adr/0006-direct-turbo-vertical-slice.md), whose loopback-only and
no-credential clauses are superseded by
[ADR 0013](adr/0013-authenticated-tailnet-model-transport.md). Before any request
`ModelTransportPolicy` allows plain `http` only to loopback, and any other host
only over `https`, on an exact allowlist (by default the PC gateway
`models.example.invalid`), with a credential bound to that host. The
bearer token is read from the login keychain through a `CredentialReference` held
in the configuration, is attached only over `https` to its bound host, and every
redirect is refused so the header cannot follow one. The client still never
executes a tool.

Since v2 S1b each request carries `TurnOptions` (`AgentClient.stream(messages:
tools:options:)`): the reasoning level, the output cap (voice 1024, chat 2048, a
computer-use step 1024), and the model's readiness, which picks the deadlines.
The configuration's `ThinkingParameterStyle` says how the server is told to
think — `chat_template_kwargs` for the PC gateway, a top-level `enable_thinking`
for mlx-vlm (with `context_management: []`, so that server never compacts the
conversation itself), nothing for the loopback Gemma. The first system message goes out
byte for byte; any later system or developer message (skill guidance) is sent as
a `<system-context>` block on the next user message, so the cached prefix does
not move when a skill comes or goes. Reasoning is decoded apart from the answer
into `.reasoningDelta`, and a turn that spent its cap thinking is reported as
`ModelClientError.truncated` rather than as an empty answer. A watchdog bounds
the wait for the headers and for the first token (`ModelDeadlinePolicy`); the PC
holds its headers until prefill ends, measured, so the headers deadline is a
first-token deadline, not a connection check.

Since v2 S2b `ModelReadinessProbe` measures that readiness without asking the
model anything: `GET /health` at the gateway's origin with no key, `GET
/v1/models` with the key (the profile's entry gives `loadState`/`active` and
the vision and tools the server reports), and `GET /running` only when the list
has no load state; a Mac brain gets its loopback `/health`. `ModelReadinessCache`
keeps each answer 30 s, and the shell's `EvieReadinessRefresher` refreshes the
launch profile at launch, on activation and on `NWPathMonitor` changes. The
per-turn resolver reads the cache, and every turn carries the rung, so the
readiness deadlines apply.

Three of the original abstinences no longer hold, and they are worth naming rather
than leaving as an out-of-date boundary:

- the application now starts a process — the voice engine, and only when a trained
  voice is asked for;
- it now executes tools, in `EvieAgentLoop`, outside the transport;
- three of those tools propose — a filesystem change, a calendar event, and an
  outgoing message — which a person then approves.

What has not changed is the invariant those abstinences were protecting: no tool
the model can call changes anything. `propose_change` records a proposal and
returns a result saying plainly that nothing happened. `propose_event`, added in
`383a92c`, has the same shape and is enforced by a stronger structure: creating
the event is `EvieCalendarWriting`, a protocol `EvieAgentLoop` does not hold, so
there is no path from a tool call to the Calendar app at all.

`propose_mail`, added in `6dade94`, is the third and the one that reaches
somebody other than the owner. It has the same shape and a **third** protocol:
`EvieMailSending`, carrying `sendMail` and `saveMailDraft`, which the loop does
not hold and cannot be given — the stub its own tests run against has no sending
function to offer. The tool validates recipients, refuses any address the
conversation does not contain, resolves the account the message would leave from,
and draws a card listing every recipient in full with the whole body; the two
writing buttons are the only callers, they re-read the Mail and agenda switch at
the press, and there is no auto-approve path for mail at all. See
`docs/SECURITY.md`, [ADR 0010](adr/0010-refuse-unseen-mail-recipients.md) and
[ADR 0011](adr/0011-draft-beside-send.md).

Prompt injection reaches a card, not a filesystem, not an agenda, and not the
wire.

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
| Transport and loop | `AgentClient`, `OpenAICompatibleClient`, `ModelClientFactory`, `ModelTransportPolicy`, `EvieCredentialProviding` (`KeychainCredentialProvider`, `StaticCredentialProvider`), `TurnOptions`, `ModelDeadlinePolicy`, `ModelReadinessProbe`, `ModelReadinessCache`, `ModelClientError`, `InlineThinkingSplitter`, `EvieImagePart`, `EvieAgentLoop`, `EvieToolCallAccumulator`, `EvieTool` |
| Conversation | `ChatMessage`, `EvieConversation`, `EvieConversationStore`, `EvieConversationExport`, `EvieInteraction`, `EvieArtifact`, `EvieRichText` |
| Commands | `EvieCommand`, `EvieSearchCommands`, `EviePlan`, `EviePlanPrompts` |
| Retrieval and grounding | `EvieVaultRetriever`, `EvieVaultPassage`, `EviePassageRanker`, `EvieQueryTerms`, `EvieGrounding`, `EvieAnswerProvenance`, `EvieWebSearch`, `EvieWebPassages` |
| Files | `EvieRootRegistry`, `EvieFileToolbox`, `EvieScopedFileReader`, `EvieDocumentReader`, `EvieFileWriter`, `EvieFileChange`, `EvieChangeIntent` |
| Mail and calendar | `EvieMailCalendar`, `EvieAppleScripts`, `EvieMailCalendarTool`, `EvieMailMessage`, `EvieCalendarEvent`, `EvieCalendarEventProposal`, `EvieCalendarEventTool`, `EvieMailProposal`, `EvieMailTool`, `EvieMailSending` |
| Arithmetic | `EvieCalculator`, `EvieCalculatorTool` |
| Schedules | `EvieSchedule`, `EvieScheduleTrigger`, `EvieScheduleAgent`, `EviePropertyList` |
| Knowledge and identity | `EvieMemory`, `EvieSkill`, `EviePersona`, `EvieCapabilityContracts` |
| Computer use (`ComputerUse/`, ADR 0016) | `EvieAgentModeBroker` (grant, proposals, commits), `ComputerActionPolicy`, `ComputerUseBudget`, `ComputerAction`, `ComputerToolDefinitions`, `ObservationFormatter`; observing (S5b): `ComputerObserver` and its protocols, `AccessibilitySnapshotBuilder`, `ComputerObservationDiff`, `AccessibilityTrust`; the loop: `EvieAgentLoop.runComputerUse`, `ComputerUseSession`, `ComputerUseTranscript`; acting (S5c): `ComputerExecutor` and its protocols, `ComputerTyping`, `ComputerKeyCodes`, `ClipboardSession`, `ComputerAppCatalog`, `ComputerUseSwitch`; starting and controls (S5d): `ComputerUseStart` (`ComputerUseIntent`, `ComputerUseRequestOrigin`, `ComputerUseStopCommand`, `ComputerUseCopy`), `EvieSyntheticInput`, `ComputerUserPress`, `ComputerConfirmationDesk`, `ComputerUsePause`, `ComputerTakeoverRule`, `ComputerActionLog` |
| Voice | `EvieTTS`, `OmniVoiceBatchTTSAdapter`, `EvieSpeechGate`, `EvieSilenceTrim`, `EvieWakePhrase`, `EvieWakeGate` |
| Settings and release | `EvieConfiguration`, `EvieConfigurationLoader`, `EvieConfigurationStore`, `EviePreferences`, `EviePreferencesStore`, `EvieShortcut`, `EvieRelease` |
| Presentation-adjacent | `EvieOverlayGeometry`, `EvieThinkingWave`, `EvieBrainChip` (the chip's words, dot and menu, `EvieBrainChoice`), `EvieSettingsSection` (the settings sidebar) |
| Process | `SecureProcessRunner` |

`EvieShell`, by what it owns:

| Area | Types |
|---|---|
| Composition and windows | `EvieShellApp`, `AppCoordinator`, `EvieReadinessRefresher`, `OverlayPanelController`, `SettingsWindowController`, `ConversationHistoryWindowController`, `GlobalHotKeyController` |
| Overlay state | `OverlayViewModel` plus `+Turn`, `+History`, `+Plan`, `+Search`, `+Brain` (the brain chip); `OverlayChromeModel` |
| Other view models | `ConversationHistoryViewModel`, `EviePreferencesViewModel`, `ModelSettingsViewModel`, `EvieRootsViewModel`, `EvieMemoryViewModel`, `EvieSkillsViewModel`, `EvieVoiceLibraryViewModel` |
| Audio | `EvieAudioCapture`, `EvieLevelMeter`, `EvieSpeechTranscription`, `EvieSpeechOutput`, `EvieOmniVoiceClient`, `EvieVoiceEngineLauncher`, `EvieWakeListener` |
| Reading the world | `EvieVaultIndex`, `EvieVisionDescriber`, `EvieDocumentAttachment`, `EvieMediaStore`, `EvieWebClient`, `EvieSkillStore`, `EvieMailCalendarClient` |
| Computer use (`ComputerUse/`) | `AccessibilitySnapshotter` (`AXTree`), `AccessibilityPermission`, `ComputerScreenLocator` (and `ScreenPresence` as the observing and acting indicator), `ComputerObserveCheck` (`--cu-observe`); acting (S5c): `MacComputerActor` (wires `ComputerExecutor`), `SyntheticInput`, `AccessibilityActions`, `FocusCoordinator`, `AppLauncher` and `InstalledApps`, `SystemPasteboard`, `ComputerSelfTest` (`--cu-selftest`); `Views/ScreenAndAgentSettingsView`; the session (S5d): `ComputerUseHost` (broker, executor, pause, desk, monitor, the grant's clock), `TakeoverMonitor`, `OverlayViewModel+ComputerUse` (the cards and the session turn), `Views/ComputerUseCardViews` (`HandPressCatcher`, the thumbnail) |
| Schedules | `EvieLaunchAgents`, `EvieScheduleStore`, `EvieScheduleRunner`, `EvieScheduleLock`, `EvieScheduleNotifier`, `EvieSchedulesViewModel` |
| Diagnostics | `EvieDiagnostic`, `EvieDiagnosticRegistry`, `EvieDiagnostics` plus its subject files (`+UISnapshots`: `--ui-snapshots <pasta>` draws the brain chip, an answer card and Settings offscreen to PNG) |
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

1. the compiled built-in profiles (`EvieModelProfileSet.builtIn`): `pc-3090`, the
   PC gateway's `qwen-daily`, preferred, then `mac-local`, LensVLM on loopback
   port 38480, started on demand (S3);
2. versioned JSON at `~/Library/Application Support/Evie/config.json` (or another
   absolute path selected through `EVIE_CONFIG_FILE`), schema v2: a list of
   profiles, a preference order and the Mac-fallback choice;
3. supported non-secret environment overrides: `EVIE_MODEL_PROFILE` picks the
   profile in use, and the other `EVIE_MODEL_*` variables override that profile
   for the run.

The profile is flattened into the `EvieConfiguration` the client reads. Which
profile a turn runs on is decided per conversation, before the turn is built
(v2 S2c, [ADR 0014](adr/0014-model-profiles-per-turn-resolution-failover.md)):
`EvieBrainResolver` keeps the preferred profile unless it cannot answer — a key
not saved, known from the keychain alone (`EvieProfileSelector.offlineRung`), or
the cached probe finding it unreachable, its key refused or its model unknown —
and then walks the preference order for one that can. The conversation is
pinned to that profile for the app session. A turn that fails before its first
delta with an unreachable server, a headers timeout, a refused or missing key,
or a 502 is rebuilt for the next profile and retried once (`EvieBrainTurn`), and
the conversation is re-pinned. Every move follows the Mac-fallback choice: off
never moves, automatic moves, ask asks before waking the Mac brain ("O PC está
fora. Acordar o cérebro do Mac? (~10 s, ~8 GB de memória)") and a yes holds for
the session. A profile chosen by the environment is never moved. The overlay's
brain control can narrow the order to one place
(`EvieBrainResolver.choose(_:)`: Sempre o PC never moves to the Mac, Sempre o
Mac wakes it without asking). An explicit popover selection saves first and
releases the current conversation pin for its next reply (ADR 0021); other pins
and historical answer labels remain unchanged. Waking a
`.localOnDemand` profile goes through `LocalBrainStarting`, implemented by
`EvieLocalBrainLauncher` since v2 S3 (ADR 0015): it starts `mlx_vlm.server` on
127.0.0.1:38480 with `LocalBrainPolicy`'s argv and offline environment, refuses a
port held by anything but that server and a start with under 8 GiB free, checks
before every turn that the listener is the configured executable, and stops it
after 10 idle minutes or when Evie quits. `Scripts/evie-brain` is the manual
path to the same server. `EvieTurnPlan` derives the turn
from the profile: the character budget, the persona's location sentence, tools
only for a profile that has them (otherwise the folders and the web are searched
first and the model is asked once with no `tools` key), pictures only with
vision, and the readiness rung in `TurnOptions`.
A schema v1 file (one endpoint) is migrated in place: its endpoint becomes the
profile `custom`, kept after the built-ins and outside the preference order, and
the original bytes are kept as `config.json.v1.bak`. A file or environment that
cannot be used — damaged, an unknown schema version, an invalid profile —
falls back to the built-ins and shows "Configuração local inválida"; launch never
blocks on it. The loader does not read credentials or print configuration. A
profile holds a `CredentialReference` (keychain service, account, bound host),
never a key.

The "Cérebro" settings tab (v2 S2d) edits the preferred profile (the head of the
preference order), the Mac-fallback choice and each profile's endpoint, model,
context cap, output cap, default reasoning and sampling, through
`EvieProfileDraft`; the endpoint is checked live against `ModelTransportPolicy`
with the profile's own credential. It saves through
`EvieConfigurationStore.saveProfiles`, which re-reads the file, applies only the
drafts that changed, never writes an environment override, and writes schema v2
with atomic replacement and mode `0600`; the resolver then takes the reloaded
profiles, so the next turn uses them. A damaged file is repaired from the profiles Evie
launched with, after its bytes are kept as `config.json.damaged.bak` (`0600`); a
file from a newer schema, or one that cannot be read and so cannot be backed up,
is left alone and the save fails with the reason. "Testar conexão" runs
`ModelReadinessProbe.connectionReport(for:)` on the profile as edited: the
probe's steps (reachable, key accepted, model loaded) with the time each request
took, and the server's model list for the model field. The tab also saves the PC
key into Evie's own keychain item, pasted or copied once from the PC
configuration's item (`EvieModelKeys`); see `docs/SECURITY.md`.

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
