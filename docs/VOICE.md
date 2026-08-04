# Voice architecture

Status: proposed and benchmark-gated.

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

## Output path and OmniVoice

The upstream OmniVoice package exposes `omnivoice-infer` and a Python API separately
from its Gradio demo, and documents `device_map="mps"` for Apple Silicon. The Evie
baseline therefore does not keep the OmniVoice application or web UI open.

Phase 3 integration order:

1. command provider: text file in, audio file out, process exits;
2. supervisor-managed warm worker with a short idle timeout if cold latency is poor;
3. Hermes Python TTS provider only if streaming, model reuse, or voice enumeration
   justifies it;
4. sentence-level streaming/chunking after naturalness and cancellation are proven.

OmniVoice supports zero-shot voice cloning from a short clean reference. That is
the first personalization method; full training/fine-tuning is unnecessary unless
zero-shot quality fails. Reference audio and matching text are private runtime
assets outside Git.

Only voices the user owns or has permission to synthesize are in scope.

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
