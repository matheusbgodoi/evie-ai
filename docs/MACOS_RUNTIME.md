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

Expected initial permissions:

- microphone for push-to-talk/wake word;
- user-selected file roots when file RAG is enabled;
- service-specific OAuth handled locally.

Deferred and separately brokered:

- Screen Recording for explicit screen analysis;
- Apple Events for specific target applications;
- Accessibility for future UI automation only.

Full Disk Access is not an initial requirement.

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
