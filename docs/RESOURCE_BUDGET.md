# Resource and standby budget

Status: installed Evie 2 candidate measurements on the target M5/24 GB Mac,
followed by dated historical benchmarks and planning targets. Scope and units
are stated for each measurement; process footprint is not a whole-machine or
battery-watt measurement.

## Installed Evie 2 candidate — 2026-10-17

Measured from the signed installed candidate 5 executable, SHA-256
`99620b81b290e74f18c9945d37e390fe94d82e0420869eff520b821e3aa31997`.
Environment: Mac17,2, Apple M5, 10 cores, 24 GB, macOS 27.2 (26B5086k), AC power,
battery 80%, Low Power Mode off. Other applications/services were preserved.
These measurements are a dated candidate-5 checkpoint. The later public-URL
Shortcuts integration changes native dispatch; it does not turn these samples
into a new binary's energy benchmark. Actual Shortcuts invocation is recorded
separately in [NATIVE_APPLE](NATIVE_APPLE.md).

The subsequent installed candidate 6 has SHA-256
`129d1878a0e0b948a35c26ee9e7b25ad989c0152b7102ab875fa57391a34cb7a`.
It passed the complete 1,555-test / 147-suite package in 14.241 seconds, the
15 controlled coordinator lifecycle cases, and fresh Launch Services native
voice and real wake-listener lifecycle checks. Synthesis produced 58,599 frames
(2.65755 seconds) in 0.371844916 seconds. Those checks qualify native function,
not themselves CPU/energy measurements. The fresh normal-app sample below is
separate. The Lens client, worker lifecycle and idle
policy were unchanged; the resource and 632.480-second actual unload evidence
below retain candidate 5's hash and measurement scope.

### Final bundle8 normal app — 2026-10-17

Executable SHA256 `318d41287f1a32aa2b0f7a073d371d914160c7109f1591e2e09558d85096a305`.
After all three final installed PC diagnostics passed, the normal app was reopened.
Actual AX showed Qwen/PC ready, Automatic selected and agent available. The draft
was empty by character count; no task, fixture, capture review, Settings window
or security prompt remained. The empty overlay was hidden safely. Enabled native
voice defaults stayed configured; no model request started during the sample.

On the same M5/24 GiB/macOS27.2/AC setup, a fresh **30.005-second** kernel sample
measured **0.3043 CPU-seconds**, **1.014% of one core**, **108.47 MiB physical
footprint** and **187.31 MiB lifetime peak**. Peak includes earlier work in that
normal process and is not a steady-state allocation. The sample does not assign
shared speech-daemon costs or establish battery watts/autonomy. Earlier Lens
unload and voice measurements below keep their own executable/date scope.

### Candidate 6 normal app

After all three real Shortcuts completed, editors were closed and the normal
installed process remained in the background with no overlay or capture review.
A fresh **30.002-second** kernel sample measured **0.4167 CPU-seconds**,
**1.389% of one core**, **96.39 MiB footprint** and **98.89 MiB lifetime peak**.
No model request was initiated; the legitimate unresolved Keychain alert was
left untouched. The same process-accounting limits apply: no attribution of
shared speech services and no battery-watt or autonomy claim.

### Candidate 5 normal app and native wake listening

The normal app was measured for 30.004 seconds before stopping it for isolated
checks. Wake listening and the requested enabled defaults remained configured.
The kernel accounted **0.3762 CPU-seconds**, **1.254% of one core**, a final
**97.31 MiB physical footprint**, and **97.78 MiB lifetime peak**. These are
`proc_pid_rusage` deltas and footprint, not `ps` lifetime CPU averages or RSS.
No model request was initiated during this window. A legitimate unresolved
Keychain consent was left untouched.

A separate installed diagnostic then compared three phases with 48 kHz mono
input, without the normal interface/coordinator. Both listening phases were
confirmed armed. Its memory therefore describes the diagnostic process rather
than the complete normal app.

| Phase | Wall time | CPU, % of one core | CPU time | Final process footprint |
| --- | ---: | ---: | ---: | ---: |
| Nothing armed | 31.4 s | 0.01% | 0.004 s | 15 MiB |
| Listener without gate | 30.1 s | 1.87% | 0.563 s | 17 MiB |
| Listener with the default gate | 30.1 s | 1.76% | 0.529 s | 17 MiB |

The gate fed 198/299 buffers (66.2%), with one opening and 100 ms buffers in this
room. This single window does not establish a general battery-saving ratio;
background sound, native service caches and phase order affect it. The figures
are the Evie process's own accounting; shared macOS speech services are outside
that ledger and cannot be wholly attributed to Evie. Raw recognised text and
level traces were excluded from published evidence.

### Energy observations

Over a separate 30-second window (29 GPU samples), machine-wide GPU utilization
was **9–36%, mean 16.2%**. Thermal state stayed **nominal**. These shared GPU
figures include other applications and are not attributed to Evie. AC battery
current was 0 A; no total or per-process watt figure was available without
privileged tooling. No power, fan-speed or temperature reading was invented.

### On-demand local model

After its two synthetic visual requests completed, the owned LensVLM process
was sampled for 30.009 seconds while waiting for its real idle policy. It used
**0.0938 CPU-seconds / 0.312% of one core**, with **8,289.15 MiB footprint** and
**9,230.49 MiB lifetime peak**. This is a short image workload at the configured
131,072-token capacity, not a full-window memory test. Long-window qualification
and its different peak are recorded in [MODEL_TUNING](MODEL_TUNING.md).

The same installed bundle then passed the complete `--brain-check --idle`
sequence in **632.480 seconds**. It started its own worker in **3.684 seconds**,
answered the synthetic red image exactly in **2.222 seconds**, and read the
pixel-only `ZEBRA4817` code exactly through the actual client/image preparation.
The unchanged ten-minute idle policy unloaded the worker after **624.756
seconds**, including its periodic idle check. Final cleanup took **6.25 ms**;
both the diagnostic and an independent OS check confirmed that the owned PID
was gone (ESRCH, not a zombie) and its loopback port was free. The normal app was
then reopened; unrelated model services were preserved. This verifies actual
memory-worker release rather than treating a successful HTTP response as unload.

### Boundary checks on that same bundle

In-process App Intents `perform`/bounds and generated 3-action/3-shortcut
metadata passed. Actual system discovery passed later, but direct system
dispatch failed for the local signature (ADR 0029); these checks do not
override that failure. Native synthesis, cancellation,
SpeechAnalyzer round-trip and temporary calibration passed with the enhanced
Luciana voice. Wake lifecycle interruption/disarm passed without reopening a
stale microphone. All five required native grants were present, with Mail and
Calendar Automation OSStatus 0 via Launch Services. Calendar was closed normally
after inspection. The real public-web check passed in 3.125 seconds: six search
results, 12,000 bounded page characters and ten synthetic forbidden destinations
rejected. No user message, mailbox, calendar entry or raw microphone text was
included in published evidence.

Historical benchmark questions, and where each is answered:

- **What does it cost to leave her open?** [What it costs to leave her open](#what-it-costs-to-leave-her-open--2026-08-07).
- **What does it cost to ask her something?** [Ten questions back to back](#ten-questions-back-to-back--2026-08-07).
- **Does it heat the machine or drain the battery?** [Energy and heat](#energy-and-heat--2026-08-07).

## Historical benchmark machine

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
— Adobe Creative Cloud, Google Chrome, and a Terminal running the measurement. This
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

**Battery life** was the gap this section used to declare, and it is now measured.
See [On battery](#on-battery-what-a-question-actually-costs--2026-08-07) below.

### On battery: what a question actually costs — 2026-08-07

Every figure above this line was taken on mains power, where the battery reports
`Amperage = 0` and no wattage exists. The owner unplugged the machine so the one
number the document could not produce could be produced.

**The register refreshes about every 22 s, and this was got wrong first.** Watts
are `|Amperage| × Voltage` from the `AppleSmartBattery` entry in the IO registry.
`Amperage` is a two's-complement negative while discharging and must be read as a
signed 64-bit value; taken unsigned it reads as about 1.8×10¹⁹, which is the first
thing anybody reproducing this will hit. The second is subtler: **the register does
not update at 1 Hz.** Logged raw, it holds one value for around 22 seconds and then
jumps. A first pass at this measurement sampled at 1 Hz and reported "88 and 99
samples", which was oversampling — those windows contained about five independent
readings each, and a median over them is a median over repeats, not over evidence.
That pass has been replaced by the figures below and its numbers should not be
quoted. On top of that, the register sometimes reports `Amperage = 0` while
genuinely on battery, which is indistinguishable from being plugged in.

**Method, corrected.** Keep only distinct readings, weight each by how long it
stood, and cross-check the result against `RemainingCapacity` — the mAh the
battery itself says it lost over the same window. Windows are 300 s rather than
100 s so that several independent readings fall inside one. Load is the same shape
as the ten-question run above: one-paragraph general-knowledge questions in
Portuguese, capped at 220 completion tokens, non-streaming, one at a time.

**Conditions.** Adobe Creative Cloud, which dominates every AC measurement in this
document, was **quit** for this run. What remained was Chrome, Obsidian, Terminal
and the terminal process taking the measurement — the last of which was the
largest single consumer and cannot be removed, since it is the thing doing the
measuring.

| Battery 71% → 66%, Low Power Mode off | Idle | Generating |
|---|---:|---:|
| Draw, time-weighted | **5.6 W** | **31.1 W** |
| Distinct readings / window | 6 in 300 s | 7 in 450 s |
| Cross-check from mAh lost | 1.9 W (13 mAh) | **27.2 W** (282 mAh) |
| Thermal state | moderate | moderate |
| CPU throttling (`pmset -g therm`) | none recorded | none recorded |

**A question costs about 25.5 W on top of what the machine already spends.** The
two methods agree under load — 31.1 W against 27.2 W — and disagree at idle, where
13 mAh over five minutes is at the resolution limit of a register that moves in
coarse steps. The idle cross-check is therefore reported and not relied on. The
load cross-check, integrating 282 mAh, is the stronger of the two figures.

**The marginal cost reproduced across two differently-loaded machines.** The first
pass, with Adobe running, put idle at 20.0 W and generating at 44.6 W — a
difference of 24.6 W. This pass, with Adobe quit, puts them at 5.6 W and 31.1 W —
a difference of 25.5 W. The baselines differ by a factor of three and the
difference between them agrees within 4%. That is the strongest evidence in this
document that the marginal figure is Evie's and not the machine's.

**Adobe cost more at idle than half a question costs while generating.** Quitting
it took idle draw from 20.0 W to 5.6 W. On this battery that is the difference
between about 3.5 hours and about 12.6 hours of doing nothing.

**Throughput does not drop on battery.** A clean 32-question run — no sampler
competing — produced 4,940 tokens in 273.6 s: **18.1 tok/s**, 8.55 s and 154
tokens per question. The AC figure for the same shape of work is 18.2 tok/s.
Unplugging costs nothing in speed.

**It does drift under sustained load, and further than the AC run suggested.**
Across those 32 questions the first quarter ran at 19.4 tok/s and the last at
16.7 — a **13.9% decline**, against the 7.3% recorded over ten questions on AC.
`pmset -g therm` recorded no thermal or performance warning level at any point and
`ProcessInfo.thermalState` stayed at `moderate`, so whatever this is, macOS does
not call it throttling. It is a drift and not a cliff; question 32 was still
faster than question 30. Two earlier runs in this session reported 23.2 and
14.2 tok/s and are not quoted, because a watt sampler was spawning `ioreg` beside
them and neither figure is clean.

**Questions per charge.** This battery's `FullChargeCapacity` is 5,873 mAh at
about 12.0 V — **70.6 Wh**, after 20 cycles, against a design capacity of 6,249
mAh. At 25.5 W marginal and 8.55 s per question, one question costs **218 J, or
0.061 Wh**. A full charge therefore holds roughly **1,160 questions** of marginal
cost, and **fifty questions in a day cost about 4.3% of the battery**.

Three things that number is not:

- **It is marginal, not total.** It excludes the 5.6 W the machine spends whether
  Evie exists or not. Total endurance while generating without pause would be
  70.6 Wh ÷ 31.1 W ≈ 2.3 h, but nobody generates without pause, which is why the
  marginal figure is the one quoted.
- **It assumes this shape of question** — about 154 completion tokens. A long
  answer costs proportionally more time and therefore more energy.
- **It still is not a clean-room figure.** The 5.6 W baseline includes the
  terminal process that took the measurement, and a genuinely idle Mac would be
  lower still.

**A weakness in `--energy-check` that this run exposed.** The command samples GPU
at 1 Hz across its window but reads watts only at the start and at the end. Its
first battery run printed 37.4 W for an "idle" window whose median, sampled 88
times a few minutes later, was 20.0 W. Two endpoint samples cannot separate a
busy machine from a quiet one, and the tool should reduce watts over the window
the way it already reduces GPU. Until it does, the wattage lines it prints are
instantaneous samples and should be read as such.

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
