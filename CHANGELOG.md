# Changelog

All notable changes to Evie are documented here. Dates use `YYYY-MM-DD`.

## [Unreleased]

### Added

- Initial feasibility, architecture, security, UI, voice, RAG, automation, model,
  resource, roadmap, handoff, and evaluation documentation.
- Repository-wide agent continuity and documentation contract.
- Sanitized configuration examples and defensive ignore rules.
- Initial ADRs for a documentation-first phase, the primary model strategy, and
  specialist workers.
- Swift 6 package with the backend-neutral `EvieCore` interaction model and state
  reducer.
- Loopback-only TurboFieldfare Chat Completions client with SSE text/usage
  streaming, typed failures, bounded HTTP error reads, and cancellation.
- Native macOS menu-bar shell, floating `NSPanel`, global summon/quick-text
  shortcuts, and one cancellable quick-text-to-Gemma interaction.
- Original native-glass capsule, data-driven waveform component, status states,
  expandable artifact/error cards, and accessibility fallbacks inspired by CLUI
  CC's interaction grammar.
- Complete implementation task ledger, VS-001 build/run/acceptance guide, and ADR
  0006 for the temporary direct inference seam.
- Typed versioned local model configuration with documented
  `defaults < JSON < environment` precedence, actionable validation failures, and
  redacted tracked examples.
- Pinned `Scripts/evie-runtime` first-test workflow for resumable setup,
  configuration, upstream verification, explicit loopback start/stop/status,
  synthetic non-streaming/SSE smoke testing, and native-shell launch.
- `Scripts/test` compatibility wrapper for Swift Testing with the current macOS 27
  Command Line Tools layout.
- ADR 0007 for keeping the pinned TurboFieldfare runtime, Gemma model, local
  configuration, process state, and logs outside Git without a persistent service.
- Deterministic configuration and TurboFieldfare protocol fixtures covering SSE
  fragmentation, CR/LF variants, heartbeats, usage, completion, errors, loopback,
  and unfinished streams.
- A `doctor` preflight for target OS/architecture, toolchain commands, storage,
  memory, runtime revision, model presence, binaries, and local file permissions.
- VS-002 continuous follow-up input that preserves answer cards, opens focused at
  launch, uses `Option-Space` for text open/hide, and preserves drafts on hide,
  cancellation, and backend failure.
- Actor-isolated, schema-versioned local conversation records with atomic writes,
  `0700`/`0600` permissions, per-record corruption containment with an opaque UI
  warning, full visible transcripts, and guaranteed exclusion of hidden
  system/developer prompts.
- Deliberate native conversation-history UI for listing, viewing, resuming,
  creating, and explicitly confirming deletion of local sessions.
- Native model settings UI and atomic configuration writer for temperature, top-p,
  completion limit, and timeout, including custom config paths, environment-owned
  field indicators, optional server defaults, and next-request application.
- ADR 0008 and VS-002 handoff/acceptance documentation for local history and
  settings before Hermes.
- Current implementation research for a deny-by-default pinned Hermes profile,
  no-Docker DDGS web research, on-demand QMD RAG, native “E aí, ívi” wake-word,
  PT-BR STT, speaker enrollment, and reuse of installed OmniVoice assets.
- Backend-neutral nominal read/propose/commit capability contracts with redacted
  material metadata, provenance, immutable revisions/expiry, and opaque
  non-serializable authority; destructive delete cannot use standing-policy
  evidence. These contracts execute no tool.
- Backend-neutral TTS contracts and a defensive one-shot OmniVoice batch adapter
  that sends private JSONL through stdin, validates local model/tokenizer/reference
  paths, requests offline resolution from supported libraries, isolates the process
  group, bounds timeout and output size, validates RIFF/WAVE structure, kills
  descendants on cancel, and performs best-effort temporary cleanup. It is not a
  network sandbox, does not yet pin the configured executable identity, and is not
  connected to playback or a real voice profile.

### Changed

- Project status advances from planning-only to source-implemented VS-001 while
  keeping manual target-UI acceptance and the full latency/throughput/context/
  battery/energy benchmark explicitly open.
- The first-test runtime is pinned to TurboFieldfare revision
  `7a99f2a635e3adf7ed0720b882d2edb600f2f0da`, model ID
  `gemma-4-26b-a4b-it`, and a declared 65,536-token loopback launch; its verified
  local installation and synthetic non-streaming/SSE smoke test now pass on the
  target Mac.
- Replaced `URLSession.AsyncBytes.lines` in the SSE adapter with a byte-level line
  decoder because the former discarded empty event separators and could combine
  valid events into malformed JSON.
- Kept the development controller alive while the shell runs so it reaps a stopped
  server cleanly, and made repeat launches reuse the current release binary until
  package/source files change.
- The menu-bar surface now exposes Converse, New Conversation, History, Show/Hide,
  Settings, local endpoint, and Quit instead of requiring the secondary quick-text
  shortcut for every turn.
- Conversation switching uses generation checks, deletion drains pending writes,
  and application termination waits for history persistence so stale asynchronous
  work cannot resurrect or silently lose a completed session.

## [0.0.1] - 2026-08-04

### Added

- Private planning repository bootstrap for Evie AI.
