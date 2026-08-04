# ADR 0006: backend-neutral core with a direct TurboFieldfare prototype adapter

Status: Accepted for VS-001

Date: 2026-08-04

## Context

The intended product architecture places Hermes and a lifecycle/policy supervisor
between the native shell and model workers. Implementing that entire control plane
before validating the interaction surface would make the first executable large,
harder to diagnose, and dependent on several still-unmeasured components.

The first code slice still needs an honest end-to-end path to the preferred Gemma
model. Directly coupling SwiftUI views to TurboFieldfare would make that temporary
path difficult to replace and could accidentally turn the UI into a second agent
runtime.

## Decision

Define backend-neutral, `Sendable` messages, interaction phases, artifacts, usage,
failures, and an `AgentClient` streaming protocol in `EvieCore`. Implement a
loopback-only `TurboFieldfareClient` adapter for OpenAI-compatible streaming Chat
Completions. Compose that concrete adapter only at the native application's root.

For VS-001 the direct adapter:

- sends system/user/assistant text messages and consumes text deltas plus usage;
- is cancellable and emits no prompt/result logs;
- rejects non-loopback endpoints;
- does not send tool declarations, execute tools, authorize actions, persist
  memory, or control the model process;
- assumes the separately started server was configured for the declared 64K
  context and reports availability errors honestly.

The direct path is a development seam, not the final production trust boundary.

## Alternatives considered

1. Wait for the complete supervisor and Hermes integration before creating a UI.
   This preserves the final layering but delays feedback on the defining product
   interaction and combines too many failure domains in the first executable.
2. Call TurboFieldfare directly from SwiftUI views. This is quick initially but
   leaks wire-protocol and backend state into the interface, increasing migration
   cost and encouraging tool authorization in the wrong process.
3. Reimplement a general agent/tool loop in Swift. This duplicates Hermes,
   broadens security scope, and contradicts the replaceable-adapter architecture.

## Consequences

- The overlay and reducer can later consume Hermes/supervisor events without a
  visual rewrite.
- TurboFieldfare integration can be validated before granting any tool authority.
- The current executable is useful only while a user-managed local server runs.
- Context enforcement, lifecycle, retries, IPC, permissions, tools, durable
  memory, and audit remain intentionally incomplete.
- When the supervisor exists, it replaces the composition-root direct client; the
  `AgentClient` contract may evolve into versioned IPC without preserving this
  temporary wiring.
