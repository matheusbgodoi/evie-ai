# ADR 0004: On-demand specialist workers

- Status: Accepted for planning
- Date: 2026-08-04

## Context

The primary TurboFieldfare runtime is text-only. Vision, STT, TTS, embeddings, and
reranking need different models, but 24 GB unified memory should not hold every
worker permanently.

## Decision

Use backend-neutral, separately managed workers with health checks, cancellation,
and idle unload. The main text agent receives structured vision/RAG observations.
OmniVoice initially runs as a command worker without its UI.

## Consequences

- Low dormant footprint and replaceable specialist models.
- Cold-start latency must be represented honestly in the interface.
- The supervisor/process lifecycle becomes custom critical infrastructure.
