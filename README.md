# Evie AI

Evie is a local-first personal AI assistant for macOS, pronounced **"ee-vee"**
("ívi"). It is intended to be available by voice or a global shortcut without
behaving like a permanent chat window.

The project now has two **source-implemented vertical slices** and a bounded local
development-runtime controller. A native menu-bar/overlay shell opens ready for
text, streams Gemma into glass result cards, supports continuous follow-ups, and
stores visible sessions locally for a deliberate history window. Model sampling
preferences have a native settings window. The controller pins and prepares the
server/model outside Git; it is development tooling, not the future supervisor or
a persistent background service. Target-Mac UI acceptance remains open.

## Product intent

Evie should eventually provide:

- a lightweight, always-available macOS presence;
- push-to-talk and optional wake-word activation;
- a transient visual overlay with audio feedback and expandable glass cards;
- local speech-to-text, language-model inference, RAG, vision, and TTS;
- bounded tools for email, calendars, drives, files, WhatsApp, and web research;
- inspectable schedules, webhooks, triggers, and visual workflows;
- explicit approval before external or destructive actions;
- aggressive unloading of heavy workers while idle.

## Proposed foundation

- **Agent runtime:** Hermes Agent, using a dedicated Evie profile.
- **Primary model:** Gemma 4 26B-A4B IT through TurboFieldfare at 64K context.
- **Model alternatives:** smaller local models evaluated against Evie-specific tasks.
- **RAG:** local hybrid retrieval with a small embedding model and optional reranker.
- **Vision:** a separate local VLM loaded only for image tasks.
- **Speech-to-text:** local Whisper-class backend, selected by benchmark on Apple Silicon.
- **Text-to-speech:** OmniVoice through its CLI/Python backend, without its web UI.
- **Automation:** Node-RED as a local deterministic workflow engine and visual canvas.
- **Interface:** a native SwiftUI/AppKit macOS utility app and lightweight supervisor.

The architecture is intentionally replaceable: Hermes, TurboFieldfare, the VLM,
the retrieval engine, and the TTS engine remain behind local adapters.

## Implemented now

VS-001 and VS-002 contain:

- a Swift 6 package with backend-neutral `EvieCore` contracts;
- a loopback-only streaming client for TurboFieldfare Chat Completions;
- a native SwiftUI/AppKit menu-bar utility and transparent floating `NSPanel`;
- launch-time focused input, `Option-Space` open/hide, and a secondary
  `Option-Shift-Space` text shortcut;
- native vibrancy, compact state pill, data-driven waveform component, and
  expandable artifact cards inspired by CLUI CC's interaction grammar;
- cancellation and explicit unavailable/malformed-server states;
- an honest system prompt that cannot claim tools or integrations that do not yet
  exist;
- typed non-secret configuration with precedence `defaults < local JSON <
  environment`;
- continuous multi-turn input with complete visible transcripts persisted in
  user-only, schema-versioned per-conversation records;
- deliberate native History and Settings windows with explicit history deletion
  confirmation and live next-request sampling changes;
- tested nominal read/propose/commit contracts whose opaque process-local authority
  cannot be constructed from model/tool JSON; no actual tool executor is enabled;
- a tested one-shot OmniVoice TTS adapter with private stdin transport,
  process-group cancellation, supported-library offline-resolution flags, bounded
  RIFF/WAVE validation, and best-effort temporary cleanup; it has no active UI,
  playback, configured personal voice, network sandbox, or executable identity
  pin yet;
- a pinned `Scripts/evie-runtime` development workflow for setup, verification,
  explicit start/stop, health, synthetic inference smoke testing, and launch.

The slices do not yet contain voice capture/playback, STT, active TTS, tools, web
search, RAG, Hermes, supervisor lifecycle, automations, personal integrations, or
semantic memory. See the [VS-001 implementation guide](docs/implementation/VS_001.md)
and [VS-002 guide](docs/implementation/VS_002.md) for exact boundaries and manual
acceptance checklists.

## First local test workflow

The setup command clones TurboFieldfare at revision
`7a99f2a635e3adf7ed0720b882d2edb600f2f0da`, builds its release server and
repacker, downloads/repackages Gemma, verifies the installed model, and creates a
local configuration. The model ID is `gemma-4-26b-a4b-it`; the server is launched
on loopback with a declared 65,536-token context.

```bash
Scripts/evie-runtime setup
Scripts/evie-runtime doctor
Scripts/evie-runtime smoke
Scripts/evie-runtime launch
```

`setup` is resumable when TurboFieldfare leaves its `.partial` and resume metadata.
It requires at least 25 GiB free before starting and never places runtime source,
model weights, local configuration, PID state, or logs in this checkout. Use
`Scripts/evie-runtime doctor`, `status`, `start`, `stop`, and `verify` provide
explicit preflight, lifecycle, and integrity checks. `Scripts/test` runs the Swift
tests with the compatibility flags needed by the current macOS 27 Command Line
Tools installation.

The current target Mac successfully built the pinned TurboFieldfare release
products using Apple Command Line Tools alone. Upstream still documents Xcode 26
as its supported prerequisite, so this observation is not a portability guarantee
for other machines.

On 2026-08-04, this base M5/24 GB Mac verified all 37 installed model files and
passed model discovery, a non-streaming response, and an SSE response ending in
`[DONE]` at a declared 65,536-token context. This establishes first-test wiring,
not long-context correctness or a full performance benchmark; exact evidence is
in [Project status](docs/PROJECT_STATUS.md).

## Local configuration

Evie loads built-in defaults, then the versioned JSON file at
`~/Library/Application Support/Evie/config.json`, then supported environment
overrides. `EVIE_CONFIG_FILE` may select another absolute JSON path. See
[`config/examples/model.example.json`](config/examples/model.example.json) and
[`.env.example`](.env.example) for the non-secret schema and implemented model
override names.

Invalid configuration is shown in the overlay instead of being silently accepted.
The development controller creates the default file with user-only permissions.
No credential belongs in either example or the model configuration.

## Documentation map

- [Current status](docs/PROJECT_STATUS.md)
- [Roadmap](docs/ROADMAP.md)
- [Feasibility assessment](docs/FEASIBILITY.md)
- [System architecture](docs/ARCHITECTURE.md)
- [Model and context strategy](docs/MODEL_STRATEGY.md)
- [Resource and standby budget](docs/RESOURCE_BUDGET.md)
- [Interface and interaction model](docs/UI_UX.md)
- [Voice architecture](docs/VOICE.md)
- [Hermes integration direction](docs/HERMES.md)
- [RAG design](docs/RAG.md)
- [Web-search design](docs/WEB_SEARCH.md)
- [Automation design](docs/AUTOMATIONS.md)
- [Security model](docs/SECURITY.md)
- [Testing and evaluation](evals/README.md)
- [Agent handoff protocol](docs/HANDOFF.md)
- [Implementation task ledger](docs/implementation/TASKS.md)
- [VS-001 implementation and run guide](docs/implementation/VS_001.md)
- [VS-002 conversation/history/settings guide](docs/implementation/VS_002.md)
- [Work log](docs/WORKLOG.md)
- [Decision records](docs/adr/README.md)
- [Research sources](docs/RESEARCH_SOURCES.md)

## Repository boundary

This repository contains source code, documentation, schemas, sanitized workflow
definitions, and configuration examples. Runtime state and private data must stay
outside Git. The current development layout uses
`~/Library/Application Support/Evie/` for the pinned runtime, model,
  configuration, conversation history, and process state, plus
  `~/Library/Logs/Evie/` for the local server log. Private/runtime material includes:

- OAuth tokens and API credentials;
- WhatsApp session material;
- Node-RED credential files;
- voice-reference recordings;
- email, calendar, Drive, and personal document content;
- vector indexes, model weights, caches, transcripts, and logs.

See [.gitignore](.gitignore) and [Security](docs/SECURITY.md) before adding any
integration.

## Status

VS-001 and the local runtime/configuration tooling are implemented at source
level; VS-002 adds continuous text, visible local history, and model settings. The
pinned TurboFieldfare runtime, verified Gemma installation, 64K server, synthetic
inference, and native process launch have passed on the target Mac. The updated
shortcut/focus/history/settings acceptance, Phase 1 benchmark matrix, and Phase 2
supervisor/lifecycle gates remain open.
