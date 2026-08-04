# Local feasibility assessment

Date: 2026-08-04

Target hardware: base Apple M5 MacBook Pro, 24 GB unified memory, approximately
460 GiB free storage at the time of initial analysis.

## Verdict

Evie is technically viable as a local-first system. The hardware is sufficient for
one high-quality text model plus lightweight always-on services and short-lived
specialist workers. It is not sufficient for keeping every high-quality worker
resident simultaneously without memory pressure.

The design is viable because it distinguishes:

- **always-on control plane:** UI, supervisor, event routing, permission broker;
- **warm optional plane:** primary text model for an active interaction window;
- **ephemeral workers:** STT, TTS, vision, embedding, reranking, and indexing;
- **deterministic automation:** Node-RED flows that do not require an LLM for every
  step.

## What can be reused

### Hermes Agent

Reusable capabilities include CLI/TUI sessions, model providers, tools and
toolsets, MCP, memory, context compression, cron, gateways, Google Workspace,
WhatsApp, web search, browser automation, and custom STT/TTS providers.

Important constraints:

- agent models require a declared context of at least 64K;
- core tool schemas remain eagerly visible, while MCP/plugin schemas can use Tool
  Search progressive disclosure;
- terminal and file safety features are defense in depth, not a hard host sandbox;
- the stock UI is not the desired Evie overlay.

### TurboFieldfare

Reusable capabilities include a native Swift/Metal runtime, a loopback
Chat-Completions endpoint, streaming, function calls, prompt-prefix reuse, bounded
expert caching, and 64K context support.

Important constraints:

- weights are already predominantly 4-bit; KV is FP16;
- the runtime is model-specific and text-only;
- the OpenAI-compatible surface is intentionally partial;
- the client must authorize and execute tools;
- only one generation runs at a time;
- tool-schema compatibility and real multi-step reliability remain unmeasured with
  Hermes.

### OmniVoice

The upstream model exposes Python and command-line inference independent of its web
demo and supports Apple Silicon through MPS. A first integration can invoke the CLI
only when speech is requested. A Hermes Python provider is justified later only for
streaming, cached model lifetime, or richer voice management.

### Node-RED

Node-RED can run natively with Node.js, represents flows as JSON, provides a visual
editor, and exposes administrative APIs. It covers schedules, intervals, webhooks,
events, messages, files, HTTP, MQTT, and third-party nodes. A narrow adapter is
still needed so the model does not receive unrestricted administrative access.

### Local RAG

QMD is a ready hybrid local option. A smaller custom stack is also feasible using
SQLite/BM25 plus a compact embedding model. The correct choice depends on cold
latency, resident memory, Portuguese retrieval quality, and ingestion needs.

## What must be programmed

1. **Native interaction shell:** top-level macOS utility, non-chat overlay,
   waveforms, cards, shortcuts, accessibility, approvals, and optional history.
2. **Supervisor/model manager:** local process lifecycle, health checks, local IPC,
   idle unload, memory-pressure response, AC/battery policy, cancellation, and
   recovery.
3. **Hermes bridge:** dedicated profile/config, local model provider, scoped
   toolsets, event stream into the UI, and approval/result projection.
4. **OmniVoice adapter:** reference selection, sentence chunking, cold/warm policy,
   audio playback, cancellation, and later optional streaming.
5. **Vision adapter:** image normalization, on-demand VLM lifecycle, structured
   observations, provenance, and handoff to the primary model.
6. **RAG ingestion:** connectors, safe extraction, chunking, metadata, collection
   permissions, index scheduling, citations, and deletion/rebuild.
7. **Node-RED adapter:** generate disabled drafts, validate schemas, render/open,
   diff, approve, enable, disable, run, and audit.
8. **Apple-native integrations:** EventKit/Reminders, Mail/Shortcuts/AppleScript or
   standards-based alternatives, and scoped filesystem operations where Hermes
   does not already provide the desired boundary.
9. **Security and observability:** permission broker, Keychain access, audit events,
   log redaction, update gates, backup, and incident/revocation procedures.

## What is not fully local

"Local-first" means model execution and private state processing can remain on the
Mac. It does not make remote services local:

- Gmail, Calendar, and Drive remain Google services;
- WhatsApp remains a Meta network service, and Baileys is unofficial;
- web search queries remote indexes and websites;
- remote mail/calendar standards still contact their servers.

No paid intermediary is required for the proposed baseline, but internet services
remain subject to their terms, availability, quotas, and protocol changes.

## Complexity estimate

These are planning estimates, not commitments:

- reproducible inference and resource benchmark: 1–2 weeks part-time;
- native overlay plus supervisor prototype: 3–6 weeks part-time;
- reliable local voice loop and worker lifecycle: 2–5 additional weeks;
- RAG and first read-only workflows: 2–4 additional weeks;
- bounded automation and write actions: 4–8 additional weeks;
- polished, maintainable personal system: approximately 200–400+ engineering
  hours, depending on the number and reliability of integrations.

The highest return comes from shipping a few measured routines before expanding
the platform.
