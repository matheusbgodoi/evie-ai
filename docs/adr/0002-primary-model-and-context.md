# ADR 0002: Gemma/TurboFieldfare primary candidate at 64K FP16 KV

- Status: Accepted for planning; Phase 1 validation required
- Date: 2026-08-04

## Context

The user values the quality of Gemma 4 26B-A4B IT. Hermes requires at least 64K
declared context. TurboFieldfare supports 64K, 4-bit streamed weights, tool calls,
and prompt-prefix reuse, but has a partial API and FP16 KV.

The 64K KV layout is approximately 1.47 GiB. An upstream Q4 KV implementation was
slower and materially reduced agreement quality, then was removed. Hypothetical Q8
would save only about 749 MiB and requires new ring-aware Metal kernels.

## Decision

Benchmark Gemma/TurboFieldfare at 64K with the current FP16 KV as the primary
candidate. Keep ordinary active context smaller through retrieval and compression.
Use reset/idle process unload for memory recovery. Do not implement KV quantization
before target-hardware evidence demonstrates a need.

## Consequences

- Preserves the preferred model's quality hypothesis.
- Fits the planning memory budget by source calculation, pending measurement.
- Requires Hermes tool-schema and multi-step compatibility tests.
- Q8 remains a later upstream experiment; Q4 is not a baseline option.
