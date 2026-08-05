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

## 2026-08-05 — INT-008: reading, contained by the kernel

- Scope: `Sources/EvieCore/EvieScopedFileReader.swift`,
  `Tests/EvieCoreTests/EvieScopedFileReaderTests.swift`, `docs/FILESYSTEM.md`,
  `CHANGELOG.md`.
- Completed:
  - listing and reading inside a granted root, contained with `O_RESOLVE_BENEATH`
    and `O_NOFOLLOW_ANY`, walked one component at a time;
  - `fstat` on the descriptor rather than `stat` on the path, so a file swapped
    between check and open cannot be substituted;
  - a denylist applied to every component, with denied entries withheld from
    listings and counted rather than named;
  - 512 KiB read ceiling with truncation reported, 128-entry pages, and binary
    detection by NUL byte.
- Validation:
  - `Scripts/test` — 116/116 across thirteen suites;
  - the containment is proven by test rather than asserted: a symlink to
    `/etc/hosts` fails, a symlinked directory partway along the path fails, and
    both `../../etc/hosts` and `/etc/hosts` fail;
  - a standalone probe confirmed the same three refusals directly against the
    kernel before the reader was written.
- Note: `ENOTCAPABLE` (107) is not exposed as a Swift constant and is spelled out
  with a comment.
- Risks/blockers:
  - nothing grants a root yet, so the reader has no way to be reached from the
    interface; `SEC-002` is next;
  - iCloud Drive placeholders are not handled — reading a dataless file starts a
    download and can hang. It must check the downloading status before opening;
  - writing and deleting do not exist, and deliberately will not until the
    approval card does.
- Next action: `SEC-002` — the root registry, so a folder can actually be granted.

## 2026-08-05 — design correction after first look

- Trigger: the user reported the design was better before — logo, glassmorphism,
  "almost everything". Two of those turned out to be defects rather than taste.
- Scope: `Sources/EvieShell/Views/{EvieMarkView,OverlayRootView,StatusPill}.swift`.
- Defects found and fixed:
  - **The glass was clipped.** `.frame(width: contentWidth)` followed by
    `.padding(18)` produced content 36 points wider than the window, so the card's
    corners, border, and side shadow were cut. The frame is now the window width
    minus the padding. This was the glassmorphism regression.
  - **The mark was not a key.** Rendering it at real size proved it: at 30, 44,
    and 64 points it came out as a scattering of `+ : - =`. The cause was applying
    a density ramp — an image-to-ASCII technique — to art that was already ASCII,
    which replaced every character of the drawing. Light now drives brightness
    only, and a second render confirmed the key reads at 30 points.
- Reverted by choice, per the user:
  - the handle bar no longer takes layout space or shows at rest; it lives in the
    margin as an overlay and appears on hover;
  - system colours restored, including `.purple` for thinking and the flat
    diagonal badge fill rather than a radial gradient;
  - one exception, stated rather than slipped in: `.mint` in light appearance
    measures 1.82:1 against the HUD, so listening keeps a darkened teal there.
    Dark appearance is byte-identical to before.
  - the mark art is the compact three-column key the user chose.
- Validation:
  - `Scripts/test` — 116/116;
  - strict format lint clean; release build with warnings-as-errors;
  - screen captured from the running application: the glass renders with its
    corners, border, and shadow intact, and at 7× the mark is legibly a key;
  - idle CPU with the mark animating: 0.0%.
- Method note: rendering the artwork to a PNG and looking at it found in one step
  what no amount of reading the code would have. Any future change to the mark
  should be rendered before it is committed.

## 2026-08-05 — the crash, and the cost of a breathing circle

- Trigger: Evie crashed on tapping the mark, still crashed after the microphone was
  granted, showed no animation, cut its shadow off, and drew pale bars on hover.
- **The crash**, from the report rather than from guessing:
  `dispatch_assert_queue_fail` → `swift_task_isCurrentExecutor` →
  `closure #1 in EvieAudioCapture.start` on queue `RealtimeMessenger.mServiceQueue`.
  A closure literal written inside a `@MainActor` method is main-actor isolated
  whatever its type says. The audio tap calls it on a real-time thread, Swift
  checks the executor, and traps. Fixed by moving the tap installation into a
  `nonisolated static` method. The first attempt — replacing the closure parameter
  with a `Sendable` protocol — did not fix it, and the second crash report said so
  in the same frame.
- `--voice-check` was added so the audio path can be exercised without a mouse:
  it opened the microphone, ran the tap for two seconds, reported a peak level of
  0.439, closed, and produced no crash report.
- **The animation cost**, measured on the release build with the overlay visible:
  | version | CPU |
  |---|---|
  | no animation at all | 0.0% |
  | SwiftUI: timeline + scale + animated shadow radius + `symbolEffect` | 22.2% |
  | without the animated shadow radius | 19.2% |
  | without `symbolEffect` | 10.0% |
  | with `drawingGroup` rasterising the badge | 8.2% |
  | Core Animation `CABasicAnimation` on `transform.scale` | **2.7%** |
  SwiftUI re-renders the gradient, the rim, and the symbol on every frame of an
  implicit animation. `EvieBadgeLayerView` draws the badge in `CALayer`s so the
  render server interpolates the transform with no work in this process.
- Also reverted per the user: the sparkle mark is back, the shadow has room to
  fade (margin 30, shadow radius 16 plus offset 7), and the side handles draw
  nothing.
- Validation: `Scripts/test` 116/116; strict lint; release build; the crash path
  exercised end to end; the badge confirmed animating by diffing two screen
  captures.
- Honest limit: 2.7% is not zero. A continuous animation on a transparent floating
  panel forces the window to recomposite, and that cost is not removable while it
  is on screen. It stops entirely when the overlay is hidden, and Reduce Motion or
  the appearance preference turn it off.
- Method note: screen captures taken during this work were deleted; they contained
  the user's own screen.

## 2026-08-05 — readable answers, live buttons, and a stop

- Trigger: the scroll fade made answers unreadable, the model's markdown and LaTeX
  were showing as punctuation, buttons were inert, there was no way to stop a
  running answer, and the menu did not show its shortcuts.
- `EvieRichText` in `EvieCore` parses an answer into headings, paragraphs,
  bullets, numbered items, code, and rules; converts LaTeX to characters; and
  produces marker-free plain text for the clipboard. A lone `$` is left alone
  because in Brazilian text it is nearly always currency.
  - A regression suite runs the exact answer from the user's screenshot and
    asserts that none of `###`, `**`, `$`, `\rightarrow`, or `---` survives, and
    that `Isolar → Descrever → Analisar.` comes out right.
- `EvieRichTextView` renders those blocks; `EvieGlowButton` is an AppKit button
  whose hover glow is a layer shadow, chosen after the earlier measurement that
  SwiftUI re-renders a button on every frame of a transition.
- The entry field now stays visible while an answer streams, and its send button
  becomes a stop button. Hiding the field mid-answer moved the cancel control away
  at the exact moment it is wanted.
- The menu is rebuilt from the preferences, so every item shows its current
  shortcut, and every configurable action has an item.
- Validation: `Scripts/test` 135/135 across fifteen suites; strict lint; release
  build with warnings-as-errors.
- Next: tool calling. Every remaining request — reading folders, the web, email,
  automations — depends on the model being able to call a function, and today the
  inference client neither sends nor executes tools.

## 2026-08-05 — a Spotlight-style presentation

- `OverlayPanelController` now animates the content layer's opacity and scale
  rather than ordering the window in and out bare: 0.93 → 1 over 0.17 s easing
  out on arrival, 1 → 0.97 over 0.11 s easing in on dismissal.
- The risky path is a hide interrupted by a show. `cancelDismissal` abandons the
  in-flight transition and resets the layer, so the window cannot be left half
  faded or ordered out under a fresh presentation.
- `--presentation-check` drives show, hide, an interrupting show, hide, and show
  again, reporting the window and layer state after each. All four end states were
  correct: visible with opacity and scale at 1 after every show, and reset to 1
  after the hide so the next arrival starts clean.
- Reduce Motion skips the movement entirely rather than skipping the window.

## 2026-08-05 — VOI-018: Evie speaks

- Scope: `Sources/EvieShell/{EvieSpeechOutput,EvieLevelMeter,AppCoordinator,OverlayViewModel,EvieShellApp}.swift`,
  `Sources/EvieShell/Views/VoiceSettingsView.swift`,
  `Sources/EvieCore/{EvieRichText,EviePreferences}.swift`, `docs/VOICE.md`.
- Completed: sentence-chunked synthesis played through an audio engine with a
  mixer tap for real output levels; voice, rate, and a sample button in Settings;
  barge-in on opening the microphone; speech reads resolved text so no markup is
  pronounced; the level meter was extracted so capture and playback share it.
- Validation: `Scripts/test` 135/135; `--speak-check` from the bundle reported
  first audio at 0.42 s, 6.77 s of speech, peak level 0.656, 149 level samples.
- Two bugs found by that check rather than by reading: an engine connected before
  the buffer format was known never played and hung the wait; and `isSpeaking`
  read immediately after `speak()` is always false, which would have left the
  speaking indicator permanently off.
- Finding: the natural Siri voices cannot be instantiated by a third-party app,
  though they appear in the system list. Filtered out of the picker. Recorded in
  `docs/VOICE.md` as the argument for cloned voices.
- Next: `AGT-003` — tool calling, which the local server was confirmed to support.

## 2026-08-05 — VOI-019: call mode

- Trigger: the user turned call mode on, pressed the mark, and nothing happened.
- Two causes, both real:
  - `allowsHitTesting(false)` was still on the badge from the version where the
    SwiftUI stack owned the tap. Once the badge handled its own mouse events, that
    modifier swallowed every one of them. Pressing the mark had been dead since.
  - Call mode saved a preference and selected no behaviour. It now switches the
    overlay to the mark alone, opens the line on entry, and reopens the microphone
    when she stops speaking.
- End-of-speech detection was the missing piece: without it a call opens the
  microphone and never closes it. Implemented in `EvieAudioCapture` beside the
  levels it already computes — a turn ends after 1.1 s below the silence level,
  and only after speech has been heard, so opening in a quiet room submits
  nothing. Enabled for calls only.
- Validation: `Scripts/test` 135/135; strict lint; release build; installed.
- Not validated: the silence thresholds were chosen from the measured room floor
  (ambient near 0.05, speech peaking above 0.4) and have not been tried in a noisy
  room or against a quiet speaker. They are the first thing to adjust if a turn
  ends too early or hangs open.

## 2026-08-05 — SEC-002 and AGT-003: she can read the Mac

- Trigger: the user asked to move on to tool calling, being agentic, and touching
  the Mac. Reading is the whole of this entry; nothing writes.
- `SEC-002` — the root registry. `EvieRootRegistry` stores grants beside
  `preferences.json` at `0600`, versioned and atomic, and a damaged or
  future-schema file grants **nothing** rather than everything. Overlapping
  grants are collapsed: granting a parent removes the children it contains, and
  granting a child of a granted folder is refused, so revoking can never leave a
  second door open to the same file. `EvieRootsViewModel` and Settings > Pastas
  are the only way in, and the only source is `NSOpenPanel`.
- `AGT-003` — five read-only tools (`list_roots`, `list_folder`, `read_file`,
  `search_files`, `file_info`) over the existing contained reader, and a loop
  bounded at four steps and four calls per step. The last step withdraws the
  tools so the model has to produce words instead of asking again.
- The model is never given a filesystem path. Roots are opaque eight-character
  identifiers; every tool speaks relative to one. Asserted per tool in
  `EvieFileToolboxTests`, and the overlay's progress lines obey the same rule.
- Wire format verified against the running server rather than assumed. It is
  ordinary OpenAI: `finish_reason: tool_calls`, `content: null`, arguments as a
  JSON string. The earlier research caution that streaming tool calls were
  undocumented and should be avoided proved unnecessary — streaming works and
  delivers a complete call in one delta. Calls are still reassembled by `index`,
  because arriving whole is this server's choice and not the protocol's.
- Validation: `Scripts/test` 189/189 in 19 suites; release build; installed;
  and `evie-shell --tools-check`, which runs four real questions against the
  live model over a throwaway folder. All four answered correctly, including a
  three-tool chain, and the `.env` planted in the granted folder stayed
  withheld — she reported not finding it rather than inventing a password.
- **Measured, and the largest risk to this being usable:** the inference server
  degrades severely with uptime. Ten hours in, a trivial eight-token request took
  1657 s (27 minutes), per-request cost no longer varied with prompt size, and
  prefix caching had stopped hitting. A restart restored 5.8 s. Full numbers in
  `docs/FILESYSTEM.md`. Workaround is `Scripts/evie-runtime stop && start`;
  the defect itself is unfixed and belongs to the server.
- Earlier timings in this session were contaminated by leftover probe processes
  queuing on the same single-worker server — the same mistake the voice timings
  made in July. The `queued` → `generating` gap in the server log is the tell.
- Known flake, pre-existing and untouched: "task cancellation terminates the
  isolated child process group" in `OmniVoiceBatchTTSAdapterTests` failed once
  with `.childIdentifierMissing` under full-suite load and passed 4/4 after. It
  is a race between cancelling and the child registering its process group.
- Next: the approval card (`UI-011`/`POL-002`) before anything writes, and the
  bypass switch the user asked for — whose exact scope is still an open question
  put to them, because "liberado" can mean several different things.

## 2026-08-05 — the bypass, first half

- The user was asked what "bypass" should cover now that the design exists, since
  reading already asks for nothing after a folder is granted. He chose both:
  skip the folder-picking step, and skip confirmation for writing once writing
  exists.
- Built the first half. One switch in Settings › Pastas authorises the whole home
  folder, replacing the individual grants because the home folder contains them.
- Deliberately did **not** build the second half. Nothing writes yet, and a
  settings switch describing something unbuilt is the exact mistake this project
  already made with voice. It ships with the write tools, and with the rule the
  user's answer implies: deleting always goes to the Trash, never a permanent
  removal, so "no confirmation" never becomes "no undo".
- The switch cannot bypass macOS, only Evie. Desktop, Documents, Downloads, and
  iCloud Drive stay behind TCC and the system will ask once for each on first
  access; choosing a folder in the open panel carries that consent with it and a
  programmatic grant does not. Said plainly in the interface rather than
  discovered later.
- Consequence handled before shipping: `~/Library` is now denied wherever it
  appears. Authorising a home folder would otherwise have handed over Mail's
  store, Messages' chat database, Safari history, cookies, and every OAuth token
  in Application Support. Verified by test with a planted `.emlx`.
- Bug found while reviewing the registry for this: containment was decided by
  plain string prefix, so authorising `projeto` would have silently revoked
  `projeto2`. Now compared with the separator attached, with a test for the
  sibling case in both directions.
- Validation: `Scripts/test` 192/192 in 19 suites; release build.
- Not validated by eye: the Pastas tab, the switch, and the progress lines during
  a lookup. The home switch was left off — turning it on is the user's decision
  to make, not one to make for him.
