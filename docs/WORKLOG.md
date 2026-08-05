# Work log

## 2026-08-04 — Codex — Phase 0 repository bootstrap

- Commit: initial planning repository bootstrap
- Phase: Phase 0 — feasibility and architecture
- Completed:
  - researched TurboFieldfare, Hermes Agent, OmniVoice, Node-RED, QMD, CLUI CC, and
    native macOS overlay/lifecycle options;
  - calculated the current TurboFieldfare FP16 KV layout through 64K;
  - recorded the upstream failed/removed Q4 KV experiment;
  - defined architecture, lifecycle, UI, voice, RAG, automation, security, roadmap,
    evaluation, and handoff plans;
  - established defensive Git boundaries for secrets and personal data.
- Files/components:
  - documentation-only initial repository.
- Validation:
  - documentation links use upstream/official sources;
  - local repository and secret scans to be recorded before commit.
- Decisions/measurements:
  - 64K FP16 KV is approximately 1,505 MiB by source layout calculation;
  - Q4 KV is excluded from the baseline after upstream speed and quality failures;
  - native SwiftUI/AppKit shell preferred over reusing CLUI CC Electron runtime.
- Risks/blockers:
  - all runtime performance remains unmeasured on the exact base M5 machine;
  - no integrations or workers have been installed.
- Next action:
  - review and publish the planning repository privately, then build only the Phase
    1 benchmark harness after explicit implementation approval.

## 2026-08-04 — Codex + parallel agents — VS-001 native quick-text slice

- Commit: `0979269` on `agent/native-overlay-foundation`
- Phase: Phase 1 inference foundation + Phase 2 native-shell prototype
- Tasks: `FND-001`, `CORE-001`, `INF-001`, `UI-001`–`UI-006`, `APP-001`,
  `DOC-001` done at source level; `QA-001` user-deferred
- Completed:
  - created a dependency-free Swift 6 `EvieCore` library with backend-neutral
    messages, phases, artifacts, usage/failure models, reducer, and streaming client
    protocol;
  - implemented the pinned TurboFieldfare Chat Completions SSE subset for text and
    usage, including cancellation, heartbeats, bounded HTTP failures, server errors,
    malformed/unfinished streams, and loopback-only endpoint enforcement;
  - implemented the native accessory/menu-bar lifecycle, dynamic transparent
    `NSPanel`, fixed prototype hotkeys, deliberate quick-text focus, cancellation,
    and focus relinquishing after submit;
  - implemented original native-vibrancy capsule, waveform, status, and artifact
    views inspired only by CLUI CC's visual/interaction grammar;
  - connected quick text to Gemma streaming with in-memory bounded turns, honest
    no-tools system guidance, completed/error cards, selection, copy, expand, and
    dismiss behavior;
  - added the complete implementation ledger, VS-001 run/acceptance guide, ADR
    0006, and synchronized architecture, model, security, UI, roadmap, status,
    changelog, agent, and handoff documentation.
- Files/components:
  - `Package.swift`, `Sources/EvieCore/`, `Sources/EvieShell/`;
  - `docs/implementation/`, ADR 0006, and repository continuity/design documents.
- Validation:
  - `swift format lint --recursive Sources Package.swift` — clean;
  - `swift build --target EvieCore -Xswiftc -warnings-as-errors` — passed;
  - `swift build --target EvieShell -Xswiftc -warnings-as-errors` — passed;
  - relative Markdown link checker — passed;
  - repository credential/private-key pattern scan excluding documented examples
    and ignored build state — no matches;
  - no runtime launch, real Gemma request, UI acceptance, or performance test was
    run, matching the user's request to test later;
  - CommandLineTools emitted only external linker search-path warnings for missing
    `Developer/usr/lib` and `Developer/Library/Frameworks`; Swift compilation had no
    warnings.
- Decisions/measurements:
  - ADR 0006 accepts a temporary backend-neutral/direct loopback adapter rather
    than coupling SwiftUI to TurboFieldfare or implementing a second agent loop;
  - implementation was checked against TurboFieldfare revision
    `7a99f2a635e3adf7ed0720b882d2edb600f2f0da` and its pinned server contract;
  - no latency, throughput, memory, energy, focus, or model-quality measurement is
    claimed.
- Security/privacy:
  - no credential fields, prompt/result logs, personal content, model weights,
    persistence, tools, microphone access, or external endpoint are present;
  - the upstream server remains manually owned and must stay on loopback.
- Risks/blockers:
  - `QA-001` still owns target focus, shortcut, Spaces, displays, accessibility,
    cancellation, and real server behavior;
  - the executable is a SwiftPM development utility, not a signed `.app` or login
    item;
  - server health/start/stop/crash/idle unload and 64K enforcement are not owned by
    Evie yet.
- Next action:
  - keep `QA-001` deferred; implement `CORE-002`, then use it for the bounded
    `SUP-001` supervisor/IPC decision spike.

## 2026-08-04 — Codex + parallel agents — First-test local Gemma runtime

- Commit: pending on `agent/native-overlay-foundation`
- Phase: Phase 1 inference readiness + VS-001 local configuration
- Tasks: `FND-002`, `FND-003`, and `INF-005` done; `QA-001` remains deferred
- Completed at this handoff:
  - added typed schema-versioned model configuration with precedence from defaults
    to local JSON to supported environment overrides;
  - added a pinned development controller covering resumable setup, configure,
    doctor, upstream verification, explicit start/stop/status, fixed synthetic
    smoke, and release-shell launch;
  - kept runtime source, Gemma assets, local configuration, PID state, and logs
    under `~/Library` and outside Git;
  - cloned TurboFieldfare revision
    `7a99f2a635e3adf7ed0720b882d2edb600f2f0da` and built its release repacker and
    server on the base M5/24 GB Mac with macOS 27 Command Line Tools;
  - installed and verified the requested Gemma model, fixed byte-level SSE framing
    exposed by deterministic fixtures, and passed real non-streaming/SSE requests;
  - fixed the development launch parent/child lifecycle after a stop test exposed a
    defunct server, then proved clean stop/reap and an immediate cached relaunch;
  - launched the release native shell with its local server and left both ready for
    the user's manual shortcut/focus/visual test;
  - documented the development boundary and migration path in ADR 0007.
- Files/components:
  - configuration loader/tests/examples, `Scripts/evie-runtime`, `Scripts/test`;
  - README, status, architecture, model, security, roadmap, VS-001/task ledger,
    changelog, and ADR 0007.
- Validation:
  - TurboFieldfare release `TurboFieldfareRepack` and
    `TurboFieldfareServer` build — passed on this exact Mac with Command Line Tools;
  - `swift format lint --strict --recursive Sources Tests Package.swift` — passed;
  - `Scripts/test` — 12/12 deterministic tests passed;
  - `swift build -c release -Xswiftc -warnings-as-errors` — passed, with only the
    external Command Line Tools linker search-path warnings;
  - `Scripts/evie-runtime verify` — passed 37 files / 14,291,915,755 bytes in
    10.65 s;
  - `Scripts/evie-runtime doctor` — passed with no installation blockers;
  - `Scripts/evie-runtime smoke` — model discovery, `PRONTA`, and SSE `[DONE]`
    passed at 65,536 declared tokens;
  - release `evie-shell` and TurboFieldfare processes remained resident and health
    returned `{"status":"ok"}`;
  - explicit `stop` terminated and reaped the server without force-kill or a zombie,
    then the final `launch` restored both healthy processes.
- Decisions/measurements:
  - pinned model ID `gemma-4-26b-a4b-it` and 65,536-token development launch;
  - Command Line Tools compatibility is an observed build result, while upstream's
    Xcode 26 requirement remains authoritative for portability;
  - recorded shell/server run on AC: server ready in a separately measured 3.14 s;
    synthetic requests completed in 5.393 s non-streaming and 0.882 s SSE; warm
    server footprint 3,215 MB, shell 18 MB, both sampled at 0.0% idle CPU, with
    53% system-wide memory free;
  - no throughput, sustained/long-context, battery, energy, model-quality, or
    rendered UI behavior is claimed from the tiny synthetic prompts.
- Security/privacy:
  - no credential, personal prompt, model asset, runtime log, PID, or real local
    config is committed; the endpoint remains loopback-only;
  - the controller creates no LaunchAgent and performs no automatic force kill.
- Risks/blockers:
  - the controller is not the future supervisor and lacks idle unload, crash
    recovery, power policy, and application-owned health events.
- Next action:
  - the user runs `QA-001` against the already launched Evie; after that, continue
    with `CORE-002` and the bounded `SUP-001` supervisor/IPC spike.

## 2026-08-04 — Codex + parallel agents — Continuous conversations and secure local foundations

- Commit: pending on `agent/native-overlay-foundation`
- Phase: VS-002 plus capability-policy and TTS adapter foundations
- Tasks: `APP-002`, `CORE-005`, and `VOI-007` done; `UI-012` in progress;
  `QA-005` deferred for the user's rendered target-Mac test
- Completed at this handoff:
  - changed the overlay from a one-question prototype into continuous multi-turn
    input: completed cards remain visible, a fresh focused field returns, hidden
    drafts survive, and cancelled/failed prompts can be retried;
  - made launch open directly into focused text input, promoted `Option-Space` to
    open/hide text, and expanded the menu-bar surface with conversation, history,
    settings, endpoint, visibility, and quit controls;
  - added actor-isolated, schema-versioned local conversation persistence, native
    list/detail/resume/delete UI, full visible transcripts, bounded inference
    context, per-record corruption containment with an opaque warning, atomic
    `0700`/`0600` storage, and termination-aware pending saves;
  - fixed stale-load, session-deletion/resurrection, mutable-selection, and
    application-termination races found during adversarial review;
  - added a native settings window and atomic local writer for temperature, top-p,
    completion limit, and timeout, respecting custom config paths and supported
    environment precedence without retaining unrelated environment variables; a
    valid save can repair malformed JSON at the selected absolute path;
  - added nominal read/propose/commit capability contracts with redacted metadata,
    bounded serialized size/depth/count/lifetime, target/revision binding, opaque
    non-serializable commit authority, and mandatory explicit-user evidence for
    destructive delete; no executor exists;
  - added a defensive one-shot adapter targeting the inspected OmniVoice 0.3.12
    CLI contract, using private stdin, supported-library offline-resolution flags,
    isolated process groups, bounded timeout/cancellation and 64 MiB output,
    RIFF/WAVE validation, private temporary files, and best-effort cleanup; it is
    not connected to a personal voice, playback, or the shell;
  - recorded implementation-grade Hermes, filesystem-broker, QMD RAG, DDGS search,
    wake-word, PT-BR STT, speaker-enrollment, and OmniVoice directions without
    installing or enabling those subsystems;
  - rebuilt and relaunched the release shell against the still-healthy local Gemma
    server, leaving it ready for manual testing.
- Validation:
  - `swift format lint --strict --recursive Sources Tests` — passed;
  - `Scripts/test` — 46/46 deterministic tests passed across six suites;
  - `swift build -c release --product evie-shell -Xswiftc -warnings-as-errors` —
    passed, with only the previously documented external Command Line Tools linker
    search-path warnings;
  - `Scripts/evie-runtime smoke` after relaunch — model discovery, `PRONTA`, and
    SSE `[DONE]` passed;
  - `git diff --check`, private-key/credential/absolute-personal-path scans, and
    relative Markdown-link validation — clean.
- Security/privacy:
  - conversation history, the real local model configuration, runtime/model state,
    prompts, voice references, generated audio, and credentials remain outside Git;
  - hidden system/developer prompts are rejected from persisted history;
  - no real filesystem, network, email, calendar, Drive, WhatsApp, RAG, Hermes,
    microphone, or TTS action is enabled by these source foundations.
- Risks/blockers:
  - launch/follow-up focus, visual history/settings behavior, Spaces/displays, and
    accessibility still need `QA-005` on the rendered app;
  - malformed/unavailable records are contained and counted without hiding readable
    sessions, but there is not yet a quarantine/repair UI; the last active session
    is not auto-restored on startup (it remains resumable from History);
  - the OmniVoice adapter has no real synthesis/latency/energy result and is not
    wired to playback or a configured voice; its executable identity/version is not
    pinned and offline flags are not a process network sandbox;
  - capability contracts deliberately cannot perform tools until the supervisor,
    resource scopes, approval UI, and revalidating broker exist.
- Next action:
  - run `QA-005`, establish a stable packaged `.app` identity/TCC path, and complete
    `CORE-002`/`SUP-001` before enabling push-to-talk, wake word, Hermes, or any real
    side-effecting integration.

## 2026-08-05 — VS-003 identity, window control, and the animated mark

- Scope: `Sources/EvieCore/{EviePersona,EviePreferences,EviePreferencesStore,EvieShortcut,EvieOverlayGeometry,EvieConfiguration}.swift`,
  `Sources/EvieShell/{AppCoordinator,EvieOverlayView,EvieShellApp,OverlayChromeModel,OverlayPanelController,OverlayViewModel,QuickTextEntryView,SettingsView}.swift`,
  `Sources/EvieShell/Views/{EvieMarkView,OverlayChrome,OverlayRootView,StatusPill}.swift`,
  `Tests/EvieCoreTests/{EviePersonaTests,EviePreferencesTests,EvieOverlayGeometryTests,EvieConfigurationLoaderTests}.swift`,
  `Scripts/evie-runtime`, `.env.example`, `config/examples/*`, `AGENTS.md`,
  `docs/{MACOS_RUNTIME,UI_UX,PROJECT_STATUS,ROADMAP}.md`,
  `docs/implementation/{VS_003,TASKS}.md`, `CHANGELOG.md`.
- Completed:
  - generated the hidden persona from a capability snapshot so Evie knows who
    created her, addresses him correctly, and cannot claim an unbuilt capability;
  - removed every model and server name, and the loopback host and port, from the
    interface, and moved the default port to 38433;
  - added a preferences file with appearance, eight configurable shortcut actions,
    and voice switches, with the call-mode/speech dependency enforced in the type;
  - made the overlay draggable, resizable, resettable, and persistent, with pure
    geometry resolution covered by tests including display disconnection;
  - replaced the estimated panel height with a measured one and rebuilt the scroll
    mask, fixing the clipped fade;
  - replaced the inert circle with the ASCII key mark, its 3D tilt, the reactive
    ring, and a voice-activation request that is honest about not being wired;
  - corrected the voice palette against measured WCAG contrast.
- Validation:
  - `Scripts/test` — 85/85 passed across ten suites, up from 46/46;
  - `swift format lint --strict --recursive Sources Tests` — clean;
  - `swift build -c release --product evie-shell -Xswiftc -warnings-as-errors` — passed;
  - `Scripts/evie-runtime smoke` on 38433 — model discovery, `PRONTA`, SSE `[DONE]`;
  - persona checked against the live model: correct name, form of address, and an
    honest refusal for filesystem access;
  - idle CPU of the release shell with the overlay visible: 0.0% over five samples,
    down from 8.1% in the first implementation of the mark.
- Measured findings recorded in `docs/MACOS_RUNTIME.md`:
  - `orderOut` does not stop a SwiftUI `TimelineView`; only removing it from the
    tree or pausing it does;
  - `context.resolve(Text:)` per glyph per frame costs roughly six times cached
    canvas symbols;
  - `@State` does not compile with Command Line Tools because it is a macro in the
    macOS 26+ SDK, and there is no Metal toolchain for custom shaders.
- Security/privacy: no credential, conversation, model asset, or personal path
  entered Git; preferences and placement live beside the existing local config
  with `0700`/`0600` permissions.
- Risks/blockers:
  - nothing in this slice has been accepted by eye on the target display; dragging,
    resizing, reset, the fade, mark legibility at 30 points, and the light/dark
    palette need `QA-006`;
  - voice remains unwired, so the ring has no real levels and clicking the mark
    only says so;
  - the settings window still shows the VS-002 model form; the new preferences have
    no UI yet.
- Next action: `UI-014` — the tabbed settings window, starting with the shortcut
  recorder, so the preferences that already exist become reachable.

## 2026-08-05 — VS-004 the settings window

- Scope: `Sources/EvieShell/{EviePreferencesViewModel,GlobalHotKeyController,AppCoordinator,SettingsWindowController,OverlayPanelController,OverlayViewModel}.swift`,
  `Sources/EvieShell/Views/{SettingsView,ShortcutSettingsView,VoiceSettingsView,AppearanceSettingsView,ModelSettingsView,DiagnosticsSettingsView}.swift`,
  `CHANGELOG.md`, `docs/implementation/TASKS.md`.
- Completed:
  - replaced the single model form with a five-tab window and moved the model
    settings into their own tab unchanged;
  - added a shortcut recorder driven by a local key monitor rather than
    first-responder plumbing, with validation, conflict naming, per-action disable,
    reset, and reset-all;
  - made `GlobalHotKeyController` data-driven: it registers from
    `EvieShortcutPreferences`, fails per action rather than wholesale, and returns
    the refusals so the interface can name them;
  - routed every shortcut through the same methods the menu bar uses, and added
    call-mode toggle and stop-everything;
  - gave the voice tab the two coupled switches with the dependency explained in
    place and a sentence stating which of the three presentations is active;
  - added the appearance tab (width, placement reset, mark animation) and the
    diagnostics tab, which is now the only surface showing the endpoint.
- Validation:
  - `Scripts/test` — 85/85 passed;
  - `swift format lint --strict --recursive Sources Tests` — clean;
  - `swift build -c release --product evie-shell -Xswiftc -warnings-as-errors` — passed;
  - launched with `--open-settings`: the process stayed resident with no output and
    resident memory rose from 104 MB to 124 MB, which is the window rendering.
- Risks/blockers:
  - no tab has been driven by hand yet; recording a shortcut, the conflict row, and
    the refusal row are all `QA-006`;
  - the voice tab writes preferences that nothing consumes yet, and says so;
  - `AppCoordinator` is getting long and will need splitting before the voice loop
    adds a capture controller to it.
- Next action: `PKG-001` — build `Evie.app` from the SwiftPM product, because
  microphone permission cannot be requested without a bundle identity.

## 2026-08-05 — PKG-001 and VOI-015: a bundle identity and a real microphone

- Scope: `Scripts/evie-app`, `Sources/EvieShell/{EvieAudioCapture,AppCoordinator,OverlayViewModel,EvieShellApp}.swift`,
  `CHANGELOG.md`, `docs/implementation/TASKS.md`.
- Completed:
  - packaged `Evie.app` with `com.matheusbgodoi.evie`, `LSUIElement`, and the
    microphone, speech, and folder usage descriptions;
  - added `identity` to create a self-signed code-signing certificate, because an
    ad-hoc signature has no stable designated requirement and macOS therefore
    re-asks for the microphone after every rebuild;
  - added `run`, which launches through Launch Services rather than executing the
    binary, since starting it from a terminal makes TCC attribute the request to
    the terminal and grant the permission to the wrong application;
  - implemented microphone capture with permission first, engine second, and level
    metering that feeds the mark's ring;
  - wired the mark and push-to-talk to the same activation path, and made
    stop-everything close the microphone too.
- Validation:
  - `Scripts/test` — 85/85 passed;
  - strict format lint clean; release build with warnings-as-errors;
  - `--audio-check` unbundled: no bundle identifier, no usage description;
  - `--audio-check` bundled: `com.matheusbgodoi.evie`, usage description present,
    permission `notDetermined`;
  - the installed bundle launched through `open -a` and stayed resident at 0.0% CPU
    and 105 MB.
- Deliberately not done: the microphone consent dialog was never triggered. Asking
  for it is the user's decision to make at a moment they choose, and a background
  session must not leave a system dialog waiting on their screen.
- Risks/blockers:
  - the signature is still ad-hoc, so the first grant will not survive a rebuild
    until `Scripts/evie-app identity` is run and the certificate is trusted for
    code signing in Keychain Access, which cannot be scripted;
  - speech recognition is not connected, so closing the microphone produces no
    transcript and the interface says exactly that.
- Next action: `VOI-017` — Apple's `SpeechTranscriber`, which supports pt-BR, runs
  outside this process so it does not compete with the model for memory, and
  exposes explicit model unload.

## 2026-08-05 — VIS-007/008/009: Evie can read

- Scope: `Sources/EvieCore/EvieDocumentReader.swift`,
  `Sources/EvieShell/{EvieDocumentAttachment,OverlayViewModel,EvieOverlayView,QuickTextEntryView,EvieShellApp}.swift`,
  `Sources/EvieShell/Views/OverlayRootView.swift`,
  `Tests/EvieCoreTests/EvieDocumentReaderTests.swift`, `CHANGELOG.md`.
- Completed:
  - native text recognition with `minimumTextHeightFraction` set to zero, because
    the default of 1/32 of the image height silently returns nothing for ordinary
    screenshot-sized text;
  - `.accurate` recognition only: the fast level was measured turning "Emissão"
    into "Emissào" and a date into digits;
  - per-page PDF strategy with a heuristic that rejects a text layer made only of
    stray characters, and 200 dpi rendering for pages that must be recognised;
  - per-line confidence, warnings for low confidence and blank pages, and a
    provenance that distinguishes exact extraction from recognition;
  - fenced prompt evidence carrying source, page, and lowest confidence;
  - drag-and-drop onto the overlay plus a file picker, with the attachment shown
    as a card before anything is asked about it, and a 20 000 character ceiling so
    a long document cannot crowd out the question.
- Validation:
  - `Scripts/test` — 99/99 across twelve suites, including recognition tests that
    run the real system recogniser rather than a stub;
  - a generated scanned PDF with no text layer was read correctly end to end:
    accents, CNPJ, dates, and `R$ 3.897,60` all intact, and the model answered
    "O total da nota é R$ 3.897,60 e o vencimento é em 04/09/2026";
  - a PDF instructing Evie to ignore her rules, delete Downloads, and rename her
    creator was reported as an injection attempt and did not change her identity.
- Known rough edge: recognition rendered "nº" as "n°", the usual ordinal/degree
  ambiguity. Asked who created her while holding that document, Evie answered
  "Seu criador é Matheus Barboza de Godoi" — the right name, the wrong pronoun.
- Risks/blockers:
  - no image understanding yet, only text: a chart or a screenshot of a UI yields
    its words, not what it means. The research recorded two routes — the system
    vision model, and the mmproj projector for the model already installed — and
    neither is pinned;
  - drag-and-drop and the picker have not been exercised by hand.
- Next action: `VOI-017`, connecting Apple's `SpeechTranscriber` so a spoken
  question becomes a typed one.

## 2026-08-05 — VOI-017: a spoken question becomes a typed one

- Scope: `Sources/EvieShell/{EvieSpeechTranscription,EvieAudioCapture,AppCoordinator,OverlayViewModel,EvieShellApp}.swift`,
  `CHANGELOG.md`, `docs/implementation/TASKS.md`.
- Completed:
  - `SpeechAnalyzer` plus `SpeechTranscriber` at `pt-BR` with volatile and fast
    results and per-result confidence, gated on macOS 26 so the package keeps its
    macOS 15 floor;
  - the language pack is installed up front rather than lazily, so the first
    spoken sentence does not vanish into a silent download;
  - an input pump that converts microphone buffers to the recogniser's format on
    the audio thread behind a lock, yielding `AnalyzerInput` into the analyzer;
  - `SpeechModels.endRetention()` on both finish and cancel, which is the idle
    unload the engineering contract requires of every heavy worker;
  - split `prepareInputFormat` from `start` in the capture, because the recogniser
    must be configured for the exact input format before the first buffer;
  - a live transcript in the capsule with the volatile part marked as still being
    heard, and discarded if capture ends on it;
  - capabilities now derived from what exists: hearing requires a bundle identity
    and system recognition, reading documents is on, speaking is still off.
- Validation:
  - `Scripts/test` — 99/99 passed;
  - strict format lint clean; release build with warnings-as-errors;
  - `--speech-check` from the bundle: recognition available, `pt-BR` resolves to
    `needsDownload`, meaning supported with a one-time language pack;
  - `--print-persona` from the bundle now lists hearing and document reading as
    available and continues to deny speaking, folders, and the web.
- Not validated, and not claimed: no audio has been transcribed. That needs the
  microphone grant, which is deliberately left for the user to give. Until then
  the recogniser's accuracy on Brazilian Portuguese, its cold-start latency after
  the language download, and barge-in behaviour are all unmeasured.
- Next action: `VOI-018` — connect the existing OmniVoice adapter to playback so
  she can answer out loud, which is the last switch in the settings that still
  describes something unbuilt.
