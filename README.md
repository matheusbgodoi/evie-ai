# Evie AI

Evie is a local-first personal AI assistant for macOS, pronounced **"ee-vee"**
("ívi"). It is intended to be available by voice or a global shortcut without
behaving like a permanent chat window.

The project is currently in **Phase 0: feasibility and architecture**. No model,
agent runtime, messaging bridge, workflow engine, or background service is
installed by this repository yet.

## Product intent

Evie should eventually provide:

- a lightweight, always-available macOS presence;
- push-to-talk and optional wake-word activation;
- a transient visual overlay with audio feedback and expandable glass cards;
- local speech-to-text, language-model inference, RAG, vision, and TTS;
- bounded tools for email, calendars, drives, files, WhatsApp, and web research;
- inspectable schedules, webhooks, triggers, and visual workflows;
- explicit approval before external or destructive actions;
- aggressive unloading of heavy workers while idle.

## Proposed foundation

- **Agent runtime:** Hermes Agent, using a dedicated Evie profile.
- **Primary model:** Gemma 4 26B-A4B IT through TurboFieldfare at 64K context.
- **Model alternatives:** smaller local models evaluated against Evie-specific tasks.
- **RAG:** local hybrid retrieval with a small embedding model and optional reranker.
- **Vision:** a separate local VLM loaded only for image tasks.
- **Speech-to-text:** local Whisper-class backend, selected by benchmark on Apple Silicon.
- **Text-to-speech:** OmniVoice through its CLI/Python backend, without its web UI.
- **Automation:** Node-RED as a local deterministic workflow engine and visual canvas.
- **Interface:** a native SwiftUI/AppKit macOS utility app and lightweight supervisor.

The architecture is intentionally replaceable: Hermes, TurboFieldfare, the VLM,
the retrieval engine, and the TTS engine remain behind local adapters.

## Documentation map

- [Current status](docs/PROJECT_STATUS.md)
- [Roadmap](docs/ROADMAP.md)
- [Feasibility assessment](docs/FEASIBILITY.md)
- [System architecture](docs/ARCHITECTURE.md)
- [Model and context strategy](docs/MODEL_STRATEGY.md)
- [Resource and standby budget](docs/RESOURCE_BUDGET.md)
- [Interface and interaction model](docs/UI_UX.md)
- [Voice architecture](docs/VOICE.md)
- [RAG design](docs/RAG.md)
- [Automation design](docs/AUTOMATIONS.md)
- [Security model](docs/SECURITY.md)
- [Testing and evaluation](evals/README.md)
- [Agent handoff protocol](docs/HANDOFF.md)
- [Work log](docs/WORKLOG.md)
- [Decision records](docs/adr/README.md)
- [Research sources](docs/RESEARCH_SOURCES.md)

## Repository boundary

This repository contains source code, documentation, schemas, sanitized workflow
definitions, and configuration examples. Runtime state and private data must stay
outside Git:

- OAuth tokens and API credentials;
- WhatsApp session material;
- Node-RED credential files;
- voice-reference recordings;
- email, calendar, Drive, and personal document content;
- vector indexes, model weights, caches, transcripts, and logs.

See [.gitignore](.gitignore) and [Security](docs/SECURITY.md) before adding any
integration.

## Status

Planning only. The first implementation milestone begins only after the Phase 0
research gates in the roadmap are accepted.
