# Hermes agent-plane integration

Status: researched and pinned candidate; not installed or enabled.

Last reviewed: 2026-08-04

## Role

Hermes is the preferred session and agent-loop candidate, not Evie's security
boundary. It already exposes persistent sessions, messages, forks, streamed text,
and streamed tool lifecycle events through a local API. Those capabilities fit
Evie's future conversation tabs and multi-step work better than implementing a
second general-purpose agent loop.

The candidate pin is Hermes Agent `v2026.8.3`, dereferenced commit
`3c27eb6234bf91b8ceee9e9071591b31e9b148cb` (package 0.20.0). Revalidate the tag,
license, dependencies, and configuration schema immediately before installation.

## Required topology

```text
native UI
  -> evied supervisor/policy broker
      -> Hermes API on 127.0.0.1:8642
          -> TurboFieldfare on 127.0.0.1:8080/v1
          -> only Evie-filtered MCP read/propose tools
```

Hermes must never be exposed directly to the UI as an authority source. The API
binds only to loopback, CORS remains disabled, and a bearer key comes from Keychain
through the supervisor's child-process environment. It never belongs in Git, UI
preferences, logs, or a model-visible diagnostic.

Initial provider settings should select the custom OpenAI-compatible provider,
the current Gemma model, `http://127.0.0.1:8080/v1`, an explicit context length of
65,536, and one concurrent run. This is a test profile, not an acceptance claim.

## Deny-by-default profile

Disable Hermes' native terminal, filesystem, browser/search, code execution,
delegation, cron, messaging, and skill-writing surfaces. Start semantic memory
disabled, or require approval for both memory and skill writes. Never use YOLO
mode. `approvals.mode: manual` is defense in depth; only the Evie broker may mint
commit authority.

The first MCP surface allows only explicitly included Evie tools. Resources and
prompts remain disabled, the worker receives a minimal environment, and idle/max
lifetime are bounded. Unrestricted filesystem MCP and shell tools are never a
shortcut around the broker.

## `AGT-002` compatibility gate

TurboFieldfare currently supports streaming Chat Completions and function tools,
but only `tool_choice` auto/none and a bounded JSON Schema subset. Before Hermes is
accepted, deterministic fixtures must cover:

- every proposed tool schema;
- one and multiple tool calls;
- tool result followed by model continuation;
- a three-tool chain;
- invalid arguments and malformed JSON;
- cancellation and stale events;
- context compression and a declared 64K session;
- mapping `assistant.delta`, `tool.started`, `tool.completed`, and
  `run.completed` without backend details entering SwiftUI;
- cold/warm latency, prompt/schema overhead, RSS, idle CPU, and clean shutdown.

If this gate fails, use a narrow compatibility adapter or reconsider the agent
runtime. Do not weaken schemas or expose native Hermes tools merely to make a demo
pass.

## Session ownership

Hermes session data will contain personal content. Its profile/database must live
under Application Support with user-only permissions and a documented retention,
delete, and migration policy. ADR 0008's current visible-history records remain the
source of truth until an explicit migration decision prevents silent duplicate
stores.

## Primary sources

- [Hermes Agent repository](https://github.com/NousResearch/hermes-agent)
- [Custom/local providers](https://hermes-agent.nousresearch.com/docs/integrations/providers)
- [Local API and sessions](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server/)
- [Toolsets](https://hermes-agent.nousresearch.com/docs/reference/toolsets-reference)
- [MCP](https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp/)
- [Memory](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory/)
- [Security](https://hermes-agent.nousresearch.com/docs/user-guide/security/)
