# Resource and standby budget

Status: targets plus one bounded first-wiring measurement on the base M5/24 GB
machine; full resource benchmark pending.

## Goals

- Evie remains summonable without a visible chat application.
- Dormant services do not interfere with normal development work.
- Heavy workers load only for an interaction or scheduled job.
- The system reacts to battery state and macOS memory pressure.
- Resource claims in this document become measurements before release.

## Runtime states

| State | Expected residents | Initial target |
|---|---|---:|
| Dormant | UI, supervisor, shortcut, optional wake word, gateway, Node-RED | <500 MB total incremental memory; near-zero idle CPU excluding keyword detection |
| Listening | Dormant plus audio capture/VAD/KWS | low single-digit CPU percentage; visible mic state |
| Warm text | Dormant plus TurboFieldfare 64K | first synthetic 64K wiring sample: 3,215 MB server physical footprint; full benchmark pending |
| Active text | Warm text plus prompt/decode activity | interactive decode target >=15 tok/s; no severe system memory pressure |
| Voice | Active text plus STT or TTS worker | workers serialized where possible; first audio target defined after benchmark |
| Vision | Warm text plus on-demand VLM | remain below pressure threshold or temporarily evict nonessential workers |
| Indexing | embedding/reranker/index writer | prefer AC power and idle periods; throttle/cancel on user activity |

The dormant memory number is a design target, not a promise. Node-RED, Hermes
gateway, and a wake-word runtime must be measured individually.

### Bounded target-Mac sample — 2026-08-04

With the verified Gemma 4 26B-A4B IT model, FP16 KV, and TurboFieldfare launched at
65,536 tokens on AC power, one non-streaming and one streaming synthetic request
left the server at a 3,215 MB physical footprint and the Swift shell at 18 MB.
Both sampled at 0.0% CPU after completion, while macOS reported 53% system-wide
memory free. The server remains loaded until explicitly stopped in this
development slice, so this is a warm-state measurement—not dormant behavior.

The input/output counts were too small for throughput or energy conclusions. See
[Model strategy](MODEL_STRATEGY.md) for exact revisions, flags, timings, and the
remaining `INF-003` gate.

## Lifecycle policy

Proposed defaults:

- UI and supervisor: always available as user LaunchAgents/menu-bar utility.
- Node-RED: enabled only when automations exist; otherwise stopped.
- Hermes gateway: always available only for configured message channels.
- primary model on AC: unload after 15 minutes idle initially.
- primary model on battery: unload after 3 minutes idle initially.
- TTS/VLM/reranker: unload 60–180 seconds after last use.
- embedding worker: start per query or indexing batch unless measured startup is
  unacceptable.
- wake word: user-toggleable; push-to-talk remains available when disabled.

All timers become user-configurable only after sensible measured defaults exist.

## Memory-pressure behavior

The supervisor should observe macOS pressure rather than rely only on free-memory
numbers.

Suggested eviction priority:

1. completed VLM/TTS/reranker workers;
2. QMD or embedding daemon;
3. inactive browser automation;
4. primary model if no request is running;
5. nonessential message gateways or workflow previews.

Never terminate an active external commit operation without recording an
indeterminate result and reconciling its target.

## Power behavior

Idle model memory consumes far less power than active inference but still reduces
available unified memory. Keyword spotting and microphone capture impose continuous
cost; generation, STT, TTS, vision, and indexing impose burst cost.

Policy candidates:

- disable speculative prewarming on battery;
- reduce warm TTL on battery and Low Power Mode;
- pause background indexing when unplugged;
- allow text-only responses when TTS would trigger a heavy cold load;
- show the user when an operation chooses a slower low-power path;
- keep the wake phrase optional during battery-sensitive work.

## Storage budget

With approximately 460 GiB free initially, storage is not the binding resource.
A planning allowance of 60–80 GB covers multiple temporary model candidates,
TurboFieldfare, voice/STT/VLM assets, indexes, build products, and benchmark
artifacts. The steady selected installation should be smaller.

Downloaded models and personal indexes stay outside Git and must have a cleanup
inventory.

## Required measurements

Every worker benchmark records:

- hardware and macOS version;
- dependency and model revision;
- quantization and context settings;
- cold and warm startup;
- time to first useful output;
- throughput/real-time factor;
- peak resident memory and post-idle memory;
- CPU/GPU activity and thermal/power observations;
- cancellation latency;
- unload time and memory recovery;
- output-quality score on its Evie cases.
