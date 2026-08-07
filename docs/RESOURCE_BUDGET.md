# Resource and standby budget

Status: targets plus measurements on the base M5/24 GB machine. Idle, single
question, sustained load, and what this Mac will say about energy and heat are
all measured; the full worker-by-worker benchmark is still pending.

Three questions a reader usually has, and where each is answered:

- **What does it cost to leave her open?** [What it costs to leave her open](#what-it-costs-to-leave-her-open--2026-08-07).
- **What does it cost to ask her something?** [Ten questions back to back](#ten-questions-back-to-back--2026-08-07).
- **Does it heat the machine or drain the battery?** [Energy and heat](#energy-and-heat--2026-08-07).

## The machine these numbers come from

Every figure below was taken on one Mac. Nothing here is a claim about Apple
Silicon in general, and a different machine would produce different numbers.

| | |
|---|---|
| Model | MacBook Pro, `Mac17,2` |
| Chip | Apple M5, 10 cores — 4 performance, 6 efficiency |
| Memory | 24 GB unified |
| macOS | 27.0 (build 26A5388g) |
| Power adapter | 68 W USB-C |
| Model | `gemma-4-26b-a4b-it` on TurboFieldfare, 65,536-token context, FP16 KV |

Read with `system_profiler SPHardwareDataType` and
`sysctl -n hw.model machdep.cpu.brand_string hw.memsize`, and reported by
`evie-shell --energy-check`.

A note on how CPU is expressed throughout. A percentage is **percent of one
core**, so 100% is one of the ten busy and the machine's ceiling is 1000%. Every
CPU figure is a delta of `ps -o cputime=` over a known interval, never `ps`'s
`%CPU` column — that column is an average over the process's whole lifetime, and
for a daemon that has been up for days it says almost nothing about now.

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

### Ten questions back to back — 2026-08-07

Everything above is one question. One question tells you nothing about the case
where a laptop actually gets hot, which is a run of them, so this is ten in a
row against the running server with no pause between.

**Conditions**, because they change the numbers: on AC power, battery at 80% and
not charging. **Other applications were running throughout and were not stopped**
— Adobe Creative Cloud, Google Chrome, Terminal, and a Claude Code session. This
is not a clean room, and it is deliberately not one: it is the machine as its
owner actually uses it. The consequence is that machine-wide figures (GPU, free
memory) include that other work, and only the per-process figures are Evie's
alone.

**Method.** A Python sampler at 1 Hz over three phases — 59 s idle, 95 s of load,
58 s of recovery — recording per-process CPU time and resident memory from `ps`,
machine-wide GPU utilisation from the IO registry, and the free-memory percentage
from `memory_pressure` every fifth sample. The ten prompts were one-paragraph
general-knowledge questions in Portuguese, capped at 220 completion tokens, sent
non-streaming and strictly one at a time, since the server is a single worker
and serialises anyway.

| | Idle, 59 s | Load, 95 s | Recovery, 58 s |
|---|---:|---:|---:|
| Server CPU, % of one core | 0.0% | **101.3%** | 0.0% |
| Server resident memory | 513 MB | 521 → **1,566 MB** | 1,231 → 1,113 MB |
| GPU utilisation, whole machine | 20.5% mean | **74.8% mean, 87% peak** | 21.4% mean |
| System free memory | 48–49% | 29–38% | 49–52% |
| CPU speed limit | not reported | not reported | not reported |
| Thermal state | nominal | nominal | nominal |

The ten questions took **95.4 s in total** and produced 1,738 completion tokens
from 317 prompt tokens — a mean of **9.5 s per question** and **18.2 tokens per
second** aggregate.

Four things this says.

- **A question is a GPU cost, not a CPU cost.** The server holds about one core
  of ten while it answers, which is the small half of the bill. The GPU goes from
  a fifth busy to three-quarters busy, and that is where the work is. Any account
  of what Evie costs that quotes only `%CPU` is understating it by a wide margin,
  which is why `--energy-check` reports the GPU at all.
- **The cost per question is steady, and drifts down slightly.** The first five
  questions averaged 19.0 tokens per second and the last five 17.6 — a **7.3%
  decline** across the run. Per-question time went from 8.0 s at the fastest to
  11.4 s at the slowest. That is a drift, not a cliff, and with other applications
  competing for the same GPU it cannot be attributed to Evie alone.
- **The machine never throttled.** `pmset -g therm` reported no CPU speed limit at
  any point — on this Mac it recorded no thermal or performance warning level at
  all, before or after the run — and `ProcessInfo.thermalState` was `nominal` in
  every sample of every phase. Ten questions back to back does not make this
  machine hot enough for macOS to mention it.
- **Sustained load releases memory more slowly than a single question does.**
  After one question the server settles back to single or low double-digit
  megabytes. After ten, it was still holding **1.1 GB a full minute later**, and
  the run ended before it finished releasing. System-wide free memory did recover
  fully, to slightly better than it started. If the resident set after a heavy
  session matters, it is worth measuring for longer than a minute; this run does
  not establish where it settles.

### For scale: what else on this Mac costs — 2026-08-07

A megabyte or a percentage means nothing on its own. These were sampled by the
same method, in the same windows, on the same machine, so they are directly
comparable.

| Over the 95 s the ten questions took | CPU, % of one core | Core-seconds spent |
|---|---:|---:|
| Evie's model server | 101.3% | 95.9 |
| Adobe Creative Cloud (all its processes) | 250.8% | 237.3 |
| Google Chrome (all its processes) | 2.6% | 2.5 |
| Evie's shell | 0.0% | 0.0 |

The comparison that answers the question this document was written for: during
the busiest 95 seconds Evie had all day, **Adobe Creative Cloud spent two and a
half times as much CPU as she did**. And Adobe was doing it in the other two
phases as well — 256.1% of a core while Evie sat idle, 242.6% during recovery —
which is to say continuously, for nothing the owner asked for. Chrome, with
tabs open, cost about a twentieth of a core and 1.09 GB resident.

Evie's cost is a burst that starts when you ask and stops when she answers.
The expensive thing on this Mac is the software that never stops.

### Energy and heat — 2026-08-07

This is the section where a resource document is usually silent, so it says
plainly what could and could not be read.

**What cannot be measured on this Mac, and why.**

- **Watts per process.** `powermetrics` is the tool that reports them and it
  requires `sudo`. No figure in this document was taken with elevated privileges.
- **Watts overall, while on AC.** The battery is the only component that reports
  a current, and on mains power it reports `Amperage = 0` — the machine is being
  fed by the adapter, not the cell. That zero is the absence of a measurement,
  not a measurement of nothing, and it is never printed as "0 W". The adapter's
  68 W is its rating, not its draw.
- **Fan speed.** Not readable without a privileged helper. Not guessed at here.
- **Sensor temperatures in degrees.** Same.
- **Per-process energy from the kernel.** `ri_billed_energy` was read on this Mac
  and returns exactly 0 for an unentitled process, which is why `ProcessCost`
  in `EvieDiagnostics+AudioAndVoice.swift` deliberately does not report it.

**What can be measured, and was used instead.**

- **GPU utilisation**, from the `PerformanceStatistics` dictionary the accelerator
  publishes in the IO registry. No privileges needed. This is the best available
  proxy for the energy an answer costs, because the decode runs there.
- **Thermal state**, from `ProcessInfo.thermalState` — macOS's own judgement of
  whether the machine is being asked for more than it can cool.
- **CPU speed limit**, from `pmset -g therm`. Anything below 100 is throttling.
- **CPU time**, from `ps`, as core-seconds. Between two versions of the same code
  this is the closest honest stand-in for energy, which is the same reasoning
  `--wake-cost-check` uses for cycles.

**The numbers.** Taken by `evie-shell --energy-check`, on AC, with the same other
applications running:

| | Idle, 12 s | Generating, 39 s |
|---|---:|---:|
| GPU utilisation, mean | 19.5% | **79.0%** |
| GPU utilisation, peak | 26% | 89% |
| Thermal state | nominal | nominal throughout |
| Low Power Mode | off | off |
| Battery draw | unavailable on AC | unavailable on AC |

That is an independent reproduction of the sustained-load table above — a
different tool, a different run, the same finding: a question roughly quadruples
GPU utilisation and does not warm the machine enough for macOS to say so.

**Battery life.** No estimate of questions-per-charge is given, because it
cannot be honestly derived. The draw figure it would need does not exist while
the machine is plugged in, and the machine was not unplugged to obtain one — it
was in use by its owner at the time. The battery's own registry entries report a
design capacity of 6,249 mAh at 12.45 V, which is roughly 78 Wh of stored energy,
but multiplying that by a wattage nobody measured would be arithmetic dressed up
as a measurement. To get the real number: unplug, run
`evie-shell --energy-check 60` while idle and again while generating, and the
watts line will populate itself.

**What the fan was actually doing.** This investigation began because the owner
heard his fan and asked whether it was Evie. At that moment three Adobe processes
were between them using more than two cores' worth of CPU while Evie's server sat
at 0.0%. The table above is the durable version of that answer.

### Measurements that live elsewhere

Related figures taken by other work, each traceable to where it was recorded, so
this document does not restate them from memory:

| Measurement | Result | Source |
|---|---|---|
| Note index load, binary format | 47 ms, 49.8 MB peak footprint, from a 22.9 MB file | commit `293fb29`, via `--index-check` |
| Note index load, previous JSON format | 789 ms, 151.0 MB peak, from a 57.0 MB file | commit `293fb29` |
| Prompt cache hit rate | 42% of prompt tokens served from the cached prefix, over the last forty requests | [Model strategy](MODEL_STRATEGY.md) |
| Endurance, after 1 h 39 m of use | 6.6–6.9 s for 128 tokens, no drift, no defect | `README.md` |
| Warm server physical footprint | 3,215 MB, at 65,536-token context | [above](#bounded-target-mac-sample--2026-08-04) |
| Wake listener, armed vs idle | measured per phase by `--wake-cost-check` | `EvieDiagnostics+AudioAndVoice.swift` |

### Repeating any of this

`evie-shell --energy-check [segundos]` prints the hardware, the power source, the
thermal state, the GPU range over a window, and the list of things this Mac will
not report without privileges. Run it once while nothing is happening and once
while a question is being answered; the difference is what a question costs.
The report is also written to `~/Library/Logs/Evie/energy-check.txt`.

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

The burst is now measured rather than assumed: a question takes the GPU from
about a fifth busy to about three-quarters busy and leaves the CPU at roughly one
core of ten, and ten questions in a row did not throttle this machine or move it
off `nominal` thermal state. See [Energy and heat](#energy-and-heat--2026-08-07)
for what that does and does not establish — in particular, no watt figure exists
for any of it, and the policies below are therefore still reasoned from
utilisation rather than from measured power.

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
