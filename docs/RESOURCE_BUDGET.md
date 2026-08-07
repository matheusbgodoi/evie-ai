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
| Dormant | UI, supervisor, shortcut, optional wake word, gateway | <500 MB total incremental memory; near-zero idle CPU excluding keyword detection. Measured 2026-08-07: 0% CPU, 10 MB shell, 9 MB server |
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

### What it costs to leave her open — 2026-08-07

The question a reader actually has is "what does it cost to keep Evie running all
day", and until now this document only answered the warm-server half of it. This
is the whole path, measured on the target Mac (base M5, 24 GB, macOS 27, AC
power) against the installed bundle in `~/Applications`, with the model server
already started.

Method, so it can be repeated: CPU is a delta of `ps -o cputime=` over a fixed
interval rather than `ps`'s lifetime average or a `top` sample; memory is
`ps -o rss=`; the system figure is the "System-wide memory free percentage" line
`memory_pressure` prints. The work under measurement is
`evie-shell --tools-check`, which is a real agentic turn over a throwaway folder.

| | evie-shell | TurboFieldfare server |
|---|---:|---:|
| Idle CPU, over a 10 s interval | 0% | 0% |
| Idle resident memory, long idle | 10 MB | 9 MB |
| Idle resident memory, shortly after a turn | — | 776 MB |
| Peak CPU during the turn | 0% | 130% of one core, of ten |
| Peak resident memory during the turn | — | 1.66 GB |

System-wide free memory was 45–50% before the turn, fell to 36% during it, and
was back at 53–55% within 9 s of the turn finishing. The server's resident set
fell from 1.3 GB to 1.0 GB within 6 s and to 776 MB by 36 s.

Three things this does and does not say:

- **Idle is genuinely idle.** Neither process spends measurable CPU between
  questions, and a server that has not been asked anything for a while holds
  single-digit megabytes. That is the same order as the 4 MB idle figure the
  Node-RED comparison used in `docs/AUTOMATIONS.md`.
- **Resident memory is not the model.** The weights are memory-mapped, so the
  server's resident set is what is paged in at that instant, not the 14.3 GB
  installation. The 3,215 MB warm footprint above is `ri_phys_footprint` from a
  different measurement and is not comparable to these `rss` figures.
- **The system-wide percentage is the whole machine.** Other work was running on
  this Mac during the sample, so the direction and the recovery are the finding;
  the exact percentage is not attributable to Evie alone.

The turn itself took 52 s and three tool calls, which is a latency figure and not
a resource one; the Phase 1 benchmark below is still what settles throughput.

## Lifecycle policy

Proposed defaults:

- UI and supervisor: always available as user LaunchAgents/menu-bar utility.
- Scheduled work: `launchd` holds the schedule and Evie holds nothing. A user
  LaunchAgent starts the bundle for one question and it exits; between firings
  there is no timer and no process. Overlapping runs skip rather than queue,
  because the model is a single worker. See `docs/SECURITY.md`.
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
