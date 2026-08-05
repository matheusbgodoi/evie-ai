# Handoff

Evie is designed to outlive any single model session, weekly quota, editor, or
coding agent. The repository, not a conversation, is the source of truth.

## Where things stand — 2026-08-05

Read this section first, then `docs/PROJECT_STATUS.md` for detail.

### Working, and verified

- Continuous conversation with the local model, streamed into glass cards, with
  local history and a deliberate history window.
- Evie's own identity. She knows Matheus Barboza de Godoi created her, addresses
  him as `você`/`seu` with masculine agreement, and can only claim capabilities
  that are actually built. `evie-shell --print-persona` shows exactly what she is
  told.
- No surface names the model or the inference server. The endpoint moved to port
  38433 and appears only under Settings › Diagnóstico.
- The overlay can be dragged anywhere, resized from either edge, and reset. The
  panel follows the height SwiftUI measured, which is what fixed the clipped fade.
- The mark: a key drawn in ASCII that tilts in 3D through Core Animation and lights
  up only during real activity. Idle CPU with the overlay visible measures 0.0%.
- A five-tab settings window. Every shortcut is recordable, disableable, and
  resettable; conflicts and system refusals are named in place.
- `Evie.app` with a stable bundle identifier, which is the prerequisite for every
  permission she will ever need.
- Reading images and PDFs, including scanned ones, in Portuguese, through the
  system recogniser. Verified end to end against the model, and against a document
  attempting prompt injection.

### Built but unproven

- The microphone and speech recognition. The code path is complete and the system
  reports Portuguese recognition available; **no audio has been transcribed**,
  because that needs a microphone grant, which is the user's to give at a moment
  they choose.

### Not built

Speaking out loud, wake word, call mode behaviour, reaching folders, web search,
semantic memory, and any action with an effect outside this Mac. The settings for
some of these exist and save; the interface says plainly that they are not active.

### Nothing has been accepted by eye

`QA-006` covers the entire visual layer: dragging, resizing, the reset control,
the corrected fade, whether the ASCII key is legible at 30 points, and the palette
in light and dark. It is deferred, not passed.

## The next three things

1. **`VOI-018` — let her speak.** The OmniVoice adapter exists, is defensively
   written, and is connected to nothing. Playback, sentence chunking, output
   metering, cancellation, and barge-in complete the loop, and it is the last
   switch in Settings that still describes something unbuilt.
2. **`SEC-002` and `INT-008` — let her read the Mac.** This is the user's own
   standing request. `docs/FILESYSTEM.md` has the full design; reading is worth
   shipping before any write capability exists.
3. **`QA-006` — the human pass.** Everything visual is unverified. One session
   with the running application converts a pile of "should work" into fact.

## Constraints that will bite

- **`@State` does not compile here.** This Mac has Command Line Tools without full
  Xcode, and `@State` is a macro whose plugin ships only with Xcode. Transient
  view state goes in an observable object. There is also no Metal toolchain, so
  custom shader effects are out. See `AGENTS.md`.
- **`orderOut` does not stop a SwiftUI timeline.** A hidden overlay was measured
  redrawing at 55 fps. The motion gate must be lowered before the window leaves.
- **Never run the executable directly once permissions matter.** TCC attributes
  the request to whatever launched it. Use `Scripts/evie-app run`.
- **Run `Scripts/test`, not `swift test`.** The wrapper supplies the Swift Testing
  macro plugin and rpaths that SwiftPM does not find under Command Line Tools.

## Start-of-session checklist

1. Read `AGENTS.md` and the documentation order it defines.
2. Run `git status -sb` and identify unfinished or uncommitted work.
3. Read the latest worklog entry and the current project status.
4. Read `docs/implementation/TASKS.md`; reconcile task status and ownership with
   the working tree before claiming anything.
5. Verify the current roadmap phase and its exit criteria.
6. Check ADR status before revisiting an accepted decision.
7. State the bounded task and the documentation updates it will require.

## End-of-session checklist

- checks are recorded with their exact commands and results;
- estimates are not presented as measurements;
- hardware, revisions, and settings accompany every benchmark;
- architecture and operation documents match the implementation;
- `CHANGELOG.md` is updated when behaviour changed;
- `docs/PROJECT_STATUS.md` reflects the phase and the next action;
- `docs/WORKLOG.md` has a dated entry;
- the credential and personal-data scan is clean;
- every uncommitted path has a named owner.

## Worklog template

```markdown
## YYYY-MM-DD — short task name

- Scope: <exact files>
- Completed:
  - ...
- Validation:
  - command — exact result
- Measured results: <or "none; not measured">
- Security/privacy notes: <scopes, logs, local state>
- Risks/blockers: <specific and reproducible>
- Next action: <one bounded task ID and its first command>
```

## Status vocabulary

- **Proposed:** a researched candidate, not accepted by measurement.
- **Accepted for planning:** an assumption used to plan, still behind a gate.
- **Validated:** reproduced on target hardware with recorded settings.
- **Implemented:** present in code, not necessarily proven.
- **Operational:** tested end to end, with recovery and security gates.
- **Superseded:** kept for history, replaced by a newer decision.

The distinction between **Implemented** and **Validated** is the one that matters
most here. Speech recognition is implemented. It is not validated, and no document
in this repository may say otherwise until someone has spoken to it.

## Benchmark handoff

Only sanitised results enter Git. Each one records target hardware and power mode,
operating system and dependency revisions, the exact command without secrets, warm
or cold state, the input case identifier, raw metrics with an interpretation, known
anomalies, and how to reproduce it. Private prompts and documents are referred to
by stable synthetic case identifiers, never by content.

## Blocking rule

Do not broaden permissions, commit credentials, activate a workflow, or accept a
lower-quality model merely to make progress. Record the blocker and propose a safe
next test.
