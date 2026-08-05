# Voice architecture

Status: the loop is closed. The microphone, speech recognition, and the spoken
answer all work. Wake word and call mode do not.

## The output path — 2026-08-05

`EvieSpeechOutput` synthesises each sentence to buffers and plays them through an
`AVAudioEngine`, rather than calling `speak()` and letting the system play. The
extra step buys the honest ring — a tap on the mixer gives the real amplitude of
what is audible — and makes swapping in a cloned voice later a change of where the
buffers come from and nothing else.

Measured on this Mac: first audio 0.42 s after the answer completed, 6.77 s of
speech, output level peaking at 0.656 across 149 published samples.

### Two failures worth remembering

**The engine must be built from the buffer's own format.** Connecting the player
before knowing it made the engine adopt the hardware's stereo layout, and a mono
buffer scheduled onto a stereo connection never plays — the wait for playback
never returned and the process hung with an idle main thread.

**`isSpeaking` cannot be read straight after `speak()`.** Synthesis happens first,
so the flag is still false; the visual state follows an `onStarted` callback
instead. Claiming she is speaking before any audio exists is exactly the dishonest
indicator this project refuses.

### The natural Siri voices are not available to third-party applications

`AVSpeechSynthesisVoice.speechVoices()` lists `com.apple.siri.natural.Sandra` and
`…Nando` at enhanced quality in `pt-BR`. Inside the signed bundle,
`AVSpeechSynthesisVoice(identifier:)` returns **nil** for both. Verified directly.

They are therefore filtered out of the picker rather than offered and then
failing. What remains is `com.apple.voice.compact.pt-BR.Luciana` — ranked first
deliberately, because the `eloquence` family are novelty voices that are fine to
choose and wrong to default to.

This is the concrete argument for a cloned voice. It is not a nicety here; it is
the only route to Evie sounding like anything other than a 2005 screen reader.

## The cloned voice — measured 2026-08-05

The local OmniVoice engine runs as a separate process on `127.0.0.1:3900`, started
and stopped by `Scripts/evie-voice`. It holds a 2.4 GB model resident, which is
why Evie does not start it herself: a heavy worker that starts itself takes a
resource decision away from the person whose machine it is.

Two profiles already existed on this Mac, both Portuguese clones, including one of
the user's own voice.

### Timings, warm model, this Mac

| Case | Audio | Synthesis | Ratio |
|---|---|---|---|
| Short sentence, 8 steps | 2.12 s | 2.99 s | 1.4× |
| Short sentence, 16 steps | 2.12 s | 4.03 s | 1.9× |
| Short sentence, 32 steps | 2.12 s | 7.39 s | 3.5× |
| Long sentence, 16 steps | 8.68 s | 9.63 s | 1.1× |
| Through Evie, first audio | — | **2.30 s** | — |

Two conclusions drive the implementation. Eight steps is the setting that keeps a
conversation moving. And the per-call overhead dominates short text — 1.9× for a
sentence against 1.1× for a paragraph — so **chunking by sentence is wrong for
this engine**. Evie synthesises the opening sentence alone, for a fast first word,
then everything after it in a single block.

### The thirty-seven second trap

A profile stored without its reference text costs a one-off Whisper pass to
transcribe the reference. Measured: **36.97 s** to first audio on a profile with
no `ref_text`, against 2.30 s on one that has it. `Scripts/evie-voice voices`
reports which profiles carry their text, and `warm` pays the cost up front.

### On training a voice instead of cloning one

Asked whether a voice could be *trained* once to save compute later, rather than
cloned from a reference every time. Three facts settle it:

- The profile already **is** the saved artifact. It is created once and stored as
  a database row plus a reference file; generation passes only a `profile_id`, and
  the reference is never re-uploaded. It can also be exported as a portable
  `.ovsvoice` bundle.
- Fine-tuning would **not** reduce the cost of speaking. The per-sentence expense
  is the diffusion, and a fine-tuned model runs exactly the same steps. Fine-tuning
  buys quality, at hours of GPU time and gigabytes of checkpoint.
- What genuinely reduces the cost is what is implemented: fewer diffusion steps,
  fewer calls, and keeping the model warm.

## What is implemented — 2026-08-05

`EvieAudioCapture` owns the microphone. `EvieSpeechTranscription` turns what it
hears into text using the system recogniser. Clicking the mark toggles listening,
push-to-talk holds it open, and stopping everything closes it.

### The blocker that had to fall first

A bare SwiftPM executable cannot obtain the microphone, and the failure is worse
than an error. Measured on this Mac: touching `AVAudioEngine().inputNode` from an
unbundled binary **hangs the main thread indefinitely** inside `coreaudiod`. TCC
identified the process by executable name, attributed the request to the terminal
that launched it, found no usage description to render in a dialog, and waited for
a decision that could never be made.

Three consequences, all now enforced by `Scripts/evie-app`:

1. Evie must be a bundle with a stable identifier and usage descriptions.
2. She must be launched through Launch Services. Running the executable *inside*
   the bundle from a terminal still attributes the grant to the terminal.
3. An ad-hoc signature loses the grant on every rebuild, because ad-hoc code has
   no stable designated requirement. A self-signed certificate fixes it.

The order in code matters too: `AVCaptureDevice.authorizationStatus` never blocks
and is safe to call first; `requestAccess` comes second; the engine is built
third; and the input node is touched only after access is actually granted.

### Speech recognition

The system recogniser was chosen over the cached Whisper checkpoints for one
reason above accuracy: **it runs in a system daemon, so its model never enters
Evie's address space** and never competes with the 26B model for the 24 GB of
unified memory that is the real constraint on this machine.

Measured on this Mac: recognition is available, 45 locales are supported including
`pt-BR` — and `pt-PT`, unusually — with `pt-BR` reporting `needsDownload`, meaning
supported with a one-time language pack. That download runs before capture starts
rather than lazily, so the first sentence anyone speaks does not vanish into it.

`SpeechModels.endRetention()` is called on both finish and cancel. That is the
idle unload the engineering contract requires of every heavy worker.

Its weakness is auditability: Apple's model revision cannot be pinned and changes
with the operating system. The published challenger is FluidAudio's Parakeet in
Core ML, at **6.14% WER and 141× real time** on Apple silicon — the best published
Brazilian Portuguese number found — with a pinnable revision, at the cost of one
to two gigabytes resident. `VOI-005` remains the gate that decides between them,
and no Brazilian Portuguese WER has been measured here.

### Not measured, not claimed

No audio has been transcribed. Accuracy in real rooms, latency after the language
download, barge-in behaviour, and energy cost are all unknown.

## Original research

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

## Echo, and the call mode

macOS provides real acoustic echo cancellation through the Voice Processing I/O
unit, which is what makes a continuous call mode possible without the speaker's
output being heard as the user's input. It is enabled per audio unit rather than
per application, and requires input and output to agree on a device. Where they do
not, the fallback is half-duplex: pause capture while speaking, and rely on the
level threshold to detect a genuine interruption.

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
