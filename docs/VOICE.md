# Voice architecture

Status: proposed and benchmark-gated.

## Target-Mac discovery — 2026-08-04

The target Mac already contains an inactive OmniVoice Studio 0.3.12 installation,
its Python/CLI environment, MLX Whisper, faster-whisper, sherpa-onnx, and cached
OmniVoice plus Whisper model assets. The Studio application was not running, and
the discovery did not inspect its database, logs, or any possible personal voice
reference. Evie can therefore reuse the installed command/model layer without
keeping the OmniVoice UI active or duplicating the known weights.

This is an inventory observation, not a performance result. No microphone was
opened, audio generated, voice profile inspected, or worker installed during the
spike.

## Goals

- Evie is pronounced "ee-vee"/"ívi".
- Push-to-talk works before always-listening wake-word mode is enabled.
- The user always receives visible listening/transcribing/speaking feedback.
- STT and TTS remain local in the baseline.
- Heavy voice models can unload while the UI stays available.
- Barge-in, cancel, mute, captions, and output-device changes behave safely.

## Input path

```text
shortcut or "Hey/Ei, Evie"
  -> local audio capture and VAD
  -> optional partial transcript for UI
  -> final local STT transcript
  -> supervisor intent/routing
  -> Hermes or deterministic action
```

The wake phrase should initially include a lead word such as "Ei, Evie" to reduce
accidental activation. A custom keyword model requires measured false accepts and
false rejects using the user's real microphone environments.

Raw audio is ephemeral by default. Explicit diagnostic mode may retain samples in
an ignored local directory with a visible indicator and cleanup control.

The preferred always-listening path is native `AVAudioEngine` capture feeding a
small `SoundAnalysis`/Core ML classifier trained specifically for “E aí, ívi” and
“Ei, ívi”, with a short RAM-only pre-roll and VAD. A third-party macOS app does not
receive Siri's private low-power hardware path: the microphone remains visibly
active and continuous energy cost must be measured. Mute must stop capture, not
merely discard samples.

Wake-word enrollment should collect roughly 40–100 varied positive utterances and
hard negatives, keep a held-out evaluation set, and pass both a false-reject target
and an 8–24 hour false-activation/energy test before default activation. The
initial target is at most one false wake in eight hours and below 5–10% false
rejects in the user's environments; these are proposed gates, not measured values.

## STT candidates

Hermes supports local faster-whisper plus arbitrary local command or Python
providers. The benchmark should compare:

- faster-whisper baseline, likely CPU-backed on this Mac;
- a current Apple-Silicon/MLX Whisper implementation through a custom command;
- tiny/base/small-class models for latency/quality;
- a larger model only if Brazilian Portuguese accuracy materially improves.

Tests include quiet speech, distance, fan/background noise, proper names, calendar
times, email addresses, English technical terms inside Portuguese, and the word
"Evie" itself.

Reuse the already cached MLX Whisper large-v3-turbo as the first PT-BR baseline.
Compare it with a pinned FluidAudio/Core ML challenger so STT/VAD/speaker
embeddings can use Apple-native execution rather than compete with Gemma on MPS.
No challenger is selected until real Brazilian Portuguese recordings establish
accuracy, cold/warm latency, memory, and energy.

Speaker recognition is optional enrollment, not model training and never action
authorization. Extract embeddings from several user-approved phrases, encrypt the
profile with a Keychain-backed key, delete raw audio by default, and expose a
one-step profile deletion. Replay and cloned speech mean a voice match may reduce
false wakes but cannot approve file deletion, messages, purchases, or any commit.

## Output path and OmniVoice

The upstream OmniVoice package exposes `omnivoice-infer` and a Python API separately
from its Gradio demo, and documents `device_map="mps"` for Apple Silicon. The Evie
baseline therefore does not keep the OmniVoice application or web UI open.

Phase 3 integration order:

1. command provider: private JSONL on stdin, audio file out, process exits;
2. supervisor-managed warm worker with a short idle timeout if cold latency is poor;
3. Hermes Python TTS provider only if streaming, model reuse, or voice enumeration
   justifies it;
4. sentence-level streaming/chunking after naturalness and cancellation are proven.

OmniVoice supports zero-shot voice cloning from a short clean reference. That is
the first personalization method; full training/fine-tuning is unnecessary unless
zero-shot quality fails. Reference audio and matching text are private runtime
assets outside Git.

Only voices the user owns or has permission to synthesize are in scope.

There are two independent profiles: the voice Evie uses for TTS (a short
OmniVoice reference/prompt) and the speaker embedding used to recognize the user.
Neither substitutes for the other. The installed batch CLI can read JSONL from
stdin through `/dev/stdin`; the adapter must keep private text/transcript content
out of argv, request offline model resolution from supported libraries, isolate the
child process group, and bound output paths, size, structure, and time. Cleanup is
best effort, so startup orphan cleanup remains required before activation.

`VOI-007` now implements that one-shot adapter in EvieCore. It additionally
requires an explicit local Hugging Face cache containing the separate
`eustlb/higgs-audio-v2-tokenizer` snapshot used by the inspected OmniVoice 0.3.12
installation, disables implicit hub tokens/telemetry and asks supported libraries
not to resolve over the network, and does not override the parent home directory.
Eight synthetic tests cover stdin privacy, permissions/best-effort cleanup,
missing/invalid/oversized output, missing tokenizer cache, timeout, cancellation,
and descendant termination. Environment flags are not a network sandbox, and the
configured executable remains trusted local code until a version/hash manifest is
verified. No model or personal voice was loaded, so naturalness and latency are
still wholly unmeasured.

For a future commercial distribution, recheck licensing: the current OmniVoice
model card is non-commercial even though the upstream code is Apache-2.0, and the
installed Studio code has its own AGPL terms. The present scope is private local
use.

## Latency model

Perceived response latency is the sum of:

- end-of-speech/VAD delay;
- final transcription;
- model cold or warm start;
- prompt prefill and first token;
- tool calls;
- first TTS chunk;
- audio buffer/playback startup.

Decode throughput alone does not predict voice experience. Approximately 20 text
tokens/s is normally ahead of natural speech if TTS can begin from early sentences.
Time to first useful audio is the primary metric.

## Cold/warm policy

- Wake word and audio metering: lightweight optional resident component.
- STT: load per utterance unless partial streaming requires a resident backend.
- OmniVoice on AC: initially retain for two minutes after use.
- OmniVoice on battery: exit after each completed response until measured otherwise.
- If TTS is still loading, show text/caption immediately and an honest loading state.
- The user can select text-only, automatic voice, or voice-on-request behavior.

## Barge-in and cancellation

Speaking while Evie is producing audio may:

1. stop playback immediately;
2. cancel pending TTS chunks;
3. start a new capture;
4. preserve the interrupted answer as a card;
5. decide explicitly whether the current agent/tool operation should also stop.

Outbound commit actions are not implicitly cancelled merely because playback stops;
their state must be reconciled and shown.

## Required benchmark outputs

- word/error observations on the Portuguese test set;
- wake-word false accept/reject rates;
- STT cold/warm latency and peak memory;
- OmniVoice cold/warm first-audio latency, real-time factor, peak memory, and unload;
- sentence chunk boundary quality;
- barge-in stop latency;
- battery/AC behavior;
- acceptable voice reference length and recording instructions.
