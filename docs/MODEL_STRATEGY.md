# Model, context, and routing strategy

Status: baseline hypothesis; selection requires Phase 1 measurements.

## Primary quality hypothesis

The user strongly prefers the observed quality of Gemma 4 26B-A4B IT. The project
therefore treats that model as the primary candidate rather than assuming a smaller
model will preserve the same behavior.

TurboFieldfare is attractive because it streams routed experts from storage and
keeps a bounded resident set. Its installed weights are already 4-bit; changing the
KV format is a separate concern.

## Context strategy

- Configure the server and Hermes provider for **65,536 tokens**.
- Keep normal active turns substantially below the maximum through retrieval,
  scoped toolsets, Tool Search, result truncation, and context compression.
- Do not fill 64K merely because it is available. Long prompt processing increases
  latency even when memory fits.
- Preserve complete local transcripts outside the active model prompt.
- Summarize or page large email, web, Drive, and file results before reinjection.

Sixteen thousand tokens is acceptable for isolated text or bounded subworker tasks,
but it is not the target Hermes agent window.

## What is already quantized

TurboFieldfare uses 4-bit MLX-affine weights for embeddings, attention, shared
experts, and routed experts, with an 8-bit router. The resident shared core and
expert cache are therefore already aggressively compressed.

The current KV cache is FP16. "Q4/Q8 memory" must not be confused with the weight
quantization already present.

## KV cache baseline

Gemma 4 26B-A4B has 30 text layers: 25 sliding-attention layers with a 1,024-token
window and five full-attention layers. It also uses grouped-query attention with
fewer KV heads for global attention. This makes a 64K KV cache much smaller than a
conventional 30-layer model retaining full K/V for every layer.

A source-derived calculation for the current physical layout places FP16 KV at:

| Maximum context | Approximate KV storage | Notes |
|---:|---:|---|
| 4K | 305 MiB | 225 MiB sliding ring plus 80 MiB full attention |
| 16K | 545 MiB | Sliding ring stays fixed; full attention is 320 MiB |
| 32K | 865 MiB | Full attention is 640 MiB |
| 64K | 1,505 MiB / 1.47 GiB | Full attention is 1,280 MiB |

The current implementation uses a physical sliding ring of 1,152 tokens (1,024
attention window plus 128-token prefill chunk allowance), which explains the fixed
225 MiB sliding allocation. Runtime buffers, Metal allocations, tokenizer state,
weights, and expert cache are additional. Starting from the project's approximately
2 GB 4K figure, a reasonable unmeasured 64K process estimate is approximately 3.2
GB. Phase 1 must measure actual peak and resident memory.

## KV quantization policy

Baseline: retain FP16 KV until end-to-end correctness and resource measurements
exist.

Potential experiment order, only if measured pressure justifies upstream-runtime
work:

1. Ring-aware Q8 K and Q8 V with fused/decode-aware Metal kernels.
2. Hybrid precision if evidence shows keys, values, or specific layers are more
   sensitive.
3. Stop if the quality, prompt-cache, or speed gates fail.

Q6 and Q7 are not assumed to be useful merely because their names suggest a middle
ground. They require inconvenient packing and custom Metal kernels. At 64K, a
hypothetical Q7 cache saves only about 94 MiB beyond Q8, and Q6 saves roughly 188
MiB beyond Q8. Those differences are small relative to total system memory.

Expected theoretical cache savings, excluding metadata and alignment:

- FP16 to Q8: approximately 2× smaller;
- FP16 to Q4: approximately 4× smaller.

For this architecture, an idealized Q8 cache is approximately 756 MiB at 64K,
saving about 749 MiB. That does not justify new Swift/Metal kernels and correctness
risk in the first release. Quantization is an upstream-runtime experiment, not a
configuration toggle in the current baseline.

### Why Q4 is not a planned experiment

TurboFieldfare previously implemented a custom K4/V4 TurboQuant cache. It was
removed after model-specific tests found it slower than FP16, with mean delta-NLL
`+0.015197`, top-1 agreement down about 5.08 percentage points, and top-8 agreement
down about 5.60 points. Its old layout also grew all 30 layers to maximum context
instead of retaining the current sliding ring, so restoring it would be worse at
64K. A new ring-aware design would still need complete kernels and quality gates.

Preserving the Gemma quality is a product requirement; Q4 KV is therefore rejected
for the baseline.

## Standby memory recovery

The current KV manager can reset and advise macOS that cache pages are no longer
needed. The server retains one successful prompt prefix by default for reuse.
Evie's lifecycle manager should use two timeouts:

1. a short idle timeout that clears retained conversation KV/prefix state when
   privacy or memory recovery is preferred;
2. a longer timeout that stops the model process entirely, especially on battery.

This provides meaningful standby recovery without altering numerical precision.

## Routing policy

The strongest model should own ambiguous multi-step orchestration. Smaller models
are allowed for bounded specialist work, not as an unverified master router.

```text
known deterministic intent  -> direct adapter or approved Node-RED flow
open question/tool task     -> primary Gemma agent
image present               -> VLM observation -> primary Gemma agent
document retrieval          -> local retrieval -> primary Gemma agent
simple extraction/classify  -> optional small worker after benchmark
primary failure/low score   -> selected fallback or explicit user escalation
```

Escalation should use deterministic evidence where possible:

- requested capability (image, long document, multi-source research);
- number or sensitivity of required tools;
- schema/parse failure;
- low retrieval confidence;
- self-consistency or validator failure;
- explicit user request for the strongest mode.

Do not rely solely on a 2–4B model asking itself whether a task is difficult.

## Smaller-model evaluation

Phase 1 should test at least:

- one current 4B-class instruction/tool model;
- one current 9B-class instruction/tool model;
- the TurboFieldfare Gemma primary candidate.

Candidates must be pinned just before the benchmark. Selection criteria:

- Brazilian Portuguese quality;
- correct tool choice and arguments;
- multi-step recovery from tool errors;
- instruction/prompt-injection resistance;
- RAG citation faithfulness;
- first-token and total latency;
- peak and idle memory;
- energy impact;
- quantized model license and local runtime stability.

The smaller model may become the low-power default only if it passes the Evie suite
and escalation does not make ordinary interactions slower or less predictable.

## Vision model strategy

TurboFieldfare is text-only, even though the upstream Gemma family includes vision.
A separate VLM is therefore required. It should be loaded only for image requests
and return structured observations rather than directly executing personal tools.

The first VLM benchmark should include screenshots, photographed documents,
Portuguese OCR, charts, UI state, and ordinary photos. A 3–4B model is preferred if
quality passes; a larger model is acceptable on demand within the active resource
budget.
