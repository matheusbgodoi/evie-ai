# Model, context, and routing strategy

Status: baseline hypothesis; selection requires Phase 1 measurements.

## Primary quality hypothesis

The user strongly prefers the observed quality of Gemma 4 26B-A4B IT. The project
therefore treats that model as the primary candidate rather than assuming a smaller
model will preserve the same behavior.

TurboFieldfare is attractive because it streams routed experts from storage and
keeps a bounded resident set. Its installed weights are already 4-bit; changing the
KV format is a separate concern.

## Pinned first-test manifest

The development runtime pins:

| Component | First-test value |
|---|---|
| TurboFieldfare revision | `7a99f2a635e3adf7ed0720b882d2edb600f2f0da` |
| OpenAI-compatible model ID | `gemma-4-26b-a4b-it` |
| Source checkpoint revision | `0d77464eeb233a2da68ebf9d7dc4edaac7db956d` |
| Verified source snapshot | `sha256:bf198c9f5ea6462addca1966e5dd669c407537a876e82cf06db9084c5c850b13` |
| Declared server context | 65,536 tokens |
| Weight format | Upstream repacked `.gturbo` assets; no weights enter Git |
| KV baseline | FP16 |
| Endpoint | `http://127.0.0.1:8080/v1` only |

The pinned release server and repacker built on the exact base M5/24 GB Mac using
macOS 27 Apple Command Line Tools. The upstream verifier passed 37 files totaling
14,291,915,755 bytes, and model discovery plus non-streaming/SSE synthetic
inference passed on loopback at the declared 64K. This is reproducible first-test
evidence, not a quality, long-context, energy, or full performance validation.

### First wiring measurement — 2026-08-04

Conditions: base Apple M5 MacBook Pro with 24 GB unified memory, macOS 27.0, AC
power, TurboFieldfare revision and model snapshot above, FP16 KV, 65,536 declared
tokens, queue limit 4, and single-prefix prompt cache. The prompt was fixed and
synthetic; no personal content was used or recorded.

| Observation | Measured result |
|---|---:|
| Loopback server ready | 3.14 s |
| Fresh non-streaming request | 5.393 s; 24 prompt / 4 completion tokens |
| Immediately following SSE request | 0.882 s; 22 prompt / 2 completion tokens; `[DONE]` received |
| Warm server physical footprint | 3,215 MB |
| Warm server RSS reported by `ps` | 1,181,552 KiB |
| Native shell physical footprint | 18 MB |
| Server/shell sampled idle CPU | 0.0% each |
| System-wide memory free after requests | 53% |

These very short completions are unsuitable for tokens-per-second or quality
claims. They show that 64K allocation, Metal execution, the OpenAI-compatible
route, and the native development process can coexist without immediate memory
pressure on this machine. `INF-003` still owns cold/warm, 16K/32K/64K, sustained
decode, long-context correctness, battery, and energy measurements.

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

### VS-001 context behavior

The source-implemented direct client declares 65,536 tokens and reserves up to
4,096 completion tokens. It sends the complete bounded in-memory conversation on
each request so TurboFieldfare can reuse a matching retained prefix. Because the
lightweight shell deliberately does not link Gemma's tokenizer, it trims older
complete user/assistant turns with a conservative character budget.

The OpenAI-compatible request cannot change server capacity. TurboFieldfare must be
started separately with `--max-context 65536`; its upstream default is 16K. This
configuration is not yet proof that 64K is performant or reliable on the target
Mac. The small synthetic responses that passed at this launch setting establish
wiring only; they cannot replace long-context correctness or the 16K/32K/64K
benchmark matrix.

### The cached prefix decides where the clock goes

The server runs with `--prompt-cache-mode single-prefix`, so the hidden system
message is the cached prefix of every request. **42% of prompt tokens on this Mac
are served from that cache**, measured over the last forty requests in the
server's log (`75ec2f2`). Anything that changes on every turn and sits early in
the prompt destroys that: the prefix stops matching and the whole thing is
reprocessed.

That is why Evie's clock is split rather than placed once. The **date** is in the
system prompt, where it is unchanged for a whole day and the cache survives;
`refreshSystemPrompt` runs before each turn and returns early when the text has
not moved, so a session left open overnight stops answering with yesterday. The
**exact time** is attached to the question, after everything cached, where the
tokens were going to be new anyway. Two clock tests now assert the minute is
absent from the system prompt rather than present, and both carry the reason,
because they invert what they were originally written to check.

A side effect worth keeping: each turn carries the time it was asked at, so "há
quanto tempo eu perguntei isso" has an answer, and the timestamps of earlier turns
never change — which is also what keeps the prefix stable.

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

## The served model has no reasoning mode

Asked for, because a toggle for it was requested. `Scripts/evie-probe thinking`
re-runs this at any time; the reading below is from 2026-08-06 against
`gemma-4-26b-a4b-it`.

| asked for | result |
| --- | --- |
| `chat_template_kwargs.enable_thinking` | accepted, ignored |
| `reasoning_effort` | accepted, ignored |
| `thinking: {type: enabled}` | accepted, ignored |
| `reasoning_content` in the reply | absent |
| `<think>` tags in the output | absent |

Every parameter is accepted and none of them changes anything, which is worse
than a refusal: a server that errors tells you where you stand. Given a problem
that would make a reasoning model think, this one writes its working out as
ordinary visible prose — "Para resolver esse problema, vamos seguir um passo a
passo lógico" — with nothing hidden behind it.

So there is no phase to switch on or off. A setting called "Thinking" would be a
switch wired to nothing, which is the exact defect this project has already had
once, in the wake phrase.

What *is* available is `/plano`, which is reasoning made explicit: the question
is decomposed, the steps run in order, and the working is on screen rather than
concealed.
