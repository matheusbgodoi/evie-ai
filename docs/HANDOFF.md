# Multi-agent handoff protocol

Evie is designed to outlive any single model session, weekly quota, IDE, or coding
agent. Repository state must be sufficient to resume work safely.

## Start-of-session checklist

1. Read `AGENTS.md` and the documentation order it defines.
2. Run `git status -sb` and identify unfinished/uncommitted work.
3. Read the latest worklog entry and current project status.
4. Verify the current roadmap phase and its exit criteria.
5. Check ADR status before revisiting an accepted decision.
6. State the bounded task and expected documentation updates.

## End-of-session checklist

Before committing or handing off:

- tests/checks are recorded;
- estimates are not presented as measurements;
- source revisions/settings accompany benchmark results;
- relevant architecture and operation docs match the implementation;
- `CHANGELOG.md` is updated when applicable;
- `docs/PROJECT_STATUS.md` reflects phase and next action;
- `docs/WORKLOG.md` contains a dated entry;
- secrets/personal data scan is clean;
- working-tree leftovers are explicitly described.

## Worklog template

```markdown
## YYYY-MM-DD — agent/tool — short task name

- Commit: `<sha or pending>`
- Phase: `<phase>`
- Completed:
  - ...
- Files/components:
  - ...
- Validation:
  - command/result
- Decisions/measurements:
  - ...
- Risks/blockers:
  - ...
- Next action:
  - exact bounded step
```

## Status vocabulary

- **Proposed:** researched/design candidate, not accepted by measurement.
- **Accepted for planning:** architecture assumption used to plan work but still
  subject to an explicit phase gate.
- **Validated:** reproduced on target hardware with recorded settings.
- **Implemented:** present in code, not necessarily production-ready.
- **Operational:** tested end-to-end with recovery and security gates.
- **Superseded:** retained for history but replaced by a newer ADR/design.

## Benchmark handoff

Store only sanitized results in Git. Each result includes:

- target hardware and power mode;
- OS/build/dependency/model revisions;
- exact command/config without secrets or private prompts;
- warm/cold state;
- input case identifier;
- raw metrics and a human interpretation;
- known anomalies;
- reproducibility instructions.

Private prompts or documents use stable synthetic case IDs rather than content.

## Blocking rule

Do not broaden permissions, commit credentials, activate a workflow, or select a
lower-quality model merely to make progress. Record the blocker and propose a safe
next test.
