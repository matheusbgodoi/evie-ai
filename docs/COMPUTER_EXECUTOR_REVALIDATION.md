# Executor context revalidation and clipboard consent

Implemented 2026-10-16; closes the executor findings formerly tracked as
11b–11d in PROJECT_STATUS. The authority model remains ADR 0016 and the
research shortcut lease remains ADR 0020.

## Behavior

A valid commit is necessary but no longer sufficient after an asynchronous
wait. Immediately before AX input, a pointer operation, a chord, a paste, or
each Unicode text chunk, the executor revalidates the session and checks that
the observed process is still frontmost. Keyboard routes also recheck secure
input and a secure focused field. Because querying Accessibility can yield,
the synchronous locator's frontmost process and secure-input state are read
again after the awaited response, immediately before dispatch.

Before **every pointer fallback**, including a listed element that returns
`notPressable`, the current frontmost window under the point must belong to
the observed process. The observed window must not have moved, and the point
must not be covered by an Evie window. This check also applies after a dwell,
not just before its animation begins. AXPress remains targeted to the listed
process and element; an unconfirmed AXPress is never repeated as a click.

A drag receives the executor's checking callback before press and each movement
step. Its delay propagates cancellation instead of swallowing it. Revocation,
focus changes, a moved window or a foreign window along the path stop further
movement. The already-held mouse button is released at its last dispatched
point on interruption; cleanup does not continue to the requested destination.

`clipboard_write` now asks before replacing the person's clipboard, showing
the full intended text. A trusted, local flow that has already collected
explicit consent for clipboard output may create a session with
`EvieAgentModeBroker.begin(… allowsClipboardWrites: true)`. This permission is
stored only on that expiring, internally minted grant. It is false by default
and never inferred from the model's text, an on-screen instruction, or a goal's
wording. It does not authorize clipboard reads or other sensitive actions.
Research's direct isolated answer-to-clipboard path keeps its existing explicit
destination consent and concurrent-copy protection. Transient paste continues
to restore the person's original clipboard and does not become permanent
`clipboard_write` consent.

## Research answer-entry boundary

Research shortcut grants additionally carry `answerEntryOnly`, derived from
`UserGesture.researchShortcut` by the broker rather than set by model text.
This policy refuses Return/newline typing, launching apps, clipboard reads,
drags, generic buttons, double/right clicks and unknown coordinate targets.
It permits single left clicks only on identified AX fields or standard
radio/check/dropdown choices without a confirm/send label; text/paste requires
a focused field, and key chords are limited to select-all/paste in a field or
plain navigation within a known field/choice. Other sensitive policies still
apply and a confirmation cannot expand this grant into submission authority.
Custom controls that do not expose these roles require the person. A web page
can perform network writes on `input`, `change`, `click` or `paste` events;
this boundary cannot promise that a third-party website never auto-saves or
sends. It prevents Evie from explicitly submitting through the supported
controls, not arbitrary behavior inside somebody else's application.

A second red run (`ComputerActionPolicyTests`) reproduced 11 failed
expectations across 44 tests before adding this restriction. The subsequent
executor/policy/broker/clipboard check passed **112 tests in four suites**
(0.033 seconds of test execution), logs `/tmp/evie-research-policy-{red,green}.log`.

## Boundaries

These are application-level checks, not an atomic OS transaction. An external
process can still change focus or windows between a final check and a posted
system event. Synchronous down/up event pairs are dispatched without suspension;
checks repeat across every asynchronous boundary and drag movement. The
existing takeover monitors, broker limits and denylist still apply. Cleanup
mouseup on an interrupted drag is necessary to avoid leaving input held and is
not a new destination action.

No polling loop or idle service was added. Revalidation runs only during an
explicitly authorized action. Its wall-clock and battery overhead have not been
benchmarked independently of the integration run.

## Verification record

Regression tests first reproduced the old behavior with real Swift Testing:

`Scripts/test --filter 'ComputerExecutorTests|ComputerActionPolicyTests'`

Before the fix: 75 tests across two suites, **15 failed expectations**, including
three text chunks posted after secure input changed following the first chunk,
AXPress after focus changed during the dwell, pointer fallback onto a foreign
window, and an unconfirmed clipboard replacement. Log retained locally at
`/tmp/evie-executor-red.log`.

After the fix, the same 75 tests passed; expanding the check to
`ComputerExecutorTests|ComputerActionPolicyTests|EvieAgentModeBrokerTests|ClipboardSessionTests`
passed **110 tests across four suites** in 0.034 seconds (test execution only;
compilation is additional). `Scripts/test` compiled with warnings as errors.
`swift format lint --strict` on the six touched Swift files and
`git diff --check` passed. Logs are local at `/tmp/evie-executor-green.log` and
`/tmp/evie-executor-final.log`. The installed-app boundary checks are recorded
in the integration work log. The unit tests use controlled input adapters to reproduce
races deterministically; they do not by themselves prove native event delivery.
