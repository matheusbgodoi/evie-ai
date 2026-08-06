# Siri, and being woken without listening

## The answer

**Yes.** Evie can be woken by voice with her own microphone shut, her own
recogniser never started, and no orange dot of her own. The system does the
listening, on the hardware she cannot reach, and hands her the turn.

It is a real yes, and it was built and measured rather than reasoned about. But
it is a yes with a shape, and the shape is the whole decision:

- The utterance must **start with the Siri wake word**. "Ei, Evie" alone will
  never work. "E aí Siri, ei Evie" will.
- The phrase after it must **contain a name of the app**. That is enforced, and
  it was measured being enforced — phrases without it are silently thrown away.
  The good news is that *which* name is up to him: the app can register spoken
  aliases, so "Evie" is available even though the bundle is called Evie, and so
  is a phonetic spelling if pt-BR dictation mishears it.
- It requires a **paid Apple Developer Program membership**. This is the one that
  hurts, and it is not a guess: the App Intents daemon was observed rejecting
  Evie's own installed bundle, today, for having no Team ID.
- **The question cannot be spoken in the same breath**, as far as the evidence
  goes. She is launched, not asked. See *What was not settled*.

So the previous answer — "Hey Siri runs on the always-on processor, no
third-party app can reach it, therefore no" — was right about the hardware and
wrong about the conclusion. Evie does not need to reach the always-on processor.
She needs Siri, which already owns it, to pass her the turn.

## The runtime this was measured on

macOS 27.0 (build 26A5388g), Apple Swift 6.4, **Command Line Tools only — no
Xcode**, Apple Silicon. Measured 2026-08-06.

## What was measured

### App Intents compiles without Xcode

`AppIntents.framework` is present in the Command Line Tools SDK, with a Swift
module for `arm64e-apple-macos`. An `AppIntent` with a `@Parameter`, plus an
`AppShortcutsProvider` declaring Portuguese phrases, compiles with plain
`swiftc` at exit 0. No macro plugin, no Xcode.

### The build step Xcode provides is missing — and can be replaced

`appintentsmetadataprocessor` does **not** exist in the Command Line Tools.
`xcrun --find` fails for it. Only the `.xcspec` files that *describe* the build
phase ship; the tool itself does not. Without it there is no
`Contents/Resources/Metadata.appintents`, and without that the system never sees
the intent. That is exactly the "a build phase only Xcode provides" failure the
brief anticipated.

**It is not fatal, because the output is plain JSON.** Every app on this Mac that
declares App Shortcuts — 73 bundles were surveyed — carries a
`Metadata.appintents` directory of exactly two files: a `version.json`, and an
`extract.actionsdata` which is uncompressed, human-readable JSON. Its schema was
read off Apple's own apps and WhatsApp's.

A `Metadata.appintents` written **by hand**, from a Python dictionary, was
accepted, parsed, indexed and donated to Siri by the system. The exact log lines
from `linkd`:

```
Checking dev.evie.siriproof at .../Metadata.appintents/extract.actionsdata
Adding .../extract.actionsdata for dev.evie.siriproof
[dev.evie.siriproof] Inserting canonical bundle
[<private>] Writing combined metadata to index
Interpolating AppShortcuts for dev.evie.siriproof:pt-BR
Interpolating Ei ${applicationName} with <private>
[<private>] Generated 1 AppShortcuts with 3 total phrases
Interpolated dev.evie.siriproof, donating to Siri...
```

Note `:pt-BR`. The locale came from the system, the phrases were Portuguese, and
they were interpolated without complaint.

The Swift compiler can also emit the raw material Xcode's processor consumes:
`swiftc -frontend -emit-const-values-path … -const-gather-protocols-file …`
produced a 16 KB `.swiftconstvalues` file containing the phrase strings, the
`applicationName` tokens and both intent type names. So a generator that reads
what the compiler already knows is possible; it is not required, since the JSON
can simply be written.

### Self-signed, unsandboxed, accessory — two of the three are fine

The proof bundle was signed with Evie's own **self-signed** `Evie Dev`
certificate, **unsandboxed**, `LSUIElement` true and
`NSApp.setActivationPolicy(.accessory)` at launch, no Dock icon. It registered
and was donated to Siri anyway. Being an accessory app and being unsandboxed
disqualify nothing.

**The signature does.** `linkd` rejected the proof app's own runtime connection:

```
Failed to generate bundleIdentity:
 -Unable to get teamId from dev.evie.siriproof PID [74670]
Rejecting invalid client due to requiresValidatedBundle: … on mach service
named com.apple.linkd.autoShortcut
```

Contrast, from the same log, minutes apart — a Developer-ID-signed app:

```
Accepting [73853]:com.google.Chrome.helper: … on mach service named
com.apple.linkd.autoShortcut
Registered process with identifier 73853-905268
```

And this is not hypothetical for Evie. The **installed** `Evie.app` was caught
doing it while this research ran, without anyone asking it to:

```
14:42:53  linkd  Failed to generate bundleIdentity:
                  -Unable to get teamId from com.matheusbgodoi.evie PID [72514]
14:42:53  linkd  Rejecting invalid client due to requiresValidatedBundle
14:42:53  evie-shell  Will NOT re-try to establish the connection
```

Static registration of the phrases survives this. What is refused is
`com.apple.linkd.autoShortcut`, the process-instance registry — the channel
`AppShortcuts.updateAppShortcutParameters()` uses. Whether the *execution* of an
intent also depends on that channel was not established; see below.

### Location matters, and it is not the signature

The first launch, from `/private/tmp/…/scratchpad`, failed differently:

```
Could not create application record for dev.evie.siriproof:
NSOSStatusErrorDomain Code=-10814
audit error Bundle did not provide any metadata sources
```

The identical bundle, identically signed, copied to `~/Applications`, indexed
successfully. So `-10814` was the path, not the certificate — worth recording so
nobody re-derives it. Evie already installs to `~/Applications`.

### The app name in the phrase is mandatory, and enforced silently

Measured directly. Three phrase templates were registered — two without
`${applicationName}`, one with:

```
Interpolating Ei Evie with <private>
Phrase missing \(.applicationName)
Interpolating Fala Evie with <private>
Phrase missing \(.applicationName)
Interpolating Acordar a ${applicationName} with <private>
[<private>] Generated 1 AppShortcuts with 1 total phrases
```

Three templates in, one phrase out. No build error, no warning to the user — the
offending phrases simply cease to exist. `AppShortcutPhraseToken` in the SDK has
exactly one case, `applicationName`, so there is no other token to reach for.

The survey agrees. Of 225 App Shortcut phrases installed on this Mac, 109 lack
the token — and **every one of those 109 belongs to Apple** (Books, Notes,
Freeform, Voice Memos). The only third-party app on this machine with App
Shortcuts, WhatsApp, includes it in all three of its phrases.

### But he chooses the name — measured

`INAlternativeAppNames`, an `Info.plist` array, is real, is used by third parties
(Prime Video registers "Amazon", "Amazon Prime", "Amazon Prime Video"), and
supports `INAlternativeAppNamePronunciationHint` and `INPreferredForAppShortcuts`
per entry.

Adding three aliases to the proof bundle and leaving two templates in place:

```
Interpolating Ei ${applicationName} with <private>
Interpolating ${applicationName} with <private>
[<private>] Generated 1 AppShortcuts with 8 total phrases
```

Two templates × four names = eight phrases. The alias mechanism multiplies, and
`"${applicationName}"` **alone** is a legal template. So the phrase the user says
after the wake word can be literally just the name:

> **"E aí Siri, Evie"**

or, with the `Ei` template, **"E aí Siri, ei Evie"**. If pt-BR mishears "Evie" —
which the wake-listener doc already notes is likely, since it is not a Portuguese
word — he adds "Ivi" or "Êvi" as an alias and both work. This is the same tuning
problem `EvieWakeListener.lastHeard` exists to solve, with a much better tool.

### Nothing cheaper for keyword spotting in the Speech framework

The macOS 27 `Speech` module was read in full. There is no keyword-spotting mode,
no wake-word API, no low-power path. Zero occurrences of "keyword"; none of
`lowPower`, `alwaysOn`, `wakeWord`. `SpeechTranscriber` and `DictationTranscriber`
offer presets that trade latency and alternatives, not power.

One thing is worth knowing: **`SpeechDetector`** exists, and is not a transcriber.

```swift
final public class SpeechDetector : SpeechModule {
  public init(detectionOptions: DetectionOptions, reportResults: Bool)
  public enum SensitivityLevel { case low, medium, high }
  public struct Result { public let speechDetected: Bool ... }
}
```

It reports *that* someone is speaking, not what they said. As a gate in front of
`SpeechTranscriber` it would plausibly cut the CPU of the current design a great
deal. **This was not benchmarked.** And it does not solve the problem the owner
actually raised: it still holds the microphone, so the orange dot stays lit and
something is still listening to everything he says. It is a smaller version of the
thing he switched off, not a different thing.

Dictation being enabled changes nothing here. It gates which on-device models are
installed for `SpeechTranscriber`, which Evie already depends on; it exposes no
additional always-on facility to third parties.

## What was not settled, and must not be claimed

Three things. They are the difference between "this registers" and "this works",
and the second one is the one that could still sink it.

1. **Nobody spoke to Siri.** There is no way to script a Siri utterance, and
   there is no CLI that invokes an App Intent — `AppIntentsCLISupport.framework`
   ships no executable, `shortcuts run` handles only user shortcuts, and the
   `linkd` index and the Shortcuts group container are both TCC-protected and
   unreadable. Every claim above stops at "the system accepted the phrase and
   donated it to Siri", because that is where the observable evidence stops.

2. **Whether `perform()` actually runs for a self-signed app is unknown.** The
   `requiresValidatedBundle` rejection above is real and reproducible, and it is
   the honest reason to hold this open. Registration and execution go through
   different paths and only registration was proved. If a Developer ID turns out
   to be required for execution as well as for the registry connection, the
   answer for a self-signed Evie collapses from yes to no, and it collapses for
   a reason that costs money to fix rather than time.

3. **Whether the question can be spoken in one breath is unresolved.** A String
   `@Parameter` interpolated into a phrase — `"Perguntar à \(.applicationName)
   \(\.$question)"` — compiles at exit 0. But the runtime rejected the
   hand-written metadata that expressed it, and a **control run proved the
   rejection was my malformed parameter JSON, not the phrase**: with the same
   parameter present and the phrase not referencing it, the whole provider still
   dropped out with `does not have AppShortcuts`; removing the parameter restored
   it. So that experiment says nothing and is reported as saying nothing.

   The indirect evidence points to *no*: across the 73 bundles surveyed, every
   parameterised App Shortcut phrase (Notes' `"Open the note ${target}"`,
   Freeform's `"Open ${target} in ${applicationName}"`) carries a
   `parameterPresentation` with an `optionsCollection` — a **finite, presentable
   list** of values. None takes free text. Plan for "she is launched, then asks
   what he wants", and treat one-breath questions as a bonus if a real Xcode
   build later proves otherwise.

Consequently: **whether the answer comes back through Siri's voice or only in
Evie's own overlay was not determined either.** `ProvidesDialog` and
`IntentDialog` exist in the SDK, so the mechanism is there; nothing was observed
using it. The safe design is the one Evie already has — she is brought forward
and answers in her own window, in her own voice, through the speech she already
owns. That also keeps the answer off Apple's path entirely, which is consistent
with the rest of this project.

## What it would cost to build

Assuming the Developer ID question is settled first, because everything below is
wasted if it is not.

| Piece | Lines | Note |
|---|---:|---|
| `EvieShell/EvieAppIntents.swift` — one `AppIntent`, one `AppShortcutsProvider` | ~60 | proved to compile |
| `Scripts/evie-app` — emit `Metadata.appintents` (two files) | ~70 | proved to be accepted |
| `Scripts/evie-app` — `INAlternativeAppNames` in the Info.plist | ~15 | proved to multiply phrases |
| Settings pane — the aliases, and the one-time instructions | ~120 | |
| Tests — the metadata JSON is generated correctly | ~80 | |
| **Total** | **~345** | |

Small, because the hard part turned out to be knowing rather than writing. Set
against it: deleting `EvieWakeListener` and its settings, which is a subtraction
of roughly the same size, and a subtraction of a permanently-open microphone.

The `Info.plist` that `Scripts/evie-app` writes today has `CFBundleIdentifier`,
the usage descriptions and little else. It needs `INAlternativeAppNames` added,
and the build needs to place `Contents/Resources/Metadata.appintents/`. Signing
must happen **after** both, since the metadata is inside the sealed bundle —
`Scripts/evie-app build` already signs last, so the ordering is already right.

## What he has to accept

Stated plainly, because these are the reasons to say no.

1. **A paid Apple Developer Program membership, near-certainly.** The self-signed
   certificate `Scripts/evie-app identity` creates has no Team ID, and the App
   Intents daemon was measured refusing Evie for exactly that. This is a
   recurring annual cost, an Apple account, and a step the project has so far
   deliberately avoided. It is the single largest thing standing here, and it
   cannot be engineered around — `requiresValidatedBundle` is Apple's check
   running in Apple's daemon.
2. **He must say "Siri" first.** Every time. "Ei, Evie" on its own is not
   available to any third-party app and never will be; that is the part of the
   original answer that was correct. What he gets is "E aí Siri, Evie" — three
   words instead of two, in exchange for never being listened to.
3. **Siri gets the first pass at understanding him.** If Siri decides the
   utterance was aimed at itself, Evie never hears about it. There is no appeal.
4. **Probably two breaths, not one.** She is woken, then asks. Until a real Xcode
   build settles it, assume he cannot dictate the whole question in the same
   utterance.
5. **The wake path stops being Evie's.** Today the phrase, the tuning, and the
   *what she actually heard* display are all hers and all inspectable. After
   this, phrase matching happens inside Siri, where it cannot be debugged, only
   re-phrased. The alias list is the only knob.
6. **Siri must be enabled.** If he has Siri switched off, this feature does not
   exist for him.

What he buys: the microphone stays shut. No orange dot from Evie. No recogniser
running for hours to catch one word. No transcript accumulating. Nothing heard
that was not addressed to her — the objection he actually raised, answered
exactly.

## What the user does once

Assuming a build that ships this:

1. Enable Siri, in Ajustes do Sistema → Apple Intelligence e Siri, with pt-BR and
   "Ouvir 'Siri' ou 'E aí Siri'" on. (The always-on processor does this part;
   this is the step that makes it free.)
2. Install Evie. Registration is automatic — no toggle, no permission dialog. It
   was measured happening within a second of `open`, unprompted.
3. Optionally, add pronunciation aliases in Evie's settings if pt-BR mishears the
   name. This is the tuning `EvieWakeListener.lastHeard` used to serve.

Nothing else. No entry in Shortcuts.app, no shortcut to install, no click to
confirm — App Shortcuts differ from the generated-shortcut path in
[`AUTOMATIONS.md`](AUTOMATIONS.md) precisely here.

## What was ruled out, and how

- **Focus filters.** `SetFocusFilterIntent` is an App Intent. It rides the same
  registration and the same Team ID gate, and it is triggered by a Focus mode
  changing, not by a voice. No help.
- **Shortcuts automation triggers.** The Mac's automation triggers are time of
  day, a Focus change, an app opening, a Wi-Fi change, a device connecting. There
  is no voice trigger. `shortcuts list` enumerates only user shortcuts and did
  not show the proof app's App Shortcut, which is the expected split: App
  Shortcuts live in the Siri index, not in the shortcuts store.
- **`launchd` `WatchPaths`.** Already covered in [`AUTOMATIONS.md`](AUTOMATIONS.md).
  It fires on a file appearing. Nothing about it is voice, and it does not
  change.
- **A cheaper Speech path.** Read out of the SDK, above. There is none.
  `SpeechDetector` is cheaper than transcription but still holds the microphone.
- **Reaching the always-on processor directly.** Not attempted, and not worth
  attempting. The original answer is correct on this point: it is Apple's, and
  the only interface to it is Siri — which is what this document is about.

## Reproducing this

The scratch proof is not in the repository. It was a five-file bundle —
`main.swift` setting `.accessory`, `Proof.swift` with the intent and the
provider, a hand-written `Info.plist`, and a hand-written
`Metadata.appintents/{version.json,extract.actionsdata}` — built with `swiftc`,
signed with `Evie Dev`, run from `~/Applications`, observed via:

```
/usr/bin/log show --last 5m --predicate 'subsystem == "com.apple.appintents"' \
  --style compact
```

That predicate is the whole method. `linkd` narrates every step it takes, names
the bundle, prints each phrase template as it interpolates it, and says exactly
why it discards one. Anyone doubting a claim above can re-run it in ten minutes.

The proof bundle was removed and unregistered afterwards; `linkd` was observed
confirming the removal (`removed: ["dev.evie.siriproof"]`). Nothing was installed
system-wide and Evie's own bundle was not touched.
