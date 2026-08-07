# Roadmap

The roadmap is gate-based. A phase is complete only when its exit criteria are
measured and documented; elapsed time alone is not completion.

## Progress snapshot — 2026-08-07

Six things landed since the snapshot below, and three of them move a phase.

- **Phase 5 (read-only integrations)** is further along than "email, calendar and
  Drive do not exist" — but not by the route the phase describes. Mail and
  Calendar are read through the Apple applications that already hold the accounts,
  so there is no Google or Apple API scope, no token in the Keychain, and nothing
  to revoke. Three reading tools, off by default — plus two that propose and
  belong to Phase 7 below. The exit criteria about untrusted content and
  provenance are met; the ones about tokens and minimal scopes are not met so much
  as sidestepped, and Drive remains untouched.
- **Phase 7 (bounded write actions)** gains its second and third writes, and the
  snapshot below is out of date where it says "email and calendar writes do not
  exist" — neither half holds now. The calendar takes exactly one write, creating
  an event (`383a92c`, `b9bd7a0`); mail takes one, sending a message, with saving
  a draft beside it (`6dade94`). Both have the shape the phase asks for. The tools
  the model calls, `propose_event` and `propose_mail`, perform nothing; creating
  and sending are separate protocols the agent loop does not hold, so the approval
  is structural rather than a policy the loop could be talked out of. No
  auto-approve path exists for either, including when file auto-approval is on,
  and for mail there is none under any setting at all. Mail is the first write in
  this project that reaches somebody other than the owner, which is why its card
  shows every recipient in full and refuses an address the conversation never
  contained ([ADR 0010](adr/0010-refuse-unseen-mail-recipients.md),
  [ADR 0011](adr/0011-draft-beside-send.md)). Replying, attaching, deleting,
  filing and marking read remain unbuilt; inviting somebody to an event is not
  unbuilt but impossible from a script here, measured (`docs/AUTOMATIONS.md`).
- **Phase 6 (deterministic automation)** gains its trigger half. Schedules are
  `launchd` user agents — daily, chosen weekdays, or a watched folder — running
  Evie's own questions, with nothing resident between firings. The Shortcuts
  adapter the phase recommends is still unwritten, and `shortcuts` is still never
  invoked.
- She knows what day it is, and calculates instead of guessing — and since
  `915d3b0` the sum is found in the question and handed over as evidence rather
  than requested of her. Measured against the running model, twenty questions:
  ten easy sums were 10/10 unaided, and ten harder ones of the same shapes were
  7/10 unaided against 10/10 grounded. Neither belongs to a phase; both were
  classes of silent error.
- The vault index stopped being JSON (`293fb29`). Same file, both ways, through
  `--index-check`: 57.0 MB to 22.9 MB, 789 ms to 47 ms, 151.0 MB peak to
  49.8 MB, with a fingerprint over every vector and passage identical across the
  two formats. Not a phase gate; it is the cost of opening the index, which the
  retrieval phases assume is close to free.
- Idle and per-turn resource cost were measured with a stated method
  (`docs/RESOURCE_BUDGET.md`). That is not Phase 1's benchmark matrix, which is
  still open.

The blockers below are unchanged: `QA-006` and `REL-001`, in that order. Both
gained work rather than losing it — there are two more settings panes to accept by
eye, and now the event confirmation card as well, which no human has seen.

## Progress snapshot — 2026-08-06

The phases below were written as a sequence and have not been executed as one. The
work went where the user needed it, so Phase 3 and Phase 4 are substantially built
while Phase 1 is still open and Phase 2's supervisor does not exist. This snapshot
is the honest ordering; the phase definitions are kept because their exit criteria
are still the right gates.

**What is done, by phase:**

- **Phase 0** — complete. Architecture, threat model, resource hypotheses,
  evaluation gates, ADRs, and the handoff contract.
- **Phase 3 (voice)** — mostly done, ahead of Phase 1 and 2. Speech in, speech
  out, call mode, on-demand speech, cloned and designed voices, barge-in, and a
  wake phrase that is implemented and off. What is missing is the measurement:
  no Brazilian Portuguese WER, no false-accept/false-reject rates, no energy
  figure, and no end-to-end wake check.
- **Phase 4 (memory and RAG)** — mostly done, in a form the phase did not
  anticipate: no staged extraction pipeline, no reranker, no QMD. Title + BM25 +
  embeddings fused with RRF over a cached index, with provenance on every passage.
  Memory is propose-and-confirm and bounded.
- **Phase 5 (read-only integrations)** — partly done and out of order. Web search
  ships, off by default. Scoped file search ships. Email, calendar and Drive do
  not exist.
- **Phase 7 (bounded write actions)** — partly done, well ahead of its phase. The
  filesystem writer proposes and a person approves; deleting is the Trash. Email
  and calendar writes do not exist.
- **Phase 1** — open. The streaming client and a pinned development-runtime
  controller exist; TurboFieldfare's release products built, the 14.3 GB Gemma
  installation verified, and non-streaming plus SSE synthetic inference passed at
  a declared 64K. The 16K/32K/64K correctness/performance matrix remains open, and
  no smaller model has been compared.
- **Phase 2** — the shell is well past prototype and the supervisor is not
  started. `evied`, worker lifecycle, idle unload, crash recovery, power policy,
  and login-item registration are all unwritten. The application does now own one
  process — the voice engine, started when a trained voice is chosen.
- **Phase 6 (visual automation)** — Node-RED is dropped, not deferred. See
  `docs/AUTOMATIONS.md`; the replacement is macOS Shortcuts and no code exists.
- **Phase 8, Phase 9** — untouched.

**What actually blocks the next step**, in order:

1. `QA-006` — the human acceptance pass. Nothing visual has been formally
   accepted, and the interface changed substantially this session.
2. `REL-001` — the first release. The update mechanism exists and verifies a
   signature; what is missing is a `1.0.0` changelog section, an ADR for the
   retrieval decision, and a decision on what the release ships.
3. The two open Shortcuts questions, each estimated at half an hour, before any
   automation code is written.
4. Phase 1's benchmark matrix, which nothing currently depends on but which the
   model-selection decision cannot be made without.

`QA-001` remains deferred at the user's request. No phase exit gate is inferred
from a successful compile.

The development controller is a readiness aid, not a Phase 2 supervisor. Its
explicit `start`/`stop` workflow does not satisfy idle unload, recovery, power,
packaging, or background-service gates.

## Phase 0 — feasibility and architecture

Scope:

- document product boundaries and threat model;
- research upstream capabilities and limitations;
- design model lifecycle, interface, voice, vision, RAG, and automation layers;
- define resource budgets and an Evie-specific evaluation suite;
- establish repository continuity for multiple coding agents.

Exit criteria:

- architecture and ADRs reviewed;
- no unresolved contradiction about minimum context or model API support;
- benchmark plan defines exact metrics and pass/fail thresholds;
- repository contains no secret or personal data;
- next agent can begin Phase 1 using repository documentation only.

## Phase 1 — local inference benchmark

Scope:

- build a benchmark harness without installing integrations;
- test TurboFieldfare Gemma at 16K/32K/64K;
- test representative smaller models at 64K;
- exercise Portuguese instruction following, RAG prompts, and tool-call schemas;
- measure cold start, warm latency, prompt processing, decode, peak memory, idle
  memory, idle CPU, and energy impact on battery and AC.

Exit criteria:

- a primary model and one fallback are selected using Evie tasks;
- 64K works with Hermes or a documented alternative is accepted;
- baseline interactive latency is acceptable;
- the selected configuration stays below the defined memory-pressure ceiling;
- all measurements are reproducible from a pinned manifest.

## Phase 2 — supervisor and native interaction shell

Current implementation note: VS-002 supplies the continuous native quick-text
shell, deliberate history/settings windows, and a temporary direct inference
adapter. It does not satisfy this phase's supervisor, worker lifecycle,
dormant-resource, recovery, packaging, voice, tool, or acceptance gates.

Scope:

- implement the local supervisor and model lifecycle manager;
- implement a menu-bar utility and transient overlay;
- add a configurable global text shortcut and push-to-talk;
- expose state: listening, transcribing, thinking, tool use, speaking, approval,
  error, and sleeping;
- add idle timers, cancellation, health checks, logs, and pressure-aware unload.

Exit criteria:

- Evie can be summoned without opening a chat application;
- the overlay never steals focus unexpectedly;
- all workers can be terminated and restarted cleanly;
- dormant resource use meets the budget;
- permissions and failure states are visible.

## Phase 3 — local voice loop

Scope:

- benchmark and integrate local STT;
- add wake word only after push-to-talk is stable;
- integrate OmniVoice as an on-demand command provider first;
- add streaming/sentence-level plugin only if it materially reduces latency;
- implement barge-in, mute, cancellation, and AC/battery warm policies.

Exit criteria:

- Brazilian Portuguese transcription accuracy is acceptable in target rooms;
- the wake phrase has measured false-accept and false-reject rates;
- first spoken feedback meets the latency target warm and has an honest cold path;
- the user can always see and stop microphone/TTS activity.

## Phase 4 — local memory and RAG

Scope:

- add document extraction into an immutable-source/staged-text pipeline;
- implement BM25 plus embeddings, with optional reranking;
- support provenance and open-source links for every retrieved answer;
- index only explicitly allowed collections;
- schedule indexing only while idle/on AC when appropriate.

Exit criteria:

- retrieval recall and citation correctness pass the evaluation set;
- prompt-injection content cannot grant new permissions;
- reindexing is deterministic and source files are never silently modified;
- the index can be deleted and recreated without data loss.

## Phase 5 — read-only personal integrations

Scope:

- Google or Apple email/calendar/Drive access with minimal read scopes;
- scoped file search in dedicated directories;
- web search through DDGS and extraction through a local browser;
- morning briefing and meeting preparation as initial workflows.

Exit criteria:

- all external content is marked untrusted;
- read-only operations have audit logs and clear provenance;
- tokens are in Keychain/local protected state, never Git;
- failures cannot mutate remote or local data.

## Phase 6 — visual deterministic automation

**Superseded.** Node-RED does not survive the constraint the user set — nothing
resident, nothing in Docker, processing spent only when the tool is used. The
recommendation is macOS Shortcuts, and what she can and cannot do with it is
measured in `docs/AUTOMATIONS.md`, including the part that decides the shape of
any future code: a shortcut that wants to ask the user never exits.

Two thirds of "nothing event-driven is reachable under the constraint" survives.
Webhooks, MQTT, inbound mail and phone-pushed location all need something
listening, and nothing that listens is non-resident. A folder changing does not:
`launchd` is already listening on this Mac and `WatchPaths` borrows it, which is
how schedules got their second trigger without a daemon of Evie's.

The scope and exit criteria below are kept because the *shape* — generate
disabled, show before activating, never activate silently — is still right, and
because macOS enforces the approval click itself, where a bug in Evie cannot
bypass it.

Scope:

- run Node-RED locally as a separately permissioned service;
- implement a narrow adapter for listing, validating, drafting, importing,
  enabling, disabling, and triggering approved flows;
- support schedules, webhooks, messages, email, file, calendar, and trusted
  location events;
- generate flows disabled by default and display them before activation.

Exit criteria:

- Evie cannot silently activate a generated workflow;
- credentials are not present in exported flow JSON;
- every flow has owner, purpose, trigger, actions, rollback, and last-reviewed
  metadata;
- workflow history is versioned and auditable.

## Phase 7 — bounded write actions

Scope:

- email drafts and explicitly confirmed sends;
- proposed calendar events and confirmed creation;
- file move manifests limited to staging roots;
- approved workflow changes;
- reversible actions and undo where available.

Exit criteria:

- read/propose/commit boundaries are enforced in code, not only prompts;
- every commit action displays the exact target and effect;
- destructive or irreversible actions are denied by default;
- prompt-injection tests cannot cross the boundary.

## Phase 8 — WhatsApp and remote presence

Scope:

- dedicated-number Baileys bridge for personal use;
- strict sender allowlist and silent behavior for unknown users;
- inbound voice transcription and optional TTS replies;
- explicit limits on outbound initiation and automation.

Exit criteria:

- no personal primary number is placed at risk;
- session credentials are protected and revocation is documented;
- protocol failure does not block the local Evie interface;
- all outbound behavior is auditable and bounded.

## Phase 9 — reliability and product polish

Scope:

- upgrade/migration tooling, backups, health dashboard, log rotation;
- automated evaluation before dependency/model upgrades;
- crash recovery, accessibility, localization, and battery policy tuning;
- optional full-history view and workflow management UI.

Exit criteria:

- routine upgrades have rollback instructions;
- the system can run for weeks without manual babysitting;
- maintenance cost is lower than the time saved by target workflows.
