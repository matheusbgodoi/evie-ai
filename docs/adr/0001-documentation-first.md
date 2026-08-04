# ADR 0001: Documentation-first, gate-based delivery

- Status: Accepted
- Date: 2026-08-04

## Context

Multiple AI agents will work on Evie across independent sessions and quota windows.
The project also touches credentials, personal data, background processes, and
models with uncertain target-hardware performance.

## Decision

Begin with a documentation-only Phase 0. Require current status, roadmap, worklog,
changelog, ADRs, evaluation cases, and same-commit documentation. Advance phases
only through explicit measurable exit gates.

## Consequences

- A new agent can resume without hidden chat context.
- Implementation starts slower but avoids irreversible architecture drift.
- Documentation maintenance is part of every commit, not postponed cleanup.
