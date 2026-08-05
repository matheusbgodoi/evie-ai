# ADR 0007: pinned local development runtime outside Git

Status: Accepted for first-test development

Date: 2026-08-04

## Context

VS-001 needs a reproducible way to reach the preferred local Gemma model before
the Phase 2 supervisor exists. Copying a changing list of upstream commands into
each agent handoff would make revision, path, context, and process ownership easy
to drift. Embedding model download or process control in the native shell would
prematurely give the UI lifecycle responsibility and blur ADR 0006's temporary
direct-client boundary.

The runtime checkout, approximately 14.3 GB installed model, generated process
state, local settings, and logs are machine state. They must not enter Git. No
persistent service or credential is required for the text-only first test.

## Decision

Provide `Scripts/evie-runtime` as a development-only controller. It pins:

- TurboFieldfare revision
  `7a99f2a635e3adf7ed0720b882d2edb600f2f0da`;
- OpenAI-compatible model ID `gemma-4-26b-a4b-it`;
- loopback port `8080` and a declared context of 65,536 tokens;
- the upstream release repacker/server products and upstream install verifier.

The controller exposes explicit `doctor`, `setup`, `configure`, `verify`, `start`,
`stop`, `status`, `smoke`, and `launch` operations. Setup checks free space,
refuses an unexpected or dirty runtime checkout, and resumes upstream partial
installation state where supported. Start checks for a port/model-owner conflict,
writes a PID, waits for loopback health, and never installs a login item. Stop
validates the PID, command, and model path before sending `SIGTERM`; it does not
force-kill.

Keep development state outside the repository:

```text
~/Library/Application Support/Evie/Runtimes/turbo-fieldfare/
~/Library/Application Support/Evie/Models/gemma4.gturbo/
~/Library/Application Support/Evie/State/
~/Library/Application Support/Evie/config.json
~/Library/Logs/Evie/turbo-fieldfare-server.log
```

The native configuration loader applies built-in defaults, the schema-versioned
local JSON file (or another absolute path selected by `EVIE_CONFIG_FILE`), then
supported environment overrides. These settings are non-secret. Credentials
remain outside this configuration and belong to future Keychain/upstream protected
stores and capability brokers.

Use a synthetic non-streaming response and an SSE completion ending in `[DONE]` as
the first wiring smoke test. This is not a model-quality, long-context, resource,
or energy benchmark.

On the current base M5/24 GB target Mac running macOS 27, the pinned release
products built with Apple Command Line Tools alone. Record that as a local
observation; TurboFieldfare's upstream Xcode 26 requirement remains the supported
prerequisite for other environments.

## Alternatives considered

1. Keep a prose-only manual upstream runbook. This avoids code but allows agents to
   use different revisions, model IDs, paths, and server flags and provides no
   common safety checks.
2. Embed setup and process control in `evie-shell`. This makes the UI a premature
   lifecycle manager, complicates cancellation/recovery, and increases the
   migration cost to `evied`.
3. Install a LaunchAgent immediately. This makes an unbenchmarked heavy worker
   persistent before idle memory, energy, shutdown, recovery, and uninstall are
   designed.
4. Use Docker for the model server. This conflicts with the native Apple
   Silicon/Metal runtime, adds an unwanted always-on layer, and is not required by
   TurboFieldfare.

## Consequences

- Agents and the user share one pinned, inspectable command surface for the first
  local text test.
- Model assets, logs, process state, and real local settings remain outside Git;
  no credential is introduced.
- The model consumes storage and active resources only after explicit setup/start;
  there is no automatic unload or power-aware policy yet.
- A successful smoke test will establish basic local wiring but will not complete
  Phase 1 or `QA-001`.
- `Scripts/evie-runtime` is not a supported production service API. `SUP-005` may
  reuse its validated paths/flags, but the supervisor must own health events,
  cancellation, recovery, idle unload, and migration explicitly.
- The 2026-08-04 first-test handoff verified 37 files / 14,291,915,755 bytes and
  passed non-streaming plus SSE synthetic inference at a declared 64K. These
  results do not replace the Phase 1 matrix or manual UI acceptance.
