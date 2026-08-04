# Roadmap

The roadmap is gate-based. A phase is complete only when its exit criteria are
measured and documented; elapsed time alone is not completion.

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
