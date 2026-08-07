# Voice architecture

Status: the loop is closed. The microphone, speech recognition, call mode, and the
spoken answer all work. The wake phrase is implemented, measured, and off by
default; the one check that matters for it has not been run.

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

The local OmniVoice engine runs as a separate process on `127.0.0.1:3900`. It
holds a 2.4 GB model resident, which is why it does not come up at login: a heavy
worker that starts itself takes a resource decision away from the person whose
machine it is.

**Corrected 2026-08-06.** That reasoning stands; where the decision was read from
was wrong. Nothing in the application ever started the engine, so choosing a
trained voice in settings did nothing audible, the log file did not exist, and a
crash was indistinguishable from a process that had never run — which is how an
evening was spent looking for the wrong bug. Choosing a trained voice *is* the
decision, so that is the trigger now: never at login, never for a system voice.
Failing to start says why and falls back to a system voice rather than falling
silent. Verified with `--voice-engine-check` against a stopped engine: up in
6.66 s with both trained profiles found. `Scripts/evie-voice` still starts and
stops it by hand.

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

Eight steps is the setting that keeps a conversation moving. The other conclusion
drawn here — that the per-call overhead dominates short text, so chunking is wrong
for this engine — was **wrong, and the reason is the next section**. The overhead
was not the engine.

### The reference transcript, and the twelve seconds nobody was paying for

A cloned voice whose `ref_text` is empty makes the backend run Whisper over its
reference recording **every time it speaks**. Not once. Every phrase. Measured on
this Mac with the same phrase:

| Profile | Time |
|---|---|
| Designed voice, no reference audio | 1.5 s |
| Cloned voice, `ref_text` empty | 19.1 s |
| The same voice, `ref_text` stored | 1.7 s |

Twelve seconds of speech went from 20.4 s to 3.4 s — four times slower than real
time to three times faster. The engine was never slow.

An earlier measurement of the same fault recorded 36.97 s to first audio against
2.30 s, and blamed a one-off Whisper pass. It is not one-off. That is the
correction.

A voice trained through Evie carries its transcript already; one made in the
engine's own application does not, which is where the affected profile came from.
Evie now fills in any that are missing, once, when the engine comes up — a single
Whisper pass over a ten-second clip, measured at 7 s, ever — and says which voices
it prepared, because a voice silently becoming ten times faster is worth a
sentence. The `PUT` that stores it takes JSON, not the multipart its neighbouring
endpoints take: multipart is rejected with 422, measured.

### Blocks, pipelined

With the fixed cost understood, the answer is spoken in blocks bounded at 280
characters — roughly fifteen seconds of speech for about 3.9 s of work. The fixed
part of a call is about 1.5 s, plus 0.16× the audio produced, both measured.

Before that bound existed, everything after the opening sentence went into one
enormous synthesis, and a two-thousand-character answer produced the first
sentence and then silence: when the big block did not come back, the loop skipped
it without a word. A block that fails now says so.

The loop also waited for a block to finish playing before starting to synthesise
the next, so every gap between blocks was the whole cost of the next one. Reported
from outside as "pausas longas de 5 ou 6 segundos do nada", which is exactly what
a serial loop sounds like. Each block is now synthesised while the previous one
plays; synthesis takes roughly a quarter of the time a block takes to play, so
overlapping them removes the gap rather than shortening it. The prefetch is
unstructured, so cancelling its parent does not reach it — `stop()` cancels it
explicitly, or it would finish a synthesis nobody is waiting for and hold the
engine busy for the next thing that is.

### Silence trimming

Every synthesised phrase carried a little silence at each end. Sensible for one
phrase, and the reason two played back to back have a gap neither sentence asked
for. `EvieSilenceTrim` removes it, leaving 40 ms in place so a plosive does not
start with a click. Silence *inside* a phrase is left alone: that is punctuation
being spoken.

### Designed voices cost less than cloned ones

A profile can also be created from a description rather than a recording:
`kind='design'` with a controlled vocabulary — gender, age, pitch, style, accent —
and the backend renders its own reference. Free text is rejected; "warm and
friendly" is not a value the engine knows.

Measured, warm, for a two-and-a-half-second sentence at eight steps:

| Profile | Synthesis |
|---|---|
| Evie Enérgica (designed) | 0.69 s |
| Evie Serena (designed) | 0.69 s |
| Evie Companheira (designed) | 1.52 s |
| matheus-voz-v2 (cloned) | 1.50 s |

All of them are faster than real time. Designed voices are cheaper still, because
there is no reference to encode.

`Scripts/evie-voice warm` speaks once with each profile: measured at 23.0 s for
the one profile without stored reference text and between 0.5 s and 1.4 s for the
rest. That 23.0 s was read at the time as a one-off warming cost. It was not — see
the reference-transcript section above. Warming is now unnecessary for that
reason, and the transcript is filled in instead.

### Speaking on demand

Every answer card carries a speaker button. Pressing it is a person pointing at
something and asking to hear it, which is not the same question as whether she
answers out loud on her own — so it does not consult the speech preferences at
all. It does bring the engine up like any other request to speak, and falls back
to a system voice, saying why, if it cannot.

It toggles, because the thing you most want to do to a voice reading four
paragraphs at you is stop it. The button tracks a single `onSpeakingChanged`
signal rather than deriving its state from `onStarted` and `onFinished`
separately, which gets it wrong the first time those fire out of order — a
barge-in stops and starts in the same breath. It carries three states, idle,
preparing and speaking, because the couple of seconds of synthesis before the
first sound made the press look like it had missed.

Whether a question is spoken back is pinned at submission rather than read when
the answer arrives. Reading it late meant a typed question could be spoken aloud
with "falar quando eu digitar" off: open the microphone while a typed question is
in flight and the flag flips underneath it. The switch was never consulted
wrongly; the question was.

### On cloning someone else's voice

A specific person's voice — including a character performance in a game — is that
performer's voice, and usually someone else's recording as well. The engine itself
is built expecting consent: its profile table carries `consent_text`,
`consent_audio_path`, `consent_recorded_at`, and `verified_own_voice`.

What reproduces cleanly without any of that is the *register*: a designed voice
set to young adult and high pitch gives the same quick, bright energy without
being anyone in particular. That is what "Evie Enérgica" is. A real person's voice
is a recording away, from anyone willing to give one.

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

Speech is transcribed daily and the recogniser has never been scored. There is no
Brazilian Portuguese WER for it, no latency figure after the language download, no
barge-in measurement, and no energy number.

## The wake phrase — 2026-08-06

`EvieWakePhrase` matches by edit distance over the phrase with its spaces
stripped, and **the threshold was measured rather than picked**. "Evie" is not a
Portuguese word, so a pt-BR recogniser builds it out of real ones. Measured
against what this recogniser actually produces:

| Heard | Score |
|---|---|
| "ei ivi", "ei evi", "ei eve", "ei e vi" | 0.667 – 1.000 |
| Twelve ordinary sentences, including "seis e meia" and "aquele vinho" | never above 0.500 |

0.6 sits in that gap. The first attempt at 0.7 dropped "ei ivi", which is exactly
the mis-hearing that would have kept her from coming.

Variants separate on semicolons, not commas. The first attempt split "Ei, Evie" in
two, discarded "Ei" as too short, and left her listening for a bare "Evie" —
worse than the phrase that was configured.

Before this, the switch and the text field in settings were wired to nothing.
Nothing in the code read either preference, so "Ei, Evie" could never have worked:
the interface promised a feature that did not exist.

### What arming costs

The promise was to measure before optimising. Measured on this Mac over three
40-second windows, in a room with speech in it:

| State | CPU |
|---|---|
| Stopped, nothing armed | 0.03% of one core |
| Armed | 1.01% |
| Armed, through the energy gate | 0.84% |

**Both of us had assumed worse.** The objection to the feature was that it
consumes the machine, and that assumption was wrong. About one percent of one core
is what it costs. What it costs is not CPU.

`EvieWakeGate` feeds the recogniser only while the level is above an adaptive
floor, with a pre-roll ring so the first syllable is not eaten. It works, and it is
tested. But it opened for 44.8% of buffers in this room and returned 0.84% against
a predicted 0.47% — it is not switching off as cleanly as the arithmetic says it
should, and 0.17 percentage points of one core is not a saving that earns a ring
buffer in the audio path. It is kept because it is written and tested and only
reachable when the wake phrase is switched on, which it is not. It is not
recommended.

### What it costs that is not CPU

While armed there is no waveform, no listening state, nothing on screen, and
nothing kept beyond an 80-character tail thrown away every minute. What cannot be
hidden is the orange microphone dot: macOS shows it for any application holding
the microphone, and "Hey Siri" is exempt only because it runs on hardware no
third-party application can reach. The settings pane says that plainly rather than
implying otherwise, and shows what the recogniser actually heard, which is the
only honest way to tune a name it has never seen.

`docs/SIRI.md` describes the route that avoids the dot entirely — an App Intent,
letting Siri's own always-on hardware do the listening and hand Evie the turn with
her microphone shut. It needs a paid Developer Program membership: observed, the
App Intents daemon rejected Evie's own bundle for having no Team ID.

### The check that has not been run

Nobody should turn this on yet. The end-to-end check — that the configured phrase
still wakes her through the gate — **was not performed**. The threshold is
measured against transcripts, and the CPU cost is measured, and neither of those
is the same as speaking to her across a room and having her come.

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

**What shipped is not this.** No classifier was trained and no enrolment exists.
The implementation runs the system recogniser over a continuous capture and
matches its transcript by edit distance, with the threshold measured against real
mis-hearings rather than against a held-out set. The gates in the paragraph above
remain unmet, which is the reason the feature is off by default. See "The wake
phrase" above for what was measured instead.

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
