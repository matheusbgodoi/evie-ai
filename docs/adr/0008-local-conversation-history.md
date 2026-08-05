# ADR 0008: local visible conversation history before Hermes

Status: Accepted for the native-shell prototype

Date: 2026-08-04

## Context

VS-001 kept all conversation state in process memory. That was an appropriate
privacy-minimal starting point, but it made a normal follow-up awkward and lost
every session when the shell exited. The user explicitly wants continuous
conversation, named prior sessions, and a deliberate place to inspect or resume
them while preserving Evie's transient, non-chat default surface.

Hermes remains the target agent/session runtime, but adopting it before the
supervisor and policy broker would either delay basic history or tempt the native
UI to expose Hermes' unrestricted tools. Conversation persistence is useful and
does not require action authority, semantic memory, RAG, credentials, or a model
worker.

## Decision

Persist only user-visible conversation messages in a small native store now:

- one schema-versioned JSON record per conversation under
  `~/Library/Application Support/Evie/Conversations/`;
- directory mode `0700` and record mode `0600` after every create/read/write;
- stable conversation/message identifiers and creation/update timestamps;
- atomic replacement and deterministic errors for malformed, unsupported, or
  identifier-mismatched records;
- independent index scanning that retains readable sessions and reports only an
  opaque count when another record is malformed or unavailable;
- `system` and `developer` messages removed before writing and rejected if found
  in a stored record;
- complete visible transcripts retained on disk while only a bounded recent
  prefix is sent to the model;
- deletion available only from a deliberate history window and only after an
  explicit confirmation.

The bottom overlay remains the default interaction. It preserves answer cards and
returns a focused input after completion. A separate native history window lists,
opens, continues, creates, and explicitly deletes sessions. It does not become a
permanent main chat window.

Model sampling preferences continue to use the existing non-secret, versioned
`config.json`. The settings window writes that same schema with user-only
permissions and applies the resulting client configuration to the next request.
Environment overrides retain their documented higher precedence on a later
launch.

This store is conversation history, not personal semantic memory. It grants no
tool, filesystem, network, account, or commit authority. The direct
TurboFieldfare adapter remains tool-free under ADR 0006.

## Alternatives considered

1. Keep process-memory-only sessions until Hermes. This preserves the smallest
   state surface but leaves a basic product interaction broken and prevents
   resuming work after a restart.
2. Install Hermes immediately and use its session database. That would conflate
   a safe history improvement with the still-unvalidated agent/tool boundary and
   make the UI dependent on a backend before `AGT-002`.
3. Use one SQLite database immediately. SQLite will likely be appropriate for
   search/index metadata later, but isolated JSON records are sufficient for the
   current volume, easier to inspect/migrate, and contain corruption to a bounded
   file.
4. Persist the full prompt sent to the model. This would duplicate hidden policy
   text, blur user history with runtime instructions, and increase disclosure risk.

## Consequences

- Multi-turn use and restart-resumable sessions no longer wait on Hermes.
- Personal conversation text now exists on disk. It remains outside Git and must
  not be copied into diagnostics, worklogs, fixtures, RAG indexes, or model logs.
- The current actor serializes access only inside one process. The future
  supervisor must become the single writer before multiple processes use the
  store.
- Hermes adoption requires an explicit migration/ownership decision: import these
  records, adapt Hermes sessions, or retain this store as the user-facing source
  of truth. Silent duplication is not acceptable.
- Search, retention controls, export, encryption-at-rest beyond macOS account/File
  Vault protection, and semantic memory remain future work.
- A malformed record cannot hide readable sessions, but the prototype only warns
  about its opaque count; quarantine, inspection, and repair/removal UX remain
  future recovery work. Direct `load(id:)` stays fail-closed.
