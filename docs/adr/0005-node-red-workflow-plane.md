# ADR 0005: Node-RED as visual deterministic workflow plane

- Status: Accepted for planning; Phase 6 validation required
- Date: 2026-08-04

## Context

Hermes provides cron and tools but not a general visual event-flow canvas. Building
a safe visual workflow engine from scratch would add substantial scope.

## Decision

Use native local Node-RED for schedules, webhooks, events, retries, and visual flow
inspection. Expose only a narrow broker to Evie. AI-generated flows are imported
disabled, reviewed visually, and explicitly enabled.

## Consequences

- Gains a mature visual runtime without Docker.
- Adds a Node.js service and third-party-node supply-chain surface.
- Requires strict credential separation, node allowlists, revisions, and approval.
