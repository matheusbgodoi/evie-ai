# macOS shell and runtime research

Status: research record for Phase 2.

## Recommended shell

A native SwiftUI/AppKit shell is preferable to Electron for a small always-resident
overlay. The core building blocks are:

- `NSPanel` with a nonactivating style for the floating HUD;
- `NSHostingView` or a SwiftUI window bridge;
- floating window level and collection behaviors for Spaces/full-screen auxiliary
  presence;
- accessory activation/`LSUIElement` to avoid ordinary Dock behavior;
- native glass/materials, with `NSVisualEffectView` fallback;
- `MenuBarExtra` or status item for status and controls;
- `AVAudioEngine` plus Accelerate/vDSP for low-cost real waveforms;
- XPC between native shell and supervisor where practical;
- `SMAppService`/user LaunchAgent registration rather than root services.

The overlay is removed with `orderOut` when hidden; a transparent window must not
redraw continuously.

### Hiding a window does not stop SwiftUI animation — measured 2026-08-05

`orderOut` is a presentation change, not a signal to the SwiftUI render loop. On
this Mac, an overlay hidden with `orderOut(nil)` kept its `TimelineView` running
at 55 frames per second and burned about 2.5% of one core with nothing on screen.
`.opacity(0)`, `NSHostingView.isHidden`, `alphaValue = 0`, and
`setIsVisible(false)` are all equally ineffective; `.hidden()` stops the drawing
but leaves the tick running at roughly 1.4%.

Only two things actually stop it: `TimelineView(paused: true)`, or removing the
timeline from the view tree. Evie does the latter, and lowers the flag that
controls it *before* calling `orderOut`. Window occlusion is observed as well, so
another window dropped on top of the overlay stops the animation too. Note that
`canJoinAllSpaces` means switching Spaces produces no occlusion change, so an
explicit hide remains the primary signal.

### Animation cost, measured on this Mac

Release build, overlay visible, percentages are of one core.

| Technique | Cost |
|---|---|
| Idle with no timeline in the tree | ~0.1% |
| `rotation3DEffect` animated implicitly by Core Animation | ~0.65% |
| `Canvas` redraw with cached symbols, 12 fps | ~3.5% |
| `Canvas` redraw with cached symbols, 60 fps | ~5.9% |
| `Canvas` calling `context.resolve(Text:)` per glyph per frame | ~23% |

Two rules follow. Reduce the frame rate rather than the artwork: grid size barely
moved the number, because the cost is the canvas frame setup rather than the
glyphs. And never resolve `Text` inside a per-frame loop — declare the glyphs
through `Canvas(symbols:)`, which is worth roughly 6× on its own.

### Screen presence indicator cost — measured 2026-10-16

Release build of `evie-shell --presence-demo 8`, Apple M5 (Mac17,2), macOS 27.2,
Swift 6.4, one built-in display. `top -l 2 -s 5` on the demo process, second
sample, 1 s into each 8 s hold:

| State on screen | Process CPU |
|---|---|
| Seeing glow, after the sweep | 0.0% |
| Observing glow and reticle | 0.0% |
| Acting, after the click | 0.1% |
| Typing, chip dots looping | 0.0% |
| Paused | 0.0% |

The animations are interpolated by the render server, so this measures what the
indicator costs Evie's process, not WindowServer, which was not measured. The
cursor's travel (under a second) was too short for this method. After the
indicator hides, the demo reports zero visible windows: panels are closed, not
made transparent, so idle costs nothing.

### SwiftUI macros need Xcode, which is now selected

`@State` is a macro in the macOS 26+ SDK and its plugin ships only with Xcode.
Until 2026-10-16 this Mac had only the Command Line Tools, so it could not be used
and transient view state moved into observable objects. Xcode 27.1 is installed
and selected since 2026-10-16, and `@State` and `@Observable` compile; see
`AGENTS.md`. Custom shader effects are allowed but not needed; the `metal`
compiler also needs the separately downloaded Metal Toolchain component, which
was not installed on that date.

## Current development runtime

The first-test implementation deliberately stops short of the recommended service
architecture. `Scripts/evie-runtime` prepares a pinned TurboFieldfare checkout and
Gemma model outside Git, then exposes explicit doctor/health/start/stop/smoke/launch
commands. It creates no `SMAppService`, LaunchAgent, login item, or `KeepAlive`
process. The native shell still connects directly to loopback under ADR 0006.

Current local paths and constraints are recorded in
[ADR 0007](adr/0007-local-development-runtime.md). The server starts only on
request, validates port/model-owner conflicts, and can be stopped with a validated
`SIGTERM`; automatic restart, idle unload, power-state handling, and sleep/wake
recovery remain Phase 2 work.

On the base M5/24 GB target Mac running macOS 27, Apple Command Line Tools were
sufficient to build pinned TurboFieldfare release products. Upstream still
documents Xcode 26, so a full Xcode installation remains the portability fallback
if another environment cannot reproduce this local result. On 2026-08-04, the
upstream verifier passed all 37 model files and both synthetic response modes
completed at a declared 64K. After those small requests, the server's measured
physical footprint was 3,215 MB and the native shell's was 18 MB; this is first-test
evidence, not the full Phase 1 resource/energy benchmark.

## The Mac brain: LensVLM on demand (v2 S3, ADR 0015)

The `mac-local` profile's server is `mlx_vlm.server` (mlx-vlm 0.7.8, a uv tool;
the executable `~/.local/bin/mlx_vlm.server` is a script whose `#!` names the
tool's Python) serving `mlx-community/LensVLM-9B-OptiQ-4bit` from the Hugging Face
cache. It is not a persistent service: no LaunchAgent, no login item, no
`KeepAlive`.

- **Startup.** Only when a turn resolves to the Mac brain (after "Acordar o
  cérebro do Mac?" when the Mac fallback is "Perguntar"), with "Acordando o
  cérebro do Mac…" on the status line. `EvieLocalBrainLauncher` refuses when the
  port is held by anything but the configured server, when the executable is
  missing, or when free memory is under 8 GiB (2.4 GiB more while the voice
  engine runs); otherwise it starts `mlx_vlm.server --model <id> --host 127.0.0.1
  --port 38480 --max-kv-size 32768 --max-num-seqs 1` with a scrubbed environment
  and `HF_HUB_OFFLINE=1`, waits up to 90 s for `/health`, and checks that the
  listener is the process it spawned. `Scripts/evie-brain start` does the same by
  hand.
- **Shutdown.** After 10 minutes without a turn, when Evie quits, or
  `Scripts/evie-brain stop`: SIGTERM, SIGKILL after 5 s, only after the pid's
  image and argv were checked to be this server. A server left by a crash, or
  started by the script, is taken over at Evie's next launch and unloads the
  same way. Evie waits for the exit by suspending (`LocalBrainShutdown`), so the
  overlay keeps running while a server ignores SIGTERM; at quit she waits at
  most the 5 s grace and sends SIGKILL without waiting for it to land.
- **Cancelling a wake.** Cancelling the turn during "Acordando o cérebro do
  Mac…" cancels the start when no other turn is waiting for it
  (`LocalBrainWake`), and a server that has not answered `/health` yet is
  stopped, so its ~8 GB are not loaded for nobody. The next turn waits for that
  stop and starts afresh.
- **Idle cost.** Loaded and idle: footprint 8,243 MB, 0.3% of one core (`top`, 5 s
  sample). Unloaded: nothing — no process, no port.
- **Logs.** `~/Library/Application Support/Evie/Runtime/brain.log` (0600,
  appended, moved to `brain.log.1` past 10 MB at the next start) and `brain.pid`
  (0600) beside it, shared by the app and the script, with `brain.key` (0600):
  the key made for the running server (ADR 0017), removed when it stops. A
  server whose key file is gone, or one started by hand without a key, is
  refused ("… não confirmou a chave …"): `Scripts/evie-brain stop`, then let
  Evie or the script start it again. The server logs each
  request's token counts and timings, never the prompt.
- **Recovery.** `Scripts/evie-brain status` (pid, RSS, health), `health` (the
  server's `/health`), `stop`. A refused start says why on the status line; the
  log has the server's own error. "A porta 38480 está ocupada por outro processo."
  means something else listens there: `lsof -nP -iTCP:38480 -sTCP:LISTEN`.
- **Checks without the overlay.** `evie-shell --brain-check` runs the real
  launcher, one question with a 32×32 red PNG through the real client, and the
  stop; `--brain-check --idle` waits for the idle unload instead of stopping.

### Measured 2026-10-16

Apple M5 (Mac17,2), 24 GB, macOS 27.2, mlx-vlm 0.7.8, LensVLM-9B-OptiQ-4bit, the
weights already in the page cache from earlier runs that day (a cold read from
disk after a reboot was not measured).

| What | Result |
|---|---|
| `Scripts/evie-brain start` until `/health` answers | 5.4 s and 6.5 s |
| `EvieLocalBrainLauncher.ensureRunning` until `/health` answers | 6.35 s and 5.74 s |
| Footprint once loaded (`footprint -p`) | 8,148–8,243 MB |
| RSS (`ps`) | 443 MB just after the start, 2.7 GB later; Metal buffers are not in RSS |
| Free + inactive + purgeable before and after a start (`vm_stat`) | 8.27 → 3.85 GiB; swap used 1,928 → 3,654 MB |
| 32×32 red PNG, `enable_thinking:false`, non-streaming, total | 2.18 s, "vermelho", no reasoning |
| The same through Evie's client (streaming) | 2.27 s, 2.09 s, 2.04 s, "vermelho" |
| Idle CPU, loaded | 0.3% of one core |
| `Scripts/evie-brain stop` | 0.34 s; no process left (`pgrep -fl mlx_vlm` empty), port free |
| Port 38480 held by `nc -l` | script: "Port 38480 is held by another process"; launcher: "A porta 38480 está ocupada por outro processo."; `nc` untouched |
| Idle unload with the real 10-minute policy (`--brain-check --idle`) | port free 605 s after the last answer (idle clock from the start, checked every 30 s); no `mlx_vlm.server` process left |

From the lead's pre-check the same day: first text answer 6.69 s, a 1280 px
screenshot described in 14.11 s, peak 10 GB; tool calls come back as malformed
XML in the content, so the profile offers no tools.

Verified in the installed 0.7.8 source and live: `--max-kv-size 32768` shows as
`configured_context_limit: 32768` in `/health`, and a request needing more than
that (13 prompt + 40,000 `max_tokens`) is refused with 400 "Request needs 40013
context tokens … but MAX_KV_SIZE is 32768" — when `context_management: []` is
sent. Without it the server compacts automatically: it served that request by
clamping `max_tokens`, and for a prompt that does not fit it would summarize the
older messages with the model. Evie's requests to this server always send the
empty list. A top-level `enable_thinking:true` produced a `reasoning_content`
trace and `false` none; absent, the server passes its own default (off) to the
template, so the prompt was the same 25 tokens as with `false`.

## Wake-word candidates

### LiveKit WakeWord

Current first prototype candidate: native Swift package, Apache-2.0, macOS support,
ONNX/CoreML execution, and a custom multilingual training path.

### SoundAnalysis plus Core ML

Most Apple-native long-term option, but requires constructing and validating a
custom classifier and dataset.

### sherpa-onnx keyword spotting

Open-vocabulary alternative with Swift/macOS support and small int8-capable models.
It must be tested carefully for the Portuguese pronunciation and similar negative
words.

The selected engine requires an ADR after an eight-hour and then full-day false
activation test.

## Global shortcuts

Prefer a narrow global-hotkey library/API that does not observe all keyboard input.
The open-source Swift `KeyboardShortcuts` package is a prototype candidate and
supports key-down/up for push-to-talk. Avoid a global NSEvent monitor unless a
documented requirement justifies Accessibility/Input Monitoring.

## Audio ownership

The shell should be the only microphone owner so macOS permission and the orange
indicator clearly identify Evie rather than Terminal or Python. PCM can be streamed
to worker adapters. Output audio passes through the shell meter so speaking
animation reflects actual sound.

Voice processing/echo cancellation must be evaluated for barge-in while Evie is
speaking.

## Sleep and power

- Hotkey standby can stop microphone capture and all heavy workers.
- Voice standby continuously consumes some CPU and keeps the macOS microphone
  indicator active.
- A sleeping Mac cannot hear the wake phrase; Evie should not prevent normal sleep.
- Low Power Mode, thermal state, AC/battery changes, and Dispatch memory-pressure
  events inform lifecycle policy.
- Do not use periodic polling where notifications or process events exist.
- Heavy workers are on-demand and should not be configured as unconditional
  `KeepAlive` jobs.

## Permission plan

Permissions Evie holds or asks for, all attached to the signed bundle at
`~/Applications/Evie.app` (see "Signing, install and recovery" below):

- microphone, for push-to-talk, call mode and the wake phrase;
- speech recognition, declared in the Info.plist for the system recogniser;
- user-selected file roots when file RAG is enabled (Desktop, Documents and
  Downloads consent);
- Apple Events, for the Mail and Calendar applications only;
- Screen Recording, for "olha a tela" (v2 S4) — `NSScreenCaptureUsageDescription`
  is in the Info.plist;
- Accessibility and Post Events, for computer use (v2 S5). Neither has an
  Info.plist key, so the first-run guide is where they are explained.

Input Monitoring is not asked for. The computer-use takeover monitor (v2 S5d)
uses `NSEvent` monitors, which do not need it: verified 2026-10-16 (M5 24 GB,
macOS 27.2) that the 0xE71E tag on an event posted at `.cghidEventTap` reaches a
global `NSEvent` monitor intact, so no listen-only event tap is needed. A global
monitor sees key events only with Accessibility, which a session needs anyway.
Full Disk Access is not a requirement.

## Signing, install and recovery

Updated 2026-10-16 (v2 S7).

### Signing

`Scripts/evie-app build` signs only with the certificate whose SHA-1 is pinned
in the script, `E1CDAAB36B6D3B8B6FEB3E7D46BA020120524C9E` ("Evie Dev"). It looks
the name up in `security find-identity -v -p codesigning`, then signs with the
hash, so a second certificate with the same name cannot make the choice
ambiguous. A missing or different certificate fails the build before compiling;
there is no ad-hoc fallback any more, because an ad-hoc build loses every grant
on every rebuild and refuses every update.

After signing, the build asserts:

- `codesign --verify --deep --strict` passes;
- `codesign -d -r-` gives exactly Evie's designated requirement. Measured on
  2026-10-16 (Apple M5, 24 GB, macOS 27.2, Xcode 27.1): `designated => identifier
  "com.matheusbgodoi.evie" and certificate leaf = H"e1cdaab36b6d3b8b6feb3e7d46ba020120524c9e"`.
  A self-signed certificate is its own leaf, so the requirement names the leaf.
- `plutil -lint` accepts the Info.plist.

codesign's own output is no longer sent to `/dev/null`. The bundle has no
sandbox and no hardened runtime (`flags=0x0(none)`, no entitlements): reading
the accessibility tree and posting events need the sandbox off, and neither
grant needs the hardened runtime. `LSMinimumSystemVersion` is 26.0, matching
`Package.swift`.

**Why `Scripts/evie-app identity` never worked, and what was still wrong.** The
first cause is in `e2cebec`: the script passed `-legacy` to an `openssl` that is
LibreSSL and has no such flag, and sent both `openssl` calls to `/dev/null`, so
the p12 was never written and Evie stayed ad-hoc signed in silence. That fix
left the step depending on whichever `openssl` comes first on `PATH`. Measured on
2026-10-16 against throwaway keychains: a p12 exported by Homebrew's OpenSSL
3.6.4 is refused by `security import` ("MAC verification failed during PKCS12
import"), because OpenSSL 3 encrypts with AES-256 and PBKDF2 by default; the same
commands through `/usr/bin/openssl` (LibreSSL 3.3.6) import cleanly. The script
now calls `/usr/bin/openssl` by absolute path. `identity` is still needed — it is
the only way to make the certificate on a new Mac or after losing this one — and
it now prints the new SHA-1 and says that the pin has to be changed, and
committed, before `build` will use it. The scratch directory that holds the
unencrypted private key and the p12 is removed by an `EXIT` trap, so a failed
`security import` or a cancelled trust prompt no longer leaves the key under
`/var/folders` (fixed 2026-10-16; `EvieAppIdentityScriptTests` runs the step with
a stand-in `security`).

**Risk: recreating the certificate invalidates every grant.** TCC attaches each
permission to the designated requirement, and the requirement names the
certificate. A new "Evie Dev" is a different application to macOS: microphone,
speech, folders, Apple Events, Screen Recording, Accessibility and Post Events
all have to be granted again, and every copy signed with the old certificate
refuses updates signed with the new one. Back up the identity rather than
recreating it.

### Install and launch

- `Scripts/evie-app install` checks the built bundle's signature, stops any
  running Evie and waits up to 5 s for it to exit, copies the bundle with
  `ditto` to `~/Applications/Evie.app`, checks the installed copy's signature
  again, and opens it through Launch Services (`open`).
- Grant permissions to that copy only. `Scripts/evie-app run` opens the
  installed copy and refuses when there is none; it never launches the bundle in
  `.build`, which is rebuilt and deleted constantly, and two registered bundles
  with one identifier leave Launch Services free to open either.
- `Scripts/evie-runtime launch` no longer runs the bare SwiftPM binary; it hands
  over to `Scripts/evie-app run`. A bare binary started from a terminal is
  attributed to the terminal, which hangs the microphone and would give Screen
  Recording and Accessibility to Terminal.
- Since the v2 merge (2026-10-16) `launch` starts no model: the default profile
  is the PC, which never asks the loopback Gemma, and that server holds about
  15 GB. `Scripts/evie-runtime launch-custom` is the explicit way to have it: it
  checks that `config.json` has a `custom` profile at `http://127.0.0.1:38433/v1`
  (seeding the file first if it is missing) and refuses otherwise, starts the
  server, then runs `evie-app run` with `EVIE_MODEL_PROFILE=custom`. Measured on
  macOS 27.2 with a throwaway background bundle: an app opened by `open` sees the
  variables of the shell that ran `open` (and `open --env` adds more), so the
  choice reaches the installed Evie.
- `Scripts/evie-app import-pc-key` (v2 S2d) copies the PC gateway's key from
  `local-ai-3090` / `gateway-api-key` into Evie's own item,
  `com.matheusbgodoi.evie.model` / `pc-3090`, with `-T` naming the installed
  copy only, so it refuses before `install`. The key goes through a pipe, never
  an argument, and is never printed; see `docs/SECURITY.md`. The same copy is
  the "Importar da configuração do PC" button in Configurações › Cérebro.

### Recovery

When a grant is stuck, or was given to the wrong copy:

```bash
tccutil reset ScreenCapture com.matheusbgodoi.evie
tccutil reset Accessibility com.matheusbgodoi.evie
tccutil reset PostEvent com.matheusbgodoi.evie
```

then ask again from the guide. `tccutil reset All com.matheusbgodoi.evie`
resets everything, including the microphone and folders.

### First-run guide

`Sources/EvieShell/Onboarding/`. A checklist window, "Primeiros passos com a
Evie", opens at launch until it has been closed once; afterwards the same list is
Settings › Permissões. Rows: Microfone, Reconhecimento de fala,
Gravação de tela (with "reabra a Evie" — a running process keeps the answer it
got at launch), Acessibilidade, Controlar o teclado e o mouse (Post Events),
then Chave do PC and Cérebro, so a first launch sets Evie up without visiting
Configurações › Cérebro.

- Each row shows its live state with a distinct symbol per state, and one
  button. "Pedir" shows the system prompt; "Abrir Ajustes" opens the right
  Privacy & Security pane (`x-apple.systempreferences:com.apple.preference.security?Privacy_…`;
  Post Events lives under Accessibility).
- `CGPreflightScreenCaptureAccess`, `AXIsProcessTrusted` and
  `CGPreflightPostEventAccess` answer only yes or no, and macOS shows each prompt
  once. So "Pedir" is offered until it has been pressed once, and the guide
  remembers that in `~/Library/Application Support/Evie/permission-guide.json`
  (mode 0600, next to `preferences.json`), with whether the window was closed.
  A missing or damaged file shows the guide again; nothing else depends on it.
- Rows are read again whenever Evie becomes active, which is what coming back
  from System Settings does. There is no polling, because macOS posts nothing
  when a privacy switch changes.
- A copy that is not bundled shows the state and no buttons: TCC would give the
  permission to the terminal.
- The decisions — which button a state offers, the deep links, the record — are
  in `Sources/EvieCore/EviePermissionGuide.swift` and tested in
  `EviePermissionGuideTests`. The probes and the window are in the shell and have
  no automated test; see the manual QA below.

**The two brain rows (S7, 2026-10-16).** Their rules and buttons are EvieCore's
(`Sources/EvieCore/EviePermissionGuide+Brain.swift`, tested in
`EviePermissionGuideBrainTests`); the shell's `PCKeyItem` and
`BrainConnectionItem` only put them in the list, and
`PermissionGuideRow.Action.Kind` gained `.importPCKey` and `.testConnection`.

- **Chave do PC** shows "Salva" / "Sem chave" from an attributes-only query of
  the PC profile's item (`EvieModelKeys.status(of:)`, never the secret, so it
  never prompts and runs on every refresh). Its key is the PC profile's even
  while the Mac brain is in use (`EvieLoadedConfiguration.pcKeyProfile`), since
  a missing key is the usual reason for that. "Importar" is
  `EvieModelKeys.importPCConfigurationKey(into:)`, with
  `EvieModelKeys.importPromptExplanation` — the sentence Settings shows — as
  the row's hint before it is pressed. A failure (no `local-ai-3090` item, a
  refused prompt) is shown in the row and the button stays, since a keychain
  prompt, unlike a privacy one, can be shown again. To paste a key by hand, the
  row points at Configurações › Cérebro.
- **Cérebro** runs `ModelReadinessProbe.connectionReport(for:)` on the profile
  in use and shows the three steps on one line with their times, then the
  report's summary. An unloaded model counts as set up ("Descarregado" on the
  PC, "Acorda ao perguntar" on the Mac); no key, a refused key, an unknown model
  or no answer are marked refused. The result is kept for the exact profile it
  measured, so a settings save that changes the brain shows "Não testado"
  again, and the test stays on offer.
- A key saved from either place (`AppCoordinator.modelKeySaved`) refreshes the
  readiness cache, drops the Cérebro result, re-reads the guide and the
  Cérebro tab's key status. While a row's button runs, it is disabled with a
  spinner (`PermissionGuideViewModel.busyRows`).

**Config seeding (done with S2a, on `v2`):** `Scripts/evie-runtime configure`
writes schema v2 when the file is missing — the two built-ins, then the Gemma it
serves as `custom`, outside the preference order. A test runs the script and
checks the file against `EvieModelProfileSet.builtIn`.

**Manual QA, not yet run** (it needs the app launched, which grants and prompts
on the owner's Mac): install, then rebuild and install twice and confirm the
grants survive; a first run against an empty `~/Library/Application Support/Evie`;
each row's "Pedir" and "Abrir Ajustes", including that each deep link lands on
its pane on macOS 27; "Importar" on a fresh install (the prompt names
`local-ai-3090`, "Permitir" is enough, the row turns "Salva") and then "Testar
conexão" with three green steps.

## Phase 2 spikes

1. Overlay/hotkey/cards with simulated events and no backend.
2. Microphone permission, waveform, cancel, and multi-device behavior.
3. Wake-word engine comparison with false-positive and energy measurements.
4. XPC/process lifecycle through login, rebuild, sleep/wake, crash, and unload.

Prototype targets:

- overlay visible within 100 ms of shortcut/wake event;
- no polling loop;
- no heavy worker in hotkey standby;
- shell/supervisor below 150 MB RSS without wake word;
- wake stack below 300 MB and below 2% average CPU as targets to validate;
- no raw audio retained by default;
- workers unload on memory pressure and do not prevent system sleep.

## Bounded MLX allocator adapter (2026-10-17)

`LocalRuntime` accepts optional `kv_bits`, `prefill_step_size`, and
`metal_cache_limit_mb`. Missing fields decode as nil and preserve the legacy
launch. KV quantization and prefill size are public upstream CLI flags. The
allocator cache is separate from the model KV cache: its limit is applied with
public `mlx.core.set_cache_limit` before the unmodified installed CLI runs.
The custom profile-runtime JSON adapter also persists all three optional fields.
Real `EvieConfigurationStore.save` → JSON → `EvieConfigurationLoader.loadProfiles`
regressions cover both complete bounded controls and legacy files without them.

A bounded launch reads the CLI's absolute Python shebang and executes that
interpreter with `-I -c <exact bootstrap> <CLI path> <cache bytes> <server flags>`.
It refuses env/PATH shebangs or interpreter flags. It adds no PYTHONPATH, worker,
dependency fork, or inherited server settings. The app's existing minimal,
authenticated, offline environment remains in force.

Process identity and reuse are separate checks. Stopping an owned server accepts
the exact wrapper or its legacy executable/interpreter form, on the configured
loopback port. Reuse additionally checks model, KV cap, one sequence, KV bits,
prefill size, and allocator limit. A changed profile must not silently reuse the
previous process. Modified inline code is not the owned wrapper.

`Scripts/evie-brain` supports the same optional controls through
`EVIE_BRAIN_KV_BITS`, `EVIE_BRAIN_PREFILL_STEP_SIZE`, and
`EVIE_BRAIN_CACHE_LIMIT_MB`. Its manual recovery default remains 32K with no
optional controls; it does not read or update the installed app's profile. For
example, the measured 64K configuration can be started manually with:

```sh
EVIE_BRAIN_MAX_KV=65536 EVIE_BRAIN_KV_BITS=8 \
EVIE_BRAIN_PREFILL_STEP_SIZE=512 EVIE_BRAIN_CACHE_LIMIT_MB=256 \
Scripts/evie-brain start
```

The short Swift/zsh bootstrap bridge is protected by an actual script launch
parity test, including exact argv and the scrubbed environment. The script
recognizes an existing bounded server for status/stop even when its current
manual configuration differs. It never accepts arbitrary `-c` code.
The real-process regression also covers macOS's Xcode Python shim, which
reexecutes with the `Python` framework executable name: the exact wrapper is
stopped with SIGTERM, while modified bootstrap code is left running. The focused
bounded-runtime/script run passed 15 tests in two suites (1.156 seconds).

A separate probe executed the exact production bootstrap against the installed
MLX and absolute Python, without loading a model. It confirmed a 268,435,456-byte
allocator limit, intact CLI argv, and isolated Python mode. The installed MLX
has no `get_cache_limit`: the probe observed the previous limit returned by a
second `set_cache_limit` call. Context, quality and headroom qualification are
recorded separately in `MODEL_TUNING.md`; allocator API correctness alone does
not qualify a larger context.


## Bounded Mail queries and OS integration tests

Mail's `messages of inbox whose ...` can materialize the entire mailbox before
filtering. A real main-thread sample showed `NSWhoseSpecifier` →
`MFSpecialMailbox.messages` → synchronous library/SQLite work. Killing the
`osascript` caller did not cancel that queued work in Mail, so later account
queries could exceed their unchanged 10-second test deadline. A normal Mail
quit succeeded; Mail was reopened in the background to preserve its prior
running state. No message, account or draft was changed.

Both `read_mail` (including unread filtering) and `search_mail` now use indexed
inbox windows: at most 80 candidates, 20 returned snippets and one subject-only
lookahead. Subjects/read-status arrive in one explicitly bounded range instead
of one AppleEvent per candidate. At the tail, at most seven binary probes find
the last existing position; only missing-index errors -1719/-1728 mean end of
window. Authorization, timeout and unexpected database errors propagate. Bodies
are read only for matches. Optional zero-based `offset`
continues a page; only a successful lookahead emits `next_offset`. The maximum
addressable position is 10,000. Every result explicitly describes partial scope,
even with no matches or no continuation. New arrivals can shift positions;
this is bounded live pagination, not a transactional mailbox snapshot. Old
protocol conformers retain first-page compatibility and explicitly reject
unsupported continuation.

The final real script boundary completed synthetic no-match searches at offsets
0/80 in 2.483/2.427 seconds, with 80 scanned candidates and next offsets 80/160.
A final partial window examined five candidates and returned no continuation in
1.242 seconds. The actual out-of-range error was -1719; an offset beyond this
mailbox returned an empty window. Cold body reads took longer (7.713 seconds
for one unread result, 3.920 seconds for one all-mail result); the application's
existing 90-second ceiling is unchanged. Only counts, cursor metadata and exit
status were recorded; no subjects, bodies or addresses entered evidence logs.
Both scripts also passed the system AppleScript compiler.

Hostile-input integration cases keep all payloads and their original deadlines.
The suite runs serially because its cases address shared Mail/Calendar processes
and the OS compiler; no retry, assertion weakening or blanket skip was added.
The final full run passed 1,542 tests in 145 suites in 23.807 seconds, including
all hostile-input cases and the new pagination regressions. One preexisting
known-issue test deliberately verifies that an interrupted hostile-input run
is reported rather than counted as successful coverage.

The signed Evie app's Automation grant is separate from the terminal/editor
responsible for `Scripts/test`. After a UI audit opened Calendar, its host-level
grant was absent: the unchanged ungated witness case reached its 10-second
ceiling, and the grant-gated completion case reported its unmet precondition.
Calendar had no sheet, popover or modal window and accepted a normal quit,
restoring the original closed-app precondition without granting the test host
new privileges. The closed-app test branch verifies the early marker and no
side effects; the installed Evie's own permission audit remains separate
evidence. Following indentation-only normalization, both Mail programs passed
`osacompile`, strict Swift formatting and the global whitespace check. The
Mail/pagination/agent-focused run passed 51 tests in four suites (23.999 seconds).


## Recognition without accelerator or linguistic assets

The full-package CI exposed two real host differences: Vision's automatic OCR
route threw `e5rt_e5_compiler_compile`/11 on the virtual runner, while Portuguese
linguistic tagging returned insufficient classification and left question grammar
among retrieval terms. Neither failure was converted into a skipped assertion.

`EvieDocumentReader` keeps accurate recognition, language correction, minimum
text height and line confidence. It first uses Vision's normal device choice;
a non-cancellation failure may take one alternative CPU route. The reader asks
`supportedComputeStageDevices` for each stage and assigns only a reported CPU
with public `setComputeDevice(_:for:)`. A missing CPU or second failure throws;
no empty successful page is invented. Cancellation is checked before and after
recognition and never starts the alternative route. Successful fallback adds
an observation warning. The explicit `cpuOnly` policy exercises the same public
CPU path locally and does not change the default's accelerated performance.
The public API contract is documented by [Apple](https://developer.apple.com/documentation/vision/vnrequest/setcomputedevice(_:for:));
the Swift `RecognizeTextRequest` signatures were also verified in the macOS 27 SDK.

Retrieval now applies a deterministic grammar supplement to both tagged tokens
and the missing-tagger fallback. It retains the original subject-word spelling
when a real lemma is unavailable; it does not guess conjugations or invent
lemmas. An empty-schemes real `NLTagger` reproduced `tenho`/`quanto` leaking into
the query before the fix. That regression then passed alongside the existing
Portuguese question, lemma, plural and auxiliary assertions.

The original OCR assertions now run on both automatic and forced-CPU policies:
Portuguese accents/currency, per-line confidence, small text, blank pages and
scanned PDFs. Additional tests force the automatic route to fail and then run
actual CPU OCR on the same synthetic page, verify one alternative only, preserve
CPU errors and reject cancellation. These local results validate the CPU route;
a fresh hosted CI run remains the evidence for the runner's automatic fallback.

For TCC audits, launch the installed bundle with Launch Services:
`open -n -a ~/Applications/Evie.app --args --permissions-check`. Directly running
its Mach-O from a terminal can inherit the command-line responsible process and
report different grants. The fresh Launch Services report matched the normal
Evie guide: microphone, speech recognition, screen recording, Accessibility and
post events granted; Mail/Calendar Automation OSStatus 0. The Mail consent was
accepted through the guide's own request and the OS's Evie→Mail alert. Existing
Calendar/Speech grants required no new prompt. Calendar was closed normally
after that audit to restore the original test-host precondition; no privileges
were granted to the terminal and no mailbox or calendar content was inspected.
