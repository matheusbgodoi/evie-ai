# Model context, sampling and compaction

Research checked 2026-10-17. This document separates model specifications,
server limits and the capacity measured on the actual hardware. It contains no
private endpoint, tailnet name, address or credential. Operational context and
automatic compaction are implemented under ADR 0026; the coordinating agent
records the final installed-runtime check separately before release.

## Effective settings

| Brain | Effective context target | Published model context | Output budget |
| --- | ---: | ---: | --- |
| PC · `qwen-daily` | **200,704 tokens**, matching the verified OpenCode setup | Qwen3.8-27B: 262,144 native | Configured ceiling of 16,384 tokens, matching OpenCode and reserved inside the context budget |
| Mac · LensVLM 9B OptiQ | **131,072 tokens**, largest qualified operational rung on the 24 GiB M5 | 262,144 nominal | Configured ceiling of 2,048 tokens, reserved inside the context budget |

Context includes system text, tools, history, the new message, image tokens
and generated reasoning/final output. Increasing a display number does not
increase server capacity. Prompt plus reserved output must fit the operational
budget. The published extension to one million tokens is not enabled here.

The PC's 200,704-token limit is the qualified operational setting; the
coordinating run found that higher settings did not retain its required GPU
memory margin. That hardware result takes precedence over a model card's
architectural ceiling. The Mac setting comes from isolated synthetic text and image inference with
measured memory margin. Its published 262,144-token ceiling remains unqualified
on this machine; the larger exploratory run did not retain enough headroom.

The brain popover displays the selected profile's exact context limit and
completion cap, last-send usage with its source when available, and automatic
compaction state. These stay out of the 30-point input button. The usage string
labels an estimate explicitly; a server-reported count is identified as such.
An estimate is not a model tokenizer measurement. The coordinator may include
the percentage of the effective context in the same last-send line.

## Model identity and primary sources

`qwen-daily` is a serving alias. Its UI name alone does not prove which
checkpoint is loaded; verify the server's artifact/configuration separately.
The official [Qwen3.8-27B card](https://huggingface.co/Qwen/Qwen3.8-27B)
and [configuration](https://huggingface.co/Qwen/Qwen3.8-27B/blob/main/config.json)
report a 27B hybrid model: 64 layers, one full-attention layer per four, four
KV heads and 256-dimensional heads. Native context is 262,144. Extending it
requires explicit supported RoPE/YaRN configuration and hardware qualification.

[LensVLM-9B](https://huggingface.co/apple/LensVLM-9B) is Apple's document-reading
fine-tune of **Qwen3.5-9B**, not Qwen3.8. Its learned document-expansion tools
are not equivalent to general desktop tools. The
[OptiQ quantization card](https://huggingface.co/mlx-community/LensVLM-9B-OptiQ-4bit)
and [quantized configuration](https://huggingface.co/mlx-community/LensVLM-9B-OptiQ-4bit/blob/main/config.json)
describe mixed 4/8-bit language weights and a bf16 vision tower: approximately
7.10 GB plus 0.91 GB on disk. “4bit” is not a claim that every weight or cache
is four bits. The quantization allocation was transferred from its matching
Qwen3.5 architecture; the card does not claim a full benchmark of this fine-tune.

Revisions observed from public Hugging Face metadata:

| Source | Revision |
| --- | --- |
| `Qwen/Qwen3.8-27B` | `1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0` |
| `apple/LensVLM-9B` | `ac40d9667bd68df3ac9839d3f0dc7bdb93f5f92b` |
| `mlx-community/LensVLM-9B-OptiQ-4bit` | `9e3d1de1d65ed7a301cdeed4b58e70a461a02463` |

These identify the researched sources; they are not a claim that the installed
model cache or server artifact was changed to those revisions.

## Sampling recommendations and ownership

The [Qwen generation settings](https://huggingface.co/Qwen/Qwen3.8-27B/blob/main/generation_config.json)
and official card distinguish two modes:

| Mode | Temperature | Top-p | Top-k | Min-p | Presence penalty | Repetition penalty |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Thinking | 1.0 | 0.95 | 20 | 0 | 0 | 1 |
| Non-thinking | 0.7 | 0.80 | 20 | 0 | 1.5 | 1 |

The owner's PC gateway remains authoritative for its qualified dual-mode
sampler, including any documented departure such as its minimum-probability
guard. Evie must not accidentally replace that policy with generic defaults.
Qwen3.8 supports `low`, `medium`, and `xhigh` reasoning effort. The official
template defaults to `preserve_thinking: true`. Evie deliberately sends
`preserve_thinking: false` when enabling reasoning through `templateKwargs`;
its conversation messages store and replay the answer content, not a separate
reasoning trace. Thus Evie does not claim exact alignment with that recommended
multi-turn template. Reasoning is off by default in the owner's configuration
for direct responses and latency; the person can choose an effort per profile.
Runtime acceptance and actual behavior must be verified on the serving stack.
Recommendations for enormous separated reasoning/final-output caps assume a
much larger supported context; they do not override this gateway's completion cap.

The PC's 16,384 tokens are the profile ceiling, not the size requested on every
call. `TurnOptions` requests 8,192 for low/medium reasoning and 16,384 for
`xhigh`; its reasoning budget takes at most three quarters of that request,
leaving room for the final answer. A written turn with reasoning off uses the
profile cap. A voice turn with reasoning off requests 1,024; enabling reasoning
uses the corresponding larger thinking cap. Computer-use steps request 1,024,
with low reasoning on the PC. The client clamps every requested output cap to
the selected profile's maximum, so the Mac ceiling remains 2,048. Reasoning and
final output share the completion allowance and total context; these are upper
bounds, not requested answer lengths or guaranteed token consumption.

LensVLM has no equivalent model-specific general sampling table in the primary
sources checked. Apple's
[official evaluation loop](https://github.com/apple-aiml-research/ml-lensvlm/blob/main/lensvlm/evaluate.py)
uses **temperature 0** for one trajectory and **2,048 output tokens per turn**;
its multiple-trajectory evaluation uses 0.7. The OptiQ card's demonstrated
image tests also use greedy decoding. These are reproducible task settings,
not evidence that a 0.7 general chat sampler or a larger completion cap is
optimal for this specialized fine-tune. Qwen3.8's sampler must not be copied
into LensVLM on the basis of their related architectures.

## Mac memory estimate and qualification

LensVLM has 32 text layers, eight with full attention, four KV heads and a
head dimension of 256. With unquantized two-byte KV values, the full-attention
cache alone is estimated as:

`2 (K + V) × 8 layers × 4 heads × 256 × 2 bytes = 32,768 bytes/token`.

That is approximately **4 GiB at 131,072 tokens** or **8 GiB at 262,144**,
before weights, linear-attention states, vision processing, prefill temporaries,
framework allocations and other applications. This is arithmetic from the
architecture, not a memory measurement or a promise that either setting fits.
Quantized KV changes this estimate and needs its own compatibility and quality
checks. On-disk weight size and process RSS are not the Metal allocation peak.

The installed MLX runtime's Qwen3.5 implementation supplies its own hybrid
cache (arrays for linear layers and KV caches for attention). Its generic
rotating-cache limit does not replace that model-specific cache. The local
server's context-budget check separately enforces prompt plus requested output
against its configured limit. Keep the runtime budget, client budget and UI
aligned rather than assuming an argument name proves effective enforcement.

Qualification should use synthetic content only, place identifiable needles
near the beginning/middle/end, record actual token counts and retrieval result,
measure Metal peak/memory pressure while the machine is awake, and leave the
user's files and conversations out. A model that loads successfully has not
thereby demonstrated maximum-context inference. An enlarged ceiling adds no
model process while idle; long active prefill still costs time, energy and
memory. Compaction reduces repeated history cost without fabricating an
infinite context window.

## Measured Mac qualification (2026-10-17)

The [sanitized capacity evidence](validation/lens-context-qualification.json)
records the cached model revision, exact request counts, controls and metrics.
The adopted **131,072-token** operational budget uses **8-bit KV**, a
**512-token prefill step**, **one concurrent sequence**, and an MLX allocator
free-cache limit of **256 MiB** set through the public `mx.set_cache_limit`
API before starting the runtime. This limits reusable allocator buffers, not
active model allocations or total machine memory. APC was disabled.

The experimental server was configured for **262,144**, while the successful
final request used **127,527 prompt tokens including one image**, reserved
256 output tokens and generated 38. The exact answer recovered all four
synthetic records in order plus the independently visible **ZEBRA4817** caption.
It stopped normally without an API error or headroom abort. This request fits
131,072; it does not claim the benchmark server was already configured to that
smaller limit. The installed Evie integration separately checks the adopted
server cap and its real request path.

Final image run: **385.99 s prefill**, **386.82 s first token**, **392.31 s total**,
330.39 prefill tokens/s and 6.92 decode tokens/s. MLX reported a cumulative
process peak of **14.819 GB (13.80 GiB)**, below this device's recommended Metal
working set of 19.070 GB. Machine-wide free-memory samples every five seconds
stayed at or above **10% (approximately 2.4 GiB)** in this final run. Other
applications affect that measure; this is bounded evidence, not a universal
memory guarantee. Long prefill is expensive in latency and energy, so automatic
compaction remains necessary even with the larger capacity.

Text controls also passed four-record retrieval at 64,473 and 128,984 prompt
tokens. The former took 139.17 s with a 12.438 GB MLX peak; the latter took
409.74 s with a 14.848 GB peak. Earlier exploration was unsuccessful: BF16 KV
ran out of Metal memory at 72,704 prefill tokens, and uncapped KV8 was stopped
at 119,296 tokens when free system memory remained at 6%. Neither demonstrates
262,144-token capacity. No 196,608-token run was performed after the bounded
131,072 result was selected.

### Small-image OCR control

The original 512 × 128 caption produced only 64 visual tokens and failed OCR
under both BF16 and KV8. A corrected five-item prompt still failed at short
context, so those image runs were rejected. Strict loading proved all 1,260
parameters were supplied, including all 333 vision parameters; stock and
OptiQ image preprocessing matched numerically. Solid red, blue and green image
controls worked. This narrowed the failure to insufficient visual resolution
for this OCR task rather than a missing vision sidecar.

Nearest-neighbor enlargement of the actual image bytes to **1536 × 384**
(576 visual tokens) made the short five-item KV8 baseline pass, then the final
long-context image request passed unchanged assertions. The server's
`resize_shape` argument was ignored by its `BaseImageProcessor`; merely adding
that field did not correct the request. Evie's model-specific wire preparation
therefore enlarges small Lens images before encoding. These synthetic tests
qualify the exercised retrieval and OCR contract, not general OCR accuracy or
all desktop-agent behavior. All experimental services were shut down afterward.

## Context-control visual verification

The updated `BrainControlsView` passed standalone `swiftc -typecheck`, strict
Swift formatting lint and diff whitespace checks. A native window probe linked
this view against the built EvieCore library, using synthetic 200,704-token
profile data, and displayed normal and compacting states side by side.
The selected-window capture succeeded and was reviewed: limits, last-send
source/percentage, compaction status, reasoning and both toggles fit; model
changes/test/effort are disabled while compacting. No input-button width or idle
animation was added. The probe's completion cap comes from its compiled fixture
profile and is not a new measurement of server capacity.

[Context and compaction controls](images/apple-visual/context-and-compaction-controls.png).
Full-app wiring and model-budget tests are recorded by the integration run.
