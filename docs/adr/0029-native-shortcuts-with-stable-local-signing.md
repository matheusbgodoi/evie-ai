# ADR 0029: working native Shortcuts with stable local signing

Status: Accepted; supersedes ADR 0023 for locally signed builds

Date: 2026-10-17

## Context and actual failure

Generated App Intents metadata, discovery and direct in-process `perform()`
checks do not prove system invocation. In the actual macOS 27.2 Shortcuts app,
all three Evie actions appeared, but executing Open Evie failed with
`LinkDaemon.ProcessRegistry.Errors` error 0. The system log identified the
boundary: `Unable to get teamId`. The installed pinned Evie Dev signature has
no TeamIdentifier. The Mac has no valid Apple Development or Developer ID
signing identity. Discovery was a pass; dispatch was a failure, not a completed
integration. No password, developer identity or entitlement was fabricated.

Apple documents code-signing team identity in its
[security constraints guidance](https://developer.apple.com/documentation/security/defining-launch-environment-and-library-constraints).
The exact App Intents rejection above is an observed boundary on this runtime,
not a claim about every macOS version or unsigned application.

## Decision

Default this build to `EVIE_NATIVE_APPLE_MODE=public-urls`, preserving the
existing signing requirement and OS permissions. Register the public `evie`
URL scheme and handle it through the standard
[NSApplicationDelegate URL entry point](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application(_:open:)).
Use actual Shortcuts workflows composed from public URL/input/encoding actions:

- `evie://open` opens conversation UI.
- `evie://prepare?text=...` prepares a draft for review. It never submits and
  refuses to replace an existing draft.
- `evie://capture` opens a capture review. Only an explicit confirmation requests
  the existing indicator/permission/capture path. A URL never captures by itself.

External text is untrusted. The parser accepts exactly these routes, one text
query for prepare and no credentials, port, path, fragment, extra/duplicate
queries or execution command. The question limit is 8,000 Unicode characters;
a separate one-MiB encoded-URL cap bounds parsing work. These are integration
limits, not chat or model context limits. Only one parsed cold-launch request
is retained. Diagnostic/terminating processes do not accept URLs.

Native entry points preserve the emergency-stop wake latch. Capture review
pauses listening, excludes voice/research/calibration admission, and rechecks
current interaction guards after confirmation. Cancel, close, emergency stop,
sleep, inactive session and shutdown revoke the pending callback. Sleep/session
revocation is synchronous on the main queue, not another deferred Task. Nothing
in a URL grants computer control, accepts an approval, sends data or writes files.

Direct App Intents remain an explicit `app-intents` build mode, compiled with
`EVIE_DIRECT_APP_INTENTS`. They require a real Apple-anchored signing identity
and nonempty TeamIdentifier. Build and install share validation of the bundle's
actual mode before replacement. The default excludes those types/provider and
removes their metadata, so it does not advertise known-unusable actions.
Obtaining another signing identity is optional future distribution work; the
working URL workflows do not require a developer subscription or private API.

## Validation

Five Core parser tests passed after the invalid stub failed the positive cases.
The capture-controller regression restored only the former deferred notification
callback: it admitted a stale confirmation after sleep. The actual synchronous
controller passed the same fixture, including single-use confirmation,
cancel/close/stop/session/shutdown. It uses an isolated notification center and
synthetic callback, not a screenshot or global sleep event. Method and limits:
[NATIVE_CAPTURE_VALIDATION](../NATIVE_CAPTURE_VALIDATION.md).

The exact coordinator voice methods are compiled into a controlled-boundary
harness. Fifteen cases passed. Two causal negative controls reproduced late
audio startup after PTT release and failure to return wake listening after a
canceled preparation. Coverage includes PTT release, generation
revocation, capture review, late transcription/finalization and a URL opening
UI without rearming a stopped wake listener. This is state-machine evidence,
not another hardware microphone measurement.

Actual Shortcuts workflow invocation on the installed bundle is a separate
release gate recorded in [NATIVE_APPLE](../NATIVE_APPLE.md). Do not substitute
metadata discovery or a mocked destination for it. Preserve the original
owner's workflows and exclude test captures/private desktop content.

## Alternatives rejected

- Forge a team identity or use private Siri APIs: bypasses the observed boundary.
- Publish discoverable actions known to fail at runtime: misleading user flow.
- Require a new developer account and rotate TCC before providing local features:
  unnecessary for the supported public URL workflow.
- Let any incoming URL capture/submit silently: external input has no authority
  to approve that action.
