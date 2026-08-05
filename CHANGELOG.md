# Changelog

All notable changes to Evie are documented here. Dates use `YYYY-MM-DD`.

## [Unreleased]

### Fixed

- Clicking the mark crashed Evie once the microphone was granted. The audio tap's
  closure was written inside a `@MainActor` method, so it inherited main-actor
  isolation whatever its type said; the tap invokes it on a real-time audio
  thread, where Swift checks the executor and traps. The closure now lives in a
  `nonisolated` method, and `evie-shell --voice-check` exercises the whole path
  from the command line.
- The mark went back to the sparkle. An ASCII key is in the history if it is ever
  wanted larger; at thirty points the sparkle is simply the better mark.
- The mark breathes again, drawn in Core Animation layers rather than SwiftUI.
  Measured: the SwiftUI version cost 22% of a core with an animated shadow, 10%
  with only a scale, 8% with the content rasterised, and 2.7% once the animation
  moved to a `CABasicAnimation` the render server interpolates.
- The window handles no longer draw two pale bars down the sides of the overlay.
  Resizing is an invisible strip with a resize cursor, which is the affordance
  macOS uses for window edges anyway, and the drag grip is invisible at rest.
- The overlay's glass was being clipped. The content frame was set to the full
  window width and *then* padded, making it 36 points wider than the window, so
  the card's rounded corners, hairline border, and side shadow were cut off — the
  reason it stopped reading as glass. The transparent margin is now wider than the
  shadow's reach, so the shadow fades out instead of ending on a hard line.
- The mark did not read as a key at any size. Each character of the artwork was
  being replaced by a glyph from a shading ramp according to how solid it was,
  which is the technique for turning a photograph into ASCII; applied to art that
  was already ASCII it destroyed the drawing. The light now changes only how
  bright a character is, never which character it is.
- The window handles no longer occupy layout space or show at rest. They live in
  the transparent margin as overlays and appear on hover, so the resting overlay
  is exactly what it was before they existed.
- The palette returned to the system colours the interface already used. One value
  is still substituted, and only in light appearance, where `.mint` measures
  1.82:1 against the HUD — below the 3:1 WCAG asks of a graphical object. Dark
  appearance is untouched.

### Added

- `EvieScopedFileReader`: reading inside a folder the user granted, contained by
  the kernel rather than by inspecting path strings. A descriptor for the root
  plus `O_RESOLVE_BENEATH` and `O_NOFOLLOW_ANY`, walking one component at a time,
  so a symlink partway along the path is refused too. Verified: symlink escapes
  fail with `ELOOP`, `..` and absolute paths fail with `ENOTCAPABLE`.
- A denylist that applies inside granted folders, because granting a folder is not
  consent to hand over the credentials that live in it. Denied entries are
  withheld from listings with a count rather than named.
- Speech recognition through the system's own recogniser. It supports Brazilian
  Portuguese, streams a partial transcript while you are still speaking, and runs
  in a system daemon rather than inside Evie — so it does not compete with the
  26B model for the 24 GB of unified memory that is the real constraint here.
- A closed microphone that produced words submits them as an ordinary question,
  through the same path typed text uses. A leftover partial guess is discarded
  rather than submitted.
- `evie-shell --speech-check` reports whether this Mac can transcribe Portuguese
  and whether the language pack still has to be downloaded, without opening the
  microphone.
- The persona now derives from what is actually built: with a bundle identity and
  system recognition present, Evie says she can hear and can read documents, and
  still says plainly that she cannot speak, reach folders, or search the web.
- Evie can read images and PDFs. `EvieDocumentReader` uses the system's own text
  recognition — no model downloaded, nothing leaving the Mac — and chooses per
  page between a PDF's embedded text layer and recognising the pixels, because a
  typed report with a scanned annex is an ordinary document.
- Drop a file on the overlay or use the paperclip to attach it. Attaching does not
  ask anything: the card shows what was read and with what confidence, and the
  text travels with the next question.
- Document text reaches the model fenced and labelled untrusted, with its source,
  page, and lowest confidence. Verified against a PDF that instructs Evie to
  ignore her rules and delete a folder: she reported it as an injection attempt
  and kept her own identity.
- `evie-shell --read <file>` prints exactly what Evie would receive from a file.
- `Scripts/evie-app`: builds `Evie.app` from the SwiftPM product with a stable
  bundle identifier, usage descriptions, and a signature, then installs, launches,
  and reports on it. This clears the hard blocker for voice — measured on this
  Mac, an unbundled binary touching `AVAudioEngine().inputNode` does not fail, it
  hangs the main thread inside `coreaudiod` forever, because TCC has no
  application to name and no description to show.
- `EvieAudioCapture`: microphone ownership with the permission checked and
  requested *before* the engine is built, real level metering through vDSP with a
  fast attack and slow release, levels published at a bounded rate, and a stop
  that stops the engine rather than discarding buffers.
- Clicking the mark toggles listening; push-to-talk holds it open and closes it on
  release. Both routes go through the same activation path.
- `evie-shell --audio-check` reports bundle identity, usage description, and
  microphone status without ever asking for consent.
- A real settings window, in five tabs: Atalhos, Voz, Aparência, Modelo, and
  Diagnóstico. Changes are written as they are made rather than behind a Save
  button, because a preference that only applies once you remember to press Save
  is a preference that quietly does not apply.
- A shortcut recorder for all eight actions, with per-action disable and reset,
  the conflicting action named in place, and a row that says so when the system
  refuses a combination another application already owns.
- Global shortcuts are now driven by the preferences at runtime: registration is
  per action, a refusal costs only that one shortcut, and re-registration happens
  as soon as a binding changes.
- Two new global actions: toggle call mode, and stop everything, which cancels the
  running answer and puts the overlay away.
- A Diagnóstico tab, the only place the interface shows the model name, the
  loopback address, and the local file paths, each copyable.
- `evie-shell --open-settings` opens the window without a mouse. Evie has no Dock
  icon, so an unavailable shortcut would otherwise leave no way in.
- Evie's own identity: `EviePersona` generates the hidden system message from an
  explicit capability snapshot, names Matheus Barboza de Godoi as her creator,
  addresses him as `você`/`seu` with masculine agreement, and can only claim a
  capability whose flag is switched on. `evie-shell --print-persona` prints it.
- `EviePreferences` and `EviePreferencesStore`: appearance, eight configurable
  shortcut actions with conflict detection and per-action disable, and voice
  switches, in a `preferences.json` kept separate from the model configuration.
- The call-mode dependency is enforced in the type: turning speech off leaves call
  mode, turning call mode on turns speech on, and the inconsistent pair fails
  validation before it can be written.
- `EvieOverlayGeometry`: overlay placement resolved from preferences and connected
  displays, with clamping, resize around the window centre, and recovery to the
  anchored default when the saved display is gone.
- The overlay can be dragged anywhere, resized from either edge, and restored to
  bottom-centre at its original width by a button that appears only once the
  placement differs from the default. Placement persists outside Git.
- Evie's mark: a key drawn as ASCII on a square-celled `Canvas`, in three grid
  densities chosen by rendered size, tilted in 3D by Core Animation and lit by a
  travelling shading ramp while she is listening, speaking, or thinking. Clicking
  it requests voice activation; the request is honest that voice is not yet wired.
- A reactive ring around the mark that encodes direction twice: incoming audio
  grows inward with thin bars, outgoing audio grows outward with thick ones.

### Changed

- The default local endpoint moved from port `8080` to `38433`, chosen outside the
  IANA registry and below the ephemeral range so it cannot collide with another
  project or be taken by an outgoing connection.
- No interface surface names the model or the inference server any more. "Gemma
  local", "TurboFieldfare", and the loopback host and port are replaced by "Evie ·
  assistente pessoal" and "Modelo local"; the raw endpoint remains available for
  diagnostics only.
- The overlay panel now follows the height SwiftUI actually measured instead of
  estimating it, and the scroll mask fades over a real distance at both edges and
  only when the list overflows. Together these fix the clipped background fade.
- The voice palette was replaced with values measured for contrast. The previous
  listening tint resolved to 1.82:1 against the HUD in light mode, below the 3:1
  WCAG requires for a graphical object; the new pair clears 4.5:1 in both
  appearances and resolves per appearance through `NSColor`.

### Fixed

- Hiding the overlay now stops its animation. `orderOut` does not stop a SwiftUI
  timeline: a hidden overlay was measured redrawing at 55 fps and burning 2.5% of
  a core. The motion gate is lowered before the window is ordered out, and window
  occlusion is observed as well. Idle CPU with the mark animated measured 0.0%.

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
