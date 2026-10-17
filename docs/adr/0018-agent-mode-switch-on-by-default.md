# ADR 0018: agent mode behind a Settings switch, on by default

Status: Accepted for Evie v2 (implemented in slice S5c, 2026-10-16)

Date: 2026-10-16

Amends: the v2 design's S5c heading, "Input executor behind a flag
(`EVIE_COMPUTER_USE=1` until QA passes)". [ADR 0016](0016-in-process-computer-use-executor-under-agent-mode-grant.md)
stands whole: this decides only whether agent mode is available at all, not
what a session may do.

## Context

The design put the S5c executor behind an environment flag that had to be set
to `1`, until the S5d manual QA passed. An environment flag is invisible to the
person using the app and reaches a bundle opened from the Finder only through
`launchctl setenv`; it is a developer's switch, not a setting. The owner asked
for agent mode to be available in the app without that step.

What makes acting on the Mac acceptable is not the availability switch but the
session rules of ADR 0016: a session only from push-to-talk or a click plus a
confirm (never the wake word), a grant of at most 15 minutes, every action a
0009 proposal checked by code policy, the confirmations, the executor
revalidating each commit, and the kill switches.

## Decision

- **A switch in Configurações › Avançado › Controle do Mac**, "Deixar a Evie
  controlar o Mac (modo agente)", stored as `computer_use_enabled` in
  `preferences.json` (`EviePreferences.computerUseEnabled`).
- **On by default**, because the owner asked for it; a preferences file written
  before the switch existed reads it as on.
- **Off means no executor:** `MacComputerActor.make` returns none, so no session
  can act; looking at the screen when asked is unaffected.
- **`EVIE_COMPUTER_USE=0`** (also `false`, `off`) forces it off for one launch,
  whatever the switch says — for test runs and demos on a screen someone else
  is using. Nothing in the environment turns it on: a switch the person turned
  off stays off (`ComputerUseSwitch`).
- The pane says what the switch does not do: it never starts a session.

## Alternatives considered

1. **The flag as designed (`EVIE_COMPUTER_USE=1`).** Hidden from the person and
   awkward for a bundled app; rejected at the owner's request.
2. **A switch, off by default** — the pattern of web search and Mail. Those
   switches send questions to strangers or read the most personal local data on
   every turn once on; this one enables nothing until a session is started by
   hand and confirmed. The owner chose on.
3. **Both a switch and an environment variable that can force it on.** Rejected:
   the environment must not override a person's "off".

## Consequences

- A fresh install can run agent sessions once S5d's card exists, with the
  Accessibility grant (asked at the session's start, never at launch).
- The security posture rests on ADR 0016's session rules, not on an opt-in; the
  Settings pane and `docs/SECURITY.md` say so.
- Tests: "the agent-mode switch starts on, and off survives a relaunch", "a file
  written before the agent-mode switch existed reads it as on",
  "EVIE_COMPUTER_USE=0 turns agent mode off whatever the switch says; nothing
  turns it on" (`EviePreferencesTests`).
