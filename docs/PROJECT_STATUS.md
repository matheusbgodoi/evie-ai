# Project status

Last updated: 2026-08-07

## Current phase

**Phase 1 inference validation is still open. Phase 2 native-shell work is far
past prototyping, and Phase 3 and Phase 4 have been overtaken by working code.**

Evie has her own identity rather than presenting as a front end for a local
server: the hidden persona names her creator and how he is addressed, no surface
mentions the model or the inference server, and the loopback port moved to 38433
so it cannot collide with another project. The overlay can be moved, resized, and
reset; its height follows what SwiftUI actually measured. Everything configurable
is reachable through a settings window, and forty-three help tags across its panes
now say what each control does when it is hovered.

The voice loop is closed in both directions. The microphone is granted and used,
the system recogniser turns speech into a typed question, and the answer is spoken
either automatically or on demand through a speaker button on the card. The
cloned/designed voice engine is started when a trained voice is asked for and not
before, so the 2.4 GB it holds resident is a consequence of a decision the user
made rather than of Evie starting at login.

She reads. Images and PDFs go through the system's own text recognition, and the
system's own vision model describes what a picture shows, with no download and no
second process. She reads the folders the user authorises, and retrieval over
those folders now matches on meaning rather than on the exact word typed. She can
search the web, off by default. She can propose a change to a file, which happens
only when a person presses a button.

Three typed commands exist and are discoverable from a "/" menu: `/plano`
decomposes a question into steps and runs them in order, `/buscar` shows the
passages retrieval found and makes no model call at all, and `/web` skips the
notes and answers from the web. `/buscar` now shows the note rather than its
storage format: LaTeX, wikilinks, tables and opening front matter are rendered or
removed instead of being put on screen as punctuation.

She knows the date, which she did not before: every answer touching "hoje", "esta
semana" or a deadline was previously a guess written in the voice of a fact. The
date is in the system prompt and the exact time rides with each question, for a
measured reason recorded in `docs/MODEL_STRATEGY.md`.

She reads Mail and Calendar, off by default, through the Apple applications that
already hold the user's Gmail and iCloud — no OAuth application and no token.
Since `383a92c` she can create one calendar event, and since `6dade94` she can
send one message: the tools she calls, `propose_event` and `propose_mail`,
perform nothing and draw a card, and the event or the message happens when a
person presses the button. The mail card is the first thing in Evie whose primary
action reaches somebody else and cannot be undone, so it shows every recipient in
full and the entire body, offers a draft as well as a send, and has no
auto-approve path under any setting. Deleting, replying, filing, marking read and
attaching do not exist; inviting somebody to an event is impossible from a script
on this Mac, measured. She calculates rather than guessing: `calculate`
is a recursive-descent parser over a fixed grammar, declared on every turn,
deliberately not `NSExpression`.

Scheduled work exists for the first time. A schedule is a prompt plus a trigger —
daily, chosen weekdays, or a watched folder — held by `launchd` as a user
LaunchAgent, with nothing of Evie's alive between firings.

`Evie.app` exists with a stable bundle identifier. That was the hard blocker for
every permission Evie will ever need — measured, an unbundled binary touching the
microphone hangs forever rather than failing. `Scripts/evie-app identity`, which
had never once worked, now does: it no longer passes an `-legacy` flag LibreSSL
does not have, no longer sends both `openssl` invocations to `/dev/null`, scripts
the trust step instead of routing it through Keychain Access, and asserts the
result rather than assuming it. Until it is run on a given machine the copy is
ad-hoc signed, and an ad-hoc copy refuses every update.

The application can update itself from a GitHub release, in three deliberate
presses, and installs a download only when its code signature matches the running
copy. See `docs/SECURITY.md` for what is checked and what was measured against
tampered bundles.

No Hermes runtime, persistent background service, or credential has been installed
or configured, and Evie still holds no account of her own: Mail and Calendar are
read through the applications that already hold the user's, so there is no OAuth
application and nothing on disk to revoke. Scheduled runs are `launchd` jobs, not
a service — no process of Evie's exists between one firing and the next.
Completed conversations are personal
local state under `Application Support/Evie/Conversations`, now including the
files that were attached to them; they remain outside Git and hidden prompts are
never stored. TurboFieldfare source, model state, configuration, PID state, and
logs also remain under `~/Library`.

## Implementation snapshot

- `EvieCore` provides backend-neutral messages, phases, artifacts, reducer state,
  configuration, and an `AgentClient` protocol.
- `TurboFieldfareClient` streams Chat Completions from
  `http://127.0.0.1:38433/v1`, requires loopback, supports cancellation, and can
  declare tools and reassemble the calls the model asks for. It never executes
  one — that is `EvieAgentLoop`'s job, outside the client, so prompt injection
  cannot reach an executor through the transport. Its byte-level SSE framing
  preserves empty event separators across arbitrary transport fragmentation and
  CR/LF variants.
- `EvieRootRegistry`, `EvieFileToolbox`, and `EvieAgentLoop` let Evie read the
  folders the user granted, through read-only tools over the contained reader. The
  model is handed opaque root identifiers and never a filesystem path.
- `EvieFileWriter` and `EvieChangeIntent` implement moving, renaming, and trashing
  inside those folders. The tool the model calls performs nothing: it records a
  proposal and the change happens when a person presses a button, or — only when
  the user's own message asked for a change — automatically, and is reported in
  the conversation afterwards either way. Deleting means the Trash; a move fails
  rather than overwriting; the file's identity is re-checked at the instant of the
  change.
- `EvieVaultIndex`, `EvieVaultRetriever`, `EviePassageRanker`, and `EvieQueryTerms`
  retrieve by meaning as well as by word, fusing title, BM25 and embedding
  rankings. See `docs/RAG.md`.
- `EvieMailCalendar` holds three reading tools — `read_mail`, `search_mail`,
  `read_calendar` — as fixed AppleScript literals whose inputs travel as process
  arguments through `on run argv`. Nothing that deletes, files or marks read was
  declared. Off by default; `docs/SECURITY.md` records the tests that hold the
  boundary, including the break-out payloads run through the real `osascript`.
- `EvieCalendarEventProposal` and `EvieCalendarEventTool` add the fourth tool,
  `propose_event`, on the same switch. It creates nothing: it resolves the
  moments, reads back the writable calendar names, and records a proposal the
  shell draws as a card. Creating is `EvieCalendarWriting.createEvent`, a separate
  protocol that `EvieAgentLoop` does not hold — the loop's own test stub conforms
  to the reading protocol only, so no test can make the loop write. The single
  caller is the card's button in `AppCoordinator`, which re-checks
  `mailAndCalendarEnabled` at the press; there is no auto-approve path, including
  when file auto-approval is on. Refusals rather than guesses: a timezone
  designator, an unknown calendar name, a start over five minutes past, a span
  over thirty days, an empty title, an end at or before the start.
- `EvieMailProposal` and `EvieMailTool` add the fifth tool, `propose_mail`, on the
  same switch. It sends nothing: it validates the recipients, refuses any address
  the conversation does not contain, reads back the account the message would
  leave from, and records a proposal drawn as a card that lists every recipient in
  full with the whole body. Sending is `EvieMailSending` — `sendMail` and
  `saveMailDraft` — a third protocol `EvieAgentLoop` does not hold, and the loop's
  test stub has no sending function to offer, so no test can make the loop send.
  The only callers are the card's two writing buttons in `AppCoordinator`, each
  re-checking `mailAndCalendarEnabled` at the press; there is no auto-approve path
  for mail under any setting. `add_attendee`, `invite_attendee`, `send_invite` and
  `invite` are refused with a sentence, because Calendar on this Mac cannot take
  an attendee from a script at all — measured, `docs/SECURITY.md`. See
  ADR 0010 and ADR 0011.
- `EvieCalculator` and `EvieCalculatorTool` evaluate arithmetic over a fixed
  grammar with no I/O — Brazilian and foreign number formats, percentages, twelve
  named functions, and refusals that are sentences in Portuguese rather than
  `NaN`. Declared on every turn and behind no preference.
- `EvieSchedule`, `EvieScheduleAgent`, `EviePropertyList` and the `EvieShell`
  schedule types install user LaunchAgents that run the bundle with
  `--run-schedule <id>`. Measured: `launchd` fired an installed job 83 s after
  install at the minute asked for, the turn took 51 s, and the answer reached the
  history; a `WatchPaths` job fired exactly once on a file landing in the folder.
- The command-line diagnostics declare themselves in `EvieDiagnosticRegistry`, so
  `--help` is the same list read out loud rather than a second list kept by hand.
  The application delegate went from 1,438 lines to 71.
- `EvieCommand` and `EvieSearchCommands` hold the typed-command catalogue and the
  read-only `/buscar` and `/web` commands; `EviePlan` and `EviePlanPrompts` hold
  the `/plano` decomposition and its parser.
- `EvieRelease`, `EvieUpdater`, and `EvieBundleSignature` implement the update
  check, the download, and the two signature checks that gate installation.
- `EvieWakePhrase`, `EvieWakeGate`, and `EvieWakeListener` implement the wake
  phrase and its optional energy gate. It is off by default and should stay off
  until the end-to-end check named in `docs/VOICE.md` has been performed.
- `EvieMediaStore` and `EvieStoredMedia` keep what was attached to a conversation
  so it can be read back whole; `EvieConversationExport` writes a conversation out
  as Markdown with YAML front matter.
- `evie-shell` is a SwiftUI/AppKit menu-bar executable with a transparent floating
  `NSPanel`, quick text, a "/" command menu, attachment chips, answer cards that
  scroll inside themselves, a history window, and a settings window.
- The composition root talks directly to TurboFieldfare only for this reversible
  slice. ADR 0006 records why this is not the future trust/lifecycle boundary.
- `EvieConfigurationLoader` applies built-in defaults, an optional versioned local
  JSON file, then supported environment overrides; invalid settings surface an
  actionable startup error and no credential is read or printed.
- `CORE-005` nominal read/propose/commit contracts make authority opaque and
  non-serializable, bound serialized identifiers/collections/depth/bytes and plan
  lifetime, revalidate revision/binding, redact material metadata, and require
  explicit-user evidence for delete. The filesystem writer is the first capability
  to sit behind an approval card; the general broker it describes is still unbuilt.
- `Scripts/evie-runtime` provides an explicit development-only doctor, setup,
  configure, verify, start, stop, status, synthetic smoke, and shell-launch
  workflow. It pins the runtime and 64K launch shape but is not `evied`, a login
  item, an idle-unload policy, or crash recovery.
- `Scripts/test` is a compatibility wrapper for Swift Testing discovery/rpaths
  with the macOS 27 Command Line Tools present on this Mac.
- Complete visible conversations persist as schema-versioned per-session JSON with
  `0700`/`0600` permissions and atomic replacement. Model context is bounded from
  an in-memory copy independently, and termination waits for pending history
  writes. History scanning contains a malformed/unavailable failure to that
  individual file. `EvieConversation` decodes media with `decodeIfPresent`, so a
  conversation saved before attachments were kept still opens.
- The waveform and the reactive ring are driven by real microphone and playback
  levels. `EvieLevelMeter` reads the room's own noise floor rather than comparing
  against constants measured once in one room.
- `EviePersona` generates the hidden system message from an explicit capability
  snapshot, so a capability cannot be described in prose without being built.
- `EviePreferences` stores appearance, the configurable shortcut actions, the
  voice switches, the web-search switch, the wake phrase, and the update
  preferences in a `preferences.json` separate from the model configuration.
- `EvieOverlayGeometry` resolves the panel rectangle from preferences and connected
  displays; the overlay can be dragged, resized, and reset, and recovers to the
  anchored default when the saved display is disconnected.
- The Node-RED workflow plane was researched and dropped against the constraint
  the user set — nothing resident, nothing in Docker. macOS Shortcuts is the
  recommendation in its place, and what she can and cannot do with it is measured
  in `docs/AUTOMATIONS.md`. No Shortcuts code has been written: nothing is
  authored, signed, installed or run. What was built from that document is its
  `launchd` half — schedules — and nothing else.
- `EvieVaultIndex` is built at launch as well as when a folder is granted, prunes
  directories that hold no human writing, and lists hidden ancestors. Before this
  session the index was empty in normal use and every search of the notes answered
  "não achei nada"; it now holds 8,629 passages from the user's four vault
  folders.

See `docs/implementation/VS_001.md` and the task ledger for exact boundaries and
handoff evidence. The ledger has not been re-scored against this session and is
behind the code.

## Current conclusion

The project is viable on a base Apple M5 MacBook Pro with 24 GB unified memory if
heavy components are isolated and loaded on demand.

Two parts of the original hypothesis have now been settled by measurement rather
than by argument:

- **The inference server serialises.** Three concurrent requests took 23.3 s
  against 8.1 s for one. Fanning work out across parallel agents costs 2.9× and
  buys nothing on this machine; sequential specialised steps are what `/plano`
  does instead.
- **Node-RED does not survive the "nothing resident" constraint.** A bare `node`
  process doing nothing costs 37.8 MB on this Mac, against the 4 MB the idle
  TurboFieldfare server costs, and Node-RED is that floor plus 227 packages.

The remaining hypothesis is:

- TurboFieldfare serving Gemma 4 26B-A4B IT at a declared 64K context;
- FP16 KV cache for the baseline; prior Q4 work failed upstream quality/speed gates,
  and Q8/hybrid KV is deferred unless measurements justify custom kernels;
- a native macOS overlay and supervisor that remain lightweight while idle;
- on-demand workers for TTS, and the system's own daemons for vision and speech
  recognition, which cost no memory in Evie's address space;
- macOS Shortcuts, not Node-RED, for deterministic visual workflows;
- a read/propose/commit permission boundary for every integration.

Hermes remains an uninstalled hypothesis; the agent loop in `EvieCore` has been
carrying the work it was proposed for. The retrieval decision was made without
QMD: `docs/RAG.md` records what was built and why an index was not.

One toolchain observation is established for this exact machine: the pinned
TurboFieldfare release server and repacker built with Apple Command Line Tools,
without a full Xcode installation. Upstream still specifies Xcode 26, so this does
not replace the upstream prerequisite or prove another installation will behave
the same way.

One bounded runtime observation is also established for this machine on AC power:
at 65,536 declared tokens the synthetic non-streaming request completed in 5.393 s
and the immediately following SSE request in 0.882 s. The warmed server had a
3,215 MB physical footprint, the native shell 18 MB, both sampled at 0.0% idle CPU,
and macOS reported 53% system-wide memory free. These tiny responses establish
wiring only; they are not the Phase 1 model/context/energy benchmark.

What it costs to leave Evie open was measured on 2026-08-07 and is recorded with
its method in `docs/RESOURCE_BUDGET.md`: 0% CPU for both processes while idle,
10 MB resident for the shell and 9 MB for a long-idle server, against a peak of
130% of one core of ten and 1.66 GB resident for the server during one agentic
turn, with system-wide free memory recovering within about nine seconds. That is
an idle-and-burst measurement, not the benchmark matrix either.

## Decisions accepted for planning

- The product name is **Evie**, pronounced "ee-vee"/"ívi".
- The default interaction is not a chat window. It is a transient voice/command
  overlay with expandable result cards; full history is secondary.
- Visible completed conversations persist locally and are opened deliberately;
  hidden prompts, semantic memory, and action authority are excluded from history.
- The high-quality Gemma model is preserved as the primary candidate instead of
  being replaced prematurely by a smaller model.
- Simple known commands should bypass an LLM when a deterministic action exists.
  `/buscar` is the first one that does: it makes no model call at all.
- Expensive behaviour is entered by typing a command, never guessed from the shape
  of a question. Something that costs minutes must not start because a question
  looked complicated.
- Vision and TTS are specialist workers, not permanent parts of the main model.
  Vision turned out to be a system daemon, which is better than a worker.
- Heavy processes must support idle unload and pressure-aware eviction, and must
  not start themselves. The voice engine starts when a trained voice is chosen.
- Real credentials and personal state are configured locally but never committed.
- All future commits must maintain status, worklog, changelog, and relevant design
  documentation.
- A UI state must be backed by observed activity.

See the ADR index for decision status.

## Open validation gates

1. Measure TurboFieldfare on the exact base M5/24 GB machine at 16K, 32K, and 64K:
   peak/resident memory, prompt processing, first-token latency, decode rate,
   correctness, idle resource use, and cold/warm startup.
2. Compare the primary Gemma with at least one 4B-class and one 9B-class local
   model on the Evie evaluation suite.
3. Benchmark local STT candidates on Brazilian Portuguese and noisy microphone
   input. The system recogniser is in daily use and has never been scored: no
   Brazilian Portuguese WER exists for it or for the FluidAudio challenger.
4. Confirm the wake phrase end to end — that the configured phrase still wakes her
   through the energy gate. The threshold and the CPU cost are measured; this is
   not, and until it is the feature must stay off.
5. Validate the overlay and global command shortcuts on the target display:
   focus, Spaces, full-screen, multiple-display, and accessibility behaviour.
6. Run `QA-005` for repeated follow-ups, restart/resume, deletion, environment-
   managed settings, and response-completion focus behaviour.
7. Settle the two open Shortcuts questions before any automation code: whether a
   shortcut can be run end to end from Evie, and which prompts appear when
   `Evie.app` rather than Terminal is the responsible process. Both are estimated
   at half an hour in `docs/AUTOMATIONS.md`.

The bounded first-test readiness checks are complete: model repack, upstream
verification, loopback health at 65,536 tokens, model discovery, non-streaming and
SSE synthetic requests, and native process launch passed. These checks establish
readiness only; they are not the Phase 1 performance suite.

## Known blockers

- ~~**`QA-006`: nothing visual has been formally accepted by the owner.**~~
  **Passed 2026-08-07.** The owner used the event confirmation card against his
  own calendar — "ela cadastrou pra hoje call cluemed meio dia perfeitamente" —
  and accepted the whole of it: "pra mim está tudo aprovado". Recorded as his
  words rather than paraphrased, because a pass is a person's judgement and not
  a measurement anybody else can reproduce.
- **`REL-001`: there is no release.** The mechanism to install one now exists and
  is tested. Two of the three things it needed are now written: the `1.0.0`
  section of `CHANGELOG.md` gathers what the release contains, and the retrieval
  decision is [ADR 0012](adr/0012-fused-local-retrieval.md). What remains is not
  documentation — a decision on whether the release ships the app or the
  instructions to build it, and then cutting and tagging it, which is the owner's
  to do.
- The bounded first-test measurements exist, and sustained decode, energy and
  battery draw have since been measured on this machine — 5.6 W idle against
  31.1 W generating, 18.1 tok/s unplugged against 18.2 on AC, in
  `docs/RESOURCE_BUDGET.md`. No long-context 16K/32K/64K comparison and no
  answer-quality result exists yet.
- Throughput drifts about 14% down across 32 sustained questions with no
  throttling reported by macOS. The cause is unestablished and it is the one
  performance question these measurements opened rather than closed.
- `Evie.app` is ad-hoc signed until `Scripts/evie-app identity` is run on the
  machine, and an ad-hoc copy has no certificate to compare an update against, so
  it refuses every update. The script now works; whether it has been run on this
  machine is not recorded here.
- The application is not notarized and is not a login item. Notarisation is not
  available for a self-signed identity, which constrains what `REL-001` can be.
- Speech recognition accuracy, latency, barge-in behaviour, and energy cost are
  unmeasured, though the recogniser is in daily use.
- Semantic memory across conversations is propose-and-confirm only: she remembers
  what the user confirmed and nothing else, bounded at sixty entries and two
  thousand recalled characters. She does not learn from a conversation by herself.
- The wake phrase holds the microphone whenever it is armed, which macOS shows as
  the orange dot and which cannot be hidden. `docs/SIRI.md` describes the route
  that would avoid it and why it needs a paid Developer Program membership.
- The development controller can explicitly health-check/start/stop the pinned
  TurboFieldfare server at `--max-context 65536`, but Evie's application does not
  own lifecycle, idle unload, crash recovery, power policy, or automatic startup.
- The voice engine's identity and model manifest are still unpinned and unverified.
  Evie starts a configured local executable and trusts it.
- The exact smaller text and vision model candidates must be pinned immediately
  before benchmarking because this area changes quickly.
- ~~**The persona does not know about Mail and Calendar.**~~ Closed by `ea2344a`.
  `EvieCapabilitySnapshot` gained `readsMailAndCalendar`, so with the switch on
  the persona names `read_mail`, `search_mail` and `read_calendar`, says in
  Portuguese what she may do with mail, and — since `383a92c` — instructs her to
  call `propose_event`, and since `6dade94` `propose_mail`, and never to claim she
  has already booked or sent anything. The
  negative half was the point: without it, asked to schedule a call she searched
  the notes for a meeting that did not exist and reported not finding it.
- The macOS Automation consent prompt for Mail and Calendar has never been
  observed. The terminal used for verification already held the grant, and every
  attempt to provoke a refusal was authorised too; the `errAEEventNotPermitted`
  path is covered by unit tests against both wordings rather than by having been
  seen.
- **Notifications do not work through the framework on this Mac.**
  `UNUserNotificationCenter.requestAuthorization` throws `UNErrorDomain 1` for a
  locally-signed bundle, ad-hoc or signed with this project's certificate, and
  `add()` then reports success while showing nothing. A schedule posts its banner
  through `osascript` instead, and the answer is in the history either way. A
  notarised identity would change this and is not available for a self-signed one.
- The mail confirmation card has not been used by a person. The message sent and
  the draft saved on 2026-08-07 prove the two scripts, not the card that asks
  first — the same gap the event card had until `QA-006` closed it. It is the
  card a person has to read under the most time pressure, and it is the only
  surface added since that pass.
- Location triggers require a trusted source such as a phone shortcut, Home
  Assistant, or a dedicated companion; the Mac alone does not provide a complete
  personal location event stream. Nothing event-driven is reachable at all under
  the "nothing resident" constraint — see `docs/AUTOMATIONS.md`.
- `docs/implementation/TASKS.md` has not been re-scored since this session and
  understates what is done.

## Next recommended action

Two things, in this order, and they are the two things between here and a release.

**`QA-006` — the human pass. Passed 2026-08-07.** The overlay rebuilt around a
bounded card, the answer scrolling inside it, the chevron straightened twice, the
forty-three help tags, the history window's multi-select and export and
thumbnails, and the two panes added to "O que ela sabe" — Mail e agenda, and
Agendamentos — were all in front of him as he used them, and each defect he found
was fixed and re-shown.

The event confirmation card was the last thing outstanding and is now the
strongest evidence: he asked her to book a call, saw the card, pressed the
button, and the appointment appeared where the card said it would. That is the
whole path — proposal, card, press, result — exercised by the person it was built
for, against his own calendar, rather than by a script against a throwaway event.

What this does not cover, and should not be read as covering: the wake phrase
(switched off, and the end-to-end check through the energy gate was never run),
and the Automation consent prompt, which has still never been observed because
every terminal used to test already held the grant.

**`REL-001` — the first release.** What it needed: `QA-006` passed (2026-08-07),
an ADR for the retrieval decision (now [ADR 0012](adr/0012-fused-local-retrieval.md)),
a `1.0.0` section in the changelog (now written, and undated), and a decision on
whether the release ships the app or the instructions to build it. Only the last
one is left, and then the act of cutting the release itself — neither is a
document. The update mechanism argues for shipping the app: it installs only a
bundle signed with the same key, which a tagged source release cannot offer.
Notarisation is not available for a self-signed identity, which constrains what
that app can be.

Do not configure WhatsApp, Drive, automatic microphone, or workflow activation
before their permission and validation gates pass. Mail and Calendar are the one
exception: no credential is held, nothing is deleted or marked read, and the
switch is off until somebody turns it on. The two things that write — an event
created from a button, and a message sent from one — are not gates this paragraph
relaxes, because no tool the model can call reaches either. A message does leave
the Mac, which nothing else here does, and that is the reason its card shows
every recipient in full and its approval can never be automatic.
