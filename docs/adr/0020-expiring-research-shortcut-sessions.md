# ADR 0020: Expiring research sessions with two configurable shortcuts

Status: Accepted, 2026-10-16

Amends [ADR 0016](0016-in-process-computer-use-executor-under-agent-mode-grant.md)
narrowly: a local research shortcut can begin a new agent grant while an
explicitly armed research session is active. It cannot approve a sensitive step.

## Context

The owner requested a research workflow that interprets the visible task on
demand, copies an answer, and optionally fills a field or selects an option.
Repeating the objective in chat for every trial adds an interaction unrelated to
the experiment. A persistent, invisible grant would also authorize actions long
after the research session and contradict the existing screen-presence contract.

## Decision

- Two actions are appended to `EvieShortcutAction`, preserving prior Carbon IDs:
  `toggleResearchMode` (⌃⌥⇧P) and `runResearchTask` (⌃⌥⇧K). The existing recorder,
  persistence, disabling and conflict detection apply unchanged.
- The toggle opens a separate consent window. A real hand click on **Ativar por
  15 minutos** arms an in-memory objective and destination. It closes the chat,
  stops speech, restores focus and disarms the wake listener. Activation itself
  never captures or executes. No background service, polling capture, new
  account scope, or stored authorization is added.
- `EvieResearchSession` issues one run lease at a time. Stop, expiry, sleep and
  user-session deactivation revoke it. Every asynchronous boundary preceding
  delivery checks cancellation and the lease. A late result cannot copy after
  stop, or regain authority after rearming.
- Clipboard mode captures once at the trigger, then resolves the brain. Its
  stateless vision turn has no tools, retrieval or conversation history. Only a
  completed, nonempty, bounded response is delivered; truncation and failed
  streams are errors. A clipboard revision change during inference refuses
  delivery. Screens and answers are not persisted.
- Control mode resolves a vision/tool-capable PC brain, then uses the existing
  `ComputerUseHost`, observer, broker, policy, executor, confirmations, takeover
  monitor and action budget. A fresh observation starts the agent loop. Its
  grant's deadline is capped by the research session's deadline as well as the
  broker's normal 15-minute maximum. `researchShortcut` is a start gesture, never
  an approval gesture. The objective asks for clipboard output plus filling or
  selecting, with no final submission; this last instruction is model guidance,
  not an additional code-level guarantee about arbitrary third-party controls.
- Chat and capture submissions cannot race a running research task. Arming and
  starting research refuse a busy chat/voice/capture or pending agent start.
- Screen indicators remain mandatory. The chat is hidden between requests;
  confirmation and failure UI appears when needed. No screen-sharing exclusion,
  anti-proctoring behavior, system-indicator suppression or guarantee of
  undetectability is provided.
- Logs remain in memory. The user can explicitly export up to 100 measurement
  rows (run UUID, timestamp, monotonic duration, destination, profile ID, result,
  action count). No objective, screenshot, model answer or AX text is exported.

## Alternatives

1. Capture on a timer: rejected; unrelated private material would be captured.
2. Reuse chat/history: rejected; research evidence should not silently become a
   saved conversation or carry unrelated personal context.
3. Remove broker confirmations or presence: rejected; shortcut convenience does
   not establish authority for sending, deletion or operating denied apps.
4. Start immediately from the toggle: rejected; a hand must review the objective,
   destination, expiry and capture disclosure each time the session is armed.

## Consequences

The workflow has a visible consent step followed by per-task shortcuts. Browser
radio buttons may need confirmation; autonomous filling and selecting are not
guaranteed on every app. A selected brain or missing macOS permission can fail a
run. UI and model evaluation remain separate from deterministic policy tests.
See [research methods and verification](../RESEARCH_MODE.md).
