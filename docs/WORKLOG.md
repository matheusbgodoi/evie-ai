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

- Commit: this implementation commit on `agent/native-overlay-foundation`
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
