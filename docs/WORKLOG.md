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
