# Project status

Last updated: 2026-10-17

## Final integrated v2 candidate — 2026-10-17

Source integration is in the isolated `v2-research` worktree. The final candidate
combines brain controls, research, native voice/AppIntents, visual identity,
context compaction and the executor/network/persistence corrections. The exact
continuation anchor remains
[EVIE_RESEARCH_DELIVERY](implementation/EVIE_RESEARCH_DELIVERY.md).
This is a source/evidence checkpoint, not a claim that final installation,
publication or a release has already occurred.

### Context and current contracts

- PC/Qwen operational context: **200,704 tokens**, with output and framing
  reserved from that capacity. The architectural model limit is not the
  operational budget.
- LensVLM: **131,072 tokens qualified** on the target Mac, synchronized between
  client context and runtime KV cap. Runtime controls: eight-bit KV, prefill step
  512, MLX allocator cache 256 MiB and profile timeout 900 seconds. The synthetic
  run used **127,527 input + 38 output tokens**, retrieved **5/5 target items**,
  retained **2.4 GiB minimum sampled free memory** (10% margin), and reached **13.8 GiB
  MLX-reported peak memory** over **392.31 seconds**. This is measured workload
  evidence, not a claim that every workload or architectural ceiling fits.
  See [MODEL_TUNING](MODEL_TUNING.md) and the release notes.
- [Adaptive compaction](CONVERSATION_CONTEXT.md) keeps the complete visible
  history, summarizes only a prepared in-memory request and never silently cuts
  the current question. Summaries are fallible data and preserve visual origin;
  cache/revocation are bound to conversation, profile and budget.
- Compact brain controls apply explicit model changes to the next turn of the
  same conversation. Profiles support local/remote endpoints and custom labels.
  Saving a key preserves other drafts and fresh file changes field by field.
- Research has two configurable shortcuts, a revocable 15-minute lease and
  bounded clipboard/answer-entry routes. Native voice selection/calibration and
  public AppIntents do not use private Siri services. Enabled capabilities still
  require real OS permission and the existing action authority.
- The local launcher reuses only compatible model/memory options and reconciles
  changed options on next use. Web DNS/redirects are pinned to public addresses
  separately from the private model transport. Current decisions are ADRs
  **0020–0027**; earlier records below are historical where they differ.

### Executed evidence, with scope

- Earlier complete checkpoint: **1,454 tests / 134 suites passed**, with one
  intentional known-issue fixture in Mail timeout coverage. This precedes the
  last changes and is not substituted for the final full-suite run.
- Executor/policy/broker/clipboard: **112 tests passed** after reproduced red
  runs. Guards cover focus/ownership/secure-field changes after awaits and per
  input step. A synchronous check and the OS input event are not an atomic OS API.
- Signed release checkpoint: build with warnings as errors in **210.54 s**;
  generated metadata for **3 AppIntents / 3 AppShortcuts**; actual perform routing,
  busy/not-ready/Unicode guards passed. This checkpoint precedes the final freeze.
- Native synthetic screen→Qwen→named clipboard→real executor→independent
  field/radio fixture readback: **68**, **4 actions**, **43.743 s** total, no
  general clipboard use or auto-approved confirmation. The run predates the last
  restrictive answer-entry policy; the final signed bundle rerun is a separate gate.
- Context probe through the real PC client: **46,247 → 16,374 characters** inside
  a **32,768-character** request budget, current question identical, old synthetic
  fact retained and next preparation cache reused. This is one observed semantic
  case, not a proof that every summary preserves every fact.
- Web/compaction integrated checkpoint: **23 tests / 3 suites passed in 4.238 s**;
  live synthetic Swift.org search/read passed in **1.900 s**, six results and
  ten prohibited destinations refused. Stream/gzip, DNS cancellation/pinning,
  redirects and real transport interruption have isolated regressions.
- Settings remained responsive in the real-view-model regression while an
  attributes lookup was deliberately blocked for 250 ms. The old implementation
  failed this case; the serial coalesced worker and cached guide update passed.
  Focused status/guide/key/rebase coverage: 38 tests / 4 suites passed.
- [Settings boundary regression](MODEL_SETTINGS_VALIDATION.md): stale-write bug
  reproduced before the fix; **3 field-rebase tests** and real view-model/JSON
  cases passed, including edits during await and refused newer schema. Keychain
  storage is in memory in this regression, not a personal Keychain dialog test.
- [Local launcher boundary regression](LOCAL_BRAIN_VALIDATION.md): actual OS
  processes, HTTP bearer enforcement, per-launch key rotation, 32K/A→64K/B and
  model-only restart, same-profile reuse, foreign listener preserved, real MLX
  **256 MiB** allocator bootstrap; **7.70 s** including standalone compilation.
  No model weights are loaded by that fixture.
- Native voice diagnostic exercised actual AVFoundation buffers and SpeechAnalyzer
  on synthetic audio; temporary five-transcription persistence passed. The wake
  lifecycle race was reproduced red and corrected green against the real microphone,
  without recording audio/transcripts. User calibration still needs five real calls.
- Public ancestry scan: **132 commits** checked for the owner's private host and
  tailnet identifiers. Existing repository image OCR: **20 PNG/JPEG**, no matches
  and no OCR errors for the private patterns held only in memory. The final
  snapshot, reachable ancestry and signed artifact are checked separately.

### Draft final gates — replace with executed evidence before publishing

- Final full-suite result: **1,549 tests in 146 suites passed (24.818 s), with one intentional known timeout-injection issue**.
- Final resource/energy measurements, including conditions: **VALOR_FINAL_A_INSERIR**.
- LensVLM qualification: completed at 131,072 tokens with the measured controls
  above; the final full-suite run covers the synchronized source defaults.
- Signed final bundle build, latest restrictive research fixture rerun,
  installation/open-state check and public release: not recorded complete here.
- Publication must use the sanitized tree parented by existing public main,
  excluding private local v2 ancestors. Runtime endpoints remain outside git
  and the bundle. Final tree/artifact/ancestry scan results belong in the ledger.

## Historical checkpoints before the integrated 2026-10-17 delivery

The entries below preserve earlier implementation decisions, test results and
then-open work. Their defaults, limitations and pending lists describe those
checkpoints; the current contracts and final validation are recorded above.

### Original Evie v2 checkpoint (manual QA still owed at that time)

Evie v2 is specified in `docs/design/2026-10-16-evie-v2-design.md`, whose
"as implemented" notes under each slice are the detailed record. Every slice in
its order — S8a, S1a–S1b, S2a–S2d, S3, S4, S5a–S5d, S6-core, S6-shell, S7,
S8b — is implemented on branch `v2` (2026-10-16), with the review and
queued-security fixes listed in the WORKLOG. Full `Scripts/test` on 2026-10-16
(M5 24 GB, macOS 27.2, Xcode 27.1): 1377 tests in 123 suites passed, 1 known
issue. ADRs 0013–0018 record the durable decisions.

### Branch `v2-files`: files and documents (2026-10-16)

Built in the worktree `evie-ai-files` from `v2` at `b97686a`, not yet merged.
Evie works like a command-line agent for everyday file tasks inside the same
authority model (ADR 0019): Mesa, Documentos, Downloads and the iCloud Obsidian
vault as one-click grants (card, first-run guide, Settings); `analyze_folder`;
document text in `read_file`; `propose_document` (`.md`, `.txt`, `.rtf`,
`.docx`, `.pdf`, new files only, Salvar / Salvar e abrir) with the opt-in
"Salvar direto quando eu pedir explicitamente"; `open_file` (documents only,
from an allowlist) and `reveal_in_finder`; file requests routed to the tools
with nothing granted. Three security findings from review fixed on the branch
(folded denylist; `open_file` allowlist; no `public.content` fallback). Full
`Scripts/test`: 1414 tests in 129 suites passed, 1 known issue (the existing
Mail one). **Owed:** manual QA on the installed app — the grant card and the
macOS prompt for each TCC folder, a `.docx` opened in Word and Pages, direct
save on and off, and a real model turn for each of the five routing requests.
Settings hook for the sidebar redesign: embed
`DocumentSettingsSection(viewModel: rootsViewModel)` in "Arquivos e pastas".

### What is done

- **The PC is the default brain.** `qwen-daily` on the owner's RTX 3090,
  reached over https on his tailnet through an exact allowlist, with a key bound
  to that host, kept in Evie's own login-keychain item and never in a file
  (ADR 0013; `Configurações › Cérebro` or `Scripts/evie-app import-pc-key`).
  Measured: text in about 2 s with thinking off; a byte-identical history prefix
  is served from the PC's cache.
- **The Mac brain is the fallback.** LensVLM 9B under `mlx_vlm.server` 0.7.8 on
  `127.0.0.1:38480`, started on demand with a per-launch key, only after asking
  ("O PC está fora. Acordar o cérebro do Mac? (~10 s, ~8 GB de memória)") unless
  the owner chose automatic, and unloaded after 10 minutes idle (ADRs 0014,
  0015, 0017). It sees but declares no tools: folders and the web are searched
  before it is asked. A conversation keeps its brain; it switches only on a
  failure before the first word.
- **"Olha a tela".** A clear request in his words, or ⌥⇧O, captures the screen
  (or the front window) with Evie's windows left out, in memory only, behind the
  violet glow: 1024 px for the PC (first token ~26 s, the projector runs on the
  PC's CPU), 1280 px for the Mac (3–6 s). One picture per PC request; a picture,
  or text read off one, never rides with tools or auto-approves a change.
- **Which brain answers, on screen.** A chip in the input bar names the brain
  the next question goes to ("Qwen 3.8 · PC", "LensVLM · Mac") with a dot for
  ready, cold or waking, and unreachable; its menu pins Automático, Sempre o PC
  or Sempre o Mac for new conversations (through `EvieBrainResolver.choose`),
  tests the connection and switches agent mode. Every answer card names its
  model and place ("Qwen 3.8 · no seu PC").
- **Agent mode.** "Deixar a Evie controlar o Mac" (Configurações › Tela e modo
  agente, off by default since 2026-10-16; ADR 0018's switch;
  `EVIE_COMPUTER_USE=0` forces it off), also on the brain chip's menu and as
  "Modo agente" in the menu bar; the chip shows an amber "Agente" while it is
  on. Settings is a sidebar window in the style of System Settings. A session starts only from a typed request, push-to-talk or a
  click — never the wake word — through a card a hand must press, and runs on
  the PC only, for at most 15 minutes and 25 actions (ADR 0016, amending 0009).
  Code refuses the denied apps (System Settings, Keychain Access, terminals,
  Shortcuts, Script Editor, Automator, Installer, password managers), password
  fields and secure input, stale observations, Evie's own windows and points on
  another app's window; it asks before confirm-word buttons, Return almost
  everywhere, browser buttons, launcher shortcuts, ⌘Q/⌘W-class chords, the
  delete class, opening links and reading the clipboard. Real input pauses the
  session; Parar, Esc, ⌥⇧Esc, "para" and the grant's end stop it.
- **The indicator.** `ScreenPresence` shows every capture and every action:
  violet glow while seeing, a reticle while observing, amber edge, highlight and
  ghost cursor while acting, a "Digitando…" chip, gray when paused, and a pill
  with the brain, the step and Parar. No capture happens before the glow is
  composited on that display; no setting turns it off.
- **S8b.** The osascript tests are opt-in integration tests for their exit
  codes; `EvieBrevityPreamble` and the model-written half of `EvieNearestTerm`
  apply only to `.gemma` profiles; skill guidance reaches every family as
  `<system-context>`; the per-brain copy is complete. The checklist's eval cases
  are in `evals/README.md` § "v2 checklist coverage".

### What needs manual QA by the owner

None of these could be done without the installed app and a person at the Mac
(no agent launched the app UI, to keep its permission prompts with the owner):

- **Install and permissions (S7):** `Scripts/evie-app install`, rebuild twice
  and confirm the TCC grants survive; a first run on an empty
  `~/Library/Application Support/Evie`; the first-run guide's rows, including
  "Chave do PC" (the import's keychain prompt) and "Cérebro" (Testar conexão).
  [VERIFY] whether the key item is read without a prompt after a rebuild.
- **Brains (S2d, S3):** with no key, "sem chave", then the import, then three
  green rungs; with the PC off, `.ask` shows the wake card and `.automatic`
  answers from the Mac with a notice; the in-app "Acordando o cérebro do Mac…".
- **The screen (S4, S6):** Safari plus a PDF answered in one look with Evie's
  overlay absent; ⌥⇧O; the Screen Recording card; the Mac profile; every
  indicator state on the internal and an external display, over a full-screen
  app, with Reduce Motion, and the CPU budget in a release build.
- **Brain chip and Settings (2026-10-16):** see the WORKLOG entry "the brain
  on screen, Settings as a sidebar" for the list — the chip's menu opening from
  the non-activating overlay, its ticks, the sidebar's width and selection in a
  real window, and the old 660 × 580 saved frame growing to 860 × 640.
- **Speed:** the installed `config.json` (written 2026-10-16 21:51) sets
  `default_reasoning` to `xhigh` for both brains, so every answer thinks at
  "Máximo" before its first word; the built-in is off. The chip's menu shows
  "Raciocínio: Máximo…" and opens Configurações › Cérebro, where the owner can
  set it back to Desligado. Evie did not change the file.
- **Agent mode (S5d):** eval cases 26–28 — the Notas script, "copia esse
  parágrafo", Esc and the mouse pause, a real password field, Mail's Send,
  Spotlight + "Terminal" + Return, and Raycast / Alfred panels where installed;
  the local `NSEvent` monitor live; whether a VoiceOver user can approve.

### Host-side issues to report (not Evie's to fix)

Found during the v2 design pass; rechecked read-only on 2026-10-16 where this Mac
could see them, without reading any secret:

- **`THINKING_SAMPLER` has `min_p` 0.0** in the PC stack's `gateway-edge.py`
  (seen in the local clone `~/Developer/local-ai-3090-stack`), which regresses
  that stack's ADR-004 sampler guard against long-generation degeneration. The
  owner's call: `min_p = 0.05`.
- **Stale `PROFILES`** (`qwen-turbo`, `qwen-quality`) in `local-ai-control.py`
  (both clones) and in the "Carregar turbo / qualidade" buttons of
  `iot-home-control/windows/shutdown_server.py`: aliases the gateway no longer
  serves.
- **The Pico Wake-on-LAN endpoint** listens on plain HTTP (port 8080 behind a
  router port-forward, per `pico/config.example.py`) on the public internet with
  a short key. The real key's length was not re-read.
- **The `com.crias.omlx` LaunchAgent is broken:** its `ProgramArguments` name
  `…/Local Studio/runtime/venvs/omlx-latest/bin/omlx`, which no longer exists.
  A process it started earlier (`omlx-server`, since 08:29 on 2026-10-16) still
  listens on `127.0.0.1:8477`, so it will fail at the next login. Evie never
  uses that port. Whether to remove the plist is the owner's choice.
- The stale 22-character key in the PC stack's `opencode.json` (not re-read).
- An "Acordar PC" button in Evie is deferred: its credentials and domain are not
  on this Mac.

### Open engineering items

- The executor's half of queued finding #11: per-event front-app and
  secure-input checks (11b), the window owner before every CGEvent pointer
  action (11c), a confirmation for `clipboard_write` (11d).
- The tool-result fence (`EvieTool.swift`) still uses fixed markers without
  neutralising.
- A known timing-sensitive test is being fixed in the Fix phase.
- `tools-mac-lensvlm-001` (eval case 12) gates tools on the Mac; last measured
  failing (malformed XML), not rerun.
- [VERIFY] items left in the design doc: the 160×44-point launcher panel
  estimate, the scroll direction with natural scrolling, the 300 ms settle in
  every app, the `.screenSaver` level over full-screen apps.

**Next action:** reinstall (`Scripts/evie-app install`) so the owner gets the
brain chip and the new Settings, check them by hand as listed above, and decide
the reasoning level; then the Fix phase (11b–11d and the timing test).

## Repository hygiene

The tracked documentation no longer names external coding tools as project
contributors. Git history contains only the owner's author and committer
identity and no additional attribution trailers. A local history rewrite is
prepared; remote
branches and tags still require an explicit force-update after review.

## Current phase

*Written before v2; where it disagrees with the v2 section above (the brain, the
loopback port, what leaves the Mac), the v2 section holds.*

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
- `OpenAICompatibleClient` (renamed from `TurboFieldfareClient` on 2026-10-16)
  streams Chat Completions from the profile in use — by default, since v2 S2a,
  the PC gateway's `qwen-daily` (`EvieModelProfileSet.builtIn`) — supports
  cancellation, and can declare tools and reassemble the calls the model asks
  for. Since v2 S1a it passes every endpoint through `ModelTransportPolicy`
  (loopback over http, or https to the allowlisted PC gateway with a key bound to
  that host, ADR 0013), reads that key from the login keychain, never sends it
  over http, and refuses redirects. Every client is built by `ModelClientFactory`.
  Since S1b each request carries `TurnOptions` (reasoning, output cap,
  readiness), reasoning streams as `.reasoningDelta` and is never shown, and
  images travel as data-URL content parts that are never persisted. It never executes
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
- The composition root talks directly to the model server only for this
  reversible slice. ADR 0006 records why this is not the future trust/lifecycle
  boundary; ADR 0013 replaces its loopback-only and no-credential clauses.
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
- ~~**`REL-001`: there is no release.**~~ **Cut 2026-08-07 as `v1.0.0`.** The
  owner decided it ships the application rather than the instructions, on the
  argument the update mechanism makes for itself: it installs only a bundle
  signed with the same key, which a source tag cannot offer. The download is the
  9.9 MB bundle; the roughly 13 GB model is not in it and is fetched by
  `Scripts/evie-runtime setup` on the machine that will run it.
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
  it refuses every update. It has now been run here: the installed bundle reports
  `Authority=Evie Dev`, not an ad-hoc signature, which is what made `v1.0.0`
  publishable at all.
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
- **CI cannot build the shell or run the tests, and builds only `EvieCore`.**
  `EvieShell` needs the macOS 27 SDK — `EvieVisionDescriber` uses `Attachment`
  from FoundationModels, which the 26 SDK does not define, and the
  `if #available(macOS 27, *)` around it decides what runs rather than what
  compiles. GitHub's newest image is macOS 26.5 with Xcode 26.6. Building
  `EvieCoreTests` alone and running with `--skip-build` was tried and works on
  this Mac's Command Line Tools, where the bundle is `EvieCoreTests.xctest`, and
  fails on a runner's full Xcode, which looks for a whole-package
  `EviePackageTests.xctest` that a single-target build never produces. So the
  618 tests run on one machine. A macOS 27 runner image closes this.

## Next recommended action

**Evie v2, on branch `v2`** (spec: `docs/design/2026-10-16-evie-v2-design.md`).
Done as of 2026-10-16: S8a, S8b item 1 (the osascript tests are gated), S1a
(transport rename, policy, keychain credentials, one client factory) and S1b
(per-turn options, thinking parameters, images as content parts, reasoning kept
apart from the answer, truncation detection, `ModelClientError`, deadlines) and
S2a (config schema v2 with model profiles, v1 migration with a `.v1.bak`, a v2
store and settings save, `evie-runtime configure` seeding v2). The default and
every fallback is now the built-in PC profile (`qwen-daily`), whose key
reference is Evie's own keychain item; that item is created by S2d's import.
S2c (per-turn brain resolver and failover, ADR 0014) is done: each conversation
is resolved before its turn is built and pinned to its brain, a missing PC key
or a PC the probe finds out moves a new conversation to the Mac profile, and a
turn that fails before its first delta is rebuilt for the next brain and retried
once, all under the Mac-fallback choice (`.ask` asks "O PC está fora. Acordar o
cérebro do Mac? (~10 s, ~8 GB de memória)"). This replaces the launch-time move
of review finding #1. Measured in S1b: the PC gateway
sends its response headers only with the first chunk, so the headers deadline is
a first-token deadline. Verified in S2a: `qwen-daily` reports a 200704-token
context window and 32768 max tokens; port 38480 is free. S2b (readiness probe
and 30 s cache, refreshed at launch, on activation and on network changes) is
done; verified in S2b: `/health` sits at the gateway's origin and needs no key,
and `/v1/models` reports `loadState`/`active` per alias. Findings #1 (the
interim above), #5, #6, #7 and #8 of the 2026-10-16 adversarial review are fixed
(see the WORKLOG). S2d is done (2026-10-16): Configurações › Cérebro picks the
preferred brain and the Mac fallback, edits each profile with the endpoint
checked live, runs "Testar conexão" (three steps with times), and saves the PC
key into Evie's own keychain item, pasted or imported once from
`local-ai-3090`; `Scripts/evie-app import-pc-key` does the import from a
terminal; the status line and error card name the brain that answered. Still
owed for S2d: its manual QA (fresh install → "sem chave", import, three green
steps; PC off with `.automatic` and `.ask`), which needs `Scripts/evie-app
install`, and two [VERIFY]s on whether macOS prompts when Evie reads her item
after a rebuild or after the script created it (`docs/SECURITY.md`). S3 is done (2026-10-16, ADR 0015): `mlx_vlm.server` 0.7.8 serves
LensVLM's images (the pre-check's option 1), and `EvieLocalBrainLauncher` starts
it on demand on 127.0.0.1:38480 ("Acordando o cérebro do Mac…", ready in about
6 s with the weights cached), checks that the listener is the configured server
before every turn, refuses a held port or under 8 GiB free, and stops it after
10 idle minutes or at quit; `Scripts/evie-brain` is the manual path and
`evie-shell --brain-check [--idle]` the command-line QA. Measured: footprint
8,148–8,243 MB, 0.3% CPU idle, a tiny-image answer in about 2.1 s. Requests to
it send `context_management: []`, since 0.7.8 otherwise compacts the
conversation itself. Still owed for S3: the in-app status line and ask card
(UI not launched), a start with the weights not in the page cache, and the
LensVLM tool-call eval (tools stay off). The first-run guide's key and brain
rows (S7) are done (2026-10-16). S4 (screen perception) is done (2026-10-16; see
"Evie v2" above). S5a (the pure computer-use core in `EvieCore`, ADR 0016) and
S5b (observe-only), S5c (the input executor, ADR 0018) and S5d (the cards,
takeover and kill switches) are done (2026-10-16). Next: S8b and the Fix phase.

**Evie v2, S7 (packaging, install, permissions) — partly done on `v2-packaging`,
2026-10-16, merged into `v2` the same day.** Signing is pinned to the "Evie Dev"
certificate's SHA-1 with the designated requirement asserted; `install` opens
`~/Applications/Evie.app`, `run` opens only that copy and `evie-runtime launch`
hands over to it, starting no model (the loopback Gemma for the `custom`
profile is `evie-runtime launch-custom`); the first-run permission checklist
has its five system rows. The v2 config seeding came with S2a on `v2`. The
"Chave do PC" row (attributes-only status, "Importar" from `local-ai-3090`) and
the "Cérebro" row (Testar conexão) are in, on `v2`, 2026-10-16, so a first
launch can import the key and test the PC without visiting Settings. The bundle
from `Scripts/evie-app build` passes `codesign --verify --deep --strict` and
carries the pinned designated requirement (2026-10-16). Open: the manual QA in
`docs/MACOS_RUNTIME.md` (grants surviving two rebuilds, a first run on an empty
support directory, each row's button, the import prompt), which needs the owner
to run `Scripts/evie-app install` — nothing is installed in `~/Applications` on
this Mac today, and Evie's own key item does not exist yet.

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

**`REL-001` — the first release. Cut 2026-08-07 as `v1.0.0`.** It needed
`QA-006` passed (2026-08-07), an ADR for the retrieval decision
([ADR 0012](adr/0012-fused-local-retrieval.md)), a `1.0.0` section in the
changelog, and a decision on whether the release ships the app or the
instructions to build it. The owner chose the app, on the argument the update
mechanism makes for itself: it installs only a bundle signed with the same key,
which a tagged source release cannot offer.
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
