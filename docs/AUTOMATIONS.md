# Automations

Status: recommendation, for a decision. Supersedes the Node-RED design previously
recorded under this name; that design is kept as an appendix because most of it
survives the change of engine.

## Se for para escolher hoje

Fique com os Atalhos da Apple: eles enumeram em 11–26 ms, não deixam nenhum
processo da Evie ligado, e dão acesso a **365 ações do sistema mais 215 ações de
apps** que existem hoje nesta máquina — coisa que o Node-RED não alcança de jeito
nenhum. O preço é que a Evie **não consegue montar um atalho sozinha do começo ao
fim**: ela escreve e assina o arquivo, mas instalar exige um clique seu, e o
`shortcuts sign` aceita qualquer plist sem conferir nada, então "assinou" não
quer dizer "funciona". Se o que você quer é ela *criando* automações sozinha e
sem você por perto, nenhuma das duas entrega isso hoje — o Node-RED chega mais
perto no papel, e cobra um servidor Node ligado o tempo todo por isso.

## Recommendation

**Make macOS Shortcuts the place a workflow is built, and Evie the place it is
triggered.** Evie ships a `run_shortcut` tool and an *Automações* pane; the visual
editor is Shortcuts.app, which the user already owns, already knows, and which
Apple maintains. This is recommended over Node-RED because the constraint is
binding: Node-RED is a resident Node.js HTTP server with a browser editor, and
nothing about removing Docker removes the residency. Shortcuts costs **zero
resident processes belonging to Evie**, enumerates in 26 ms, and invokes in about
90 ms — measured below. The cost of the recommendation is real and stated in full:
Shortcuts has no event triggers Evie can subscribe to, so scheduling has to be
Evie's own `launchd` job, and a shortcut that asks the user a question **hangs
forever** when invoked from the command line, which Evie must defend against with
her own timeout.

Everything below was run on this Mac on 2026-08-06 unless labelled otherwise.

Hardware and OS for every measurement in this document:

```
$ sw_vers; uname -m; sysctl -n machdep.cpu.brand_string hw.memsize
ProductName:     macOS
ProductVersion:  27.0
BuildVersion:    26A5388g
arm64
Apple M5
25769803776        # 24 GB
```

## What Evie already has

Before adding anything, it is worth being precise about what is already built,
because part of the answer is "she has most of this".

- `Sources/EvieCore/EvieSkill.swift` — markdown files with front matter (`nome`,
  `quando`), matched to a question by word overlap, capped at two skills and 6,000
  characters per turn. Its doc comment is explicit that a skill is *instructions,
  not code*, and that giving a skill the ability to carry a command "would undo"
  the project's containment work, and if ever needed "should be a separate
  mechanism with its own confirmation, not a field on this one."
- `Sources/EvieCore/EvieAgentLoop.swift` — a bounded tool-calling loop, four
  iterations, four calls per iteration, with tools withdrawn on the last pass.
- `Sources/EvieCore/EvieTool.swift` — the tool-definition shape.
- `Sources/EvieCore/SecureProcessRunner.swift` — already launches one bounded
  child process with no shell, no inherited environment, no inherited descriptors,
  a new process group, and a timeout. This is exactly the primitive a shortcut
  invocation needs, and it already exists.
- `Sources/EvieShell/Views/SettingsView.swift` — five tabs (*Atalhos*, *Voz*, *O
  que ela sabe*, *Aparência*, *Avançado*); `SkillsSettingsView` is the pattern an
  automations pane would copy.

So the recommendation is not a new subsystem. It is one tool definition, one
process invocation, one settings pane, and a `launchd` plist. The skill mechanism
stays what its comment says it is.

## Option 1 — macOS Shortcuts

### What was measured

| Thing | Command | Result |
|---|---|---|
| Enumeration, shell | `shortcuts list` ×5 | 26, 26, 28, 25, 26 ms; exit 0; 8 shortcuts |
| Enumeration with IDs | `shortcuts list --show-identifiers` | 8 lines, `Nome (UUID)` |
| Enumeration process cost | `/usr/bin/time -l shortcuts list` | 0.02 s real, **22,167,552 B max RSS**, transient |
| Enumeration from Swift | `Process` + pipes, `nullDevice` stdin, `PATH` only | exit 0, 8 lines parsed, **79 ms** |
| Invoke an empty shortcut | `shortcuts run "Novo Atalho"` ×6 | exit 1 in 87–100 ms; stderr `Error: Atalho Vazio` |
| Same, from Swift | as above | exit 1, **151 ms** |
| Invoke by UUID | `shortcuts run "10CF80EE-…"` | identical behaviour, 87 ms |
| Invoke a missing name | `shortcuts run "ZZZ-does-not-exist-ZZZ"` | exit 1, 124 ms, stderr `Error: A operação não pôde ser concluída. Não foi possível encontrar o atalho` |
| Invoke a real, network-bound shortcut | `shortcuts run "Verificar PC"` | exit 1 after **9,890 ms**, stderr `Error: Não foi possível conectar ao servidor.` |
| Invoke a shortcut that wants a UI | `shortcuts run "Transformar Texto em Áudio" -i in.txt -o out.m4a` | **no output, no error, still running at 60 s**, killed (137); no output file written |
| Sign a hand-written workflow | `shortcuts sign -m anyone -i probe.shortcut -o signed.shortcut` | **exit 0**, 21,577-byte `AEA1` container, no UI, no prompt |
| Install that file | `open signed.shortcut`, wait 5 s | Shortcuts.app launched; shortcut **absent** from `shortcuts list` — install needs a human click |
| Read the Shortcuts store directly | `ls ~/Library/Shortcuts/`, `ls ~/Library/Group Containers/group.com.apple.shortcuts/` | `Operation not permitted` (TCC) |

Residency, sampled with `ps -Ao rss=,comm=`:

| Process | Before any Evie-shaped use | After ~15 invocations |
|---|---:|---:|
| `siriactionsd` | 9,760 KB | 22,128 KB |
| `ShortcutsViewService` | 5,552 KB | 36,688 KB |
| `ShortcutLiveActivityWidgetExtension` | absent | 43,280 KB |

Both surviving services are owned by `launchd` (`com.apple.siriactionsd`,
`com.apple.WorkflowKit.ShortcutsViewService`), and `siriactionsd` was started at
10:57 today — hours before any of this work, by the operating system, for its own
reasons. **Evie adds no resident process of her own.** She does warm up machinery
that macOS then holds for a while and reaps on its own schedule; after 20 s idle
it had not returned to baseline. That is the operating system's memory, not
Evie's, but it is honest to say it is not free.

For scale, on this same Mac at the same moment: Evie's shell was 90,112 KB, and
its TurboFieldfare server (loaded, idle) 4,080 KB.

### What this means

Enumeration works, unsandboxed, with no permission prompt, in 26 ms. That is
cheap enough to run every time the pane opens rather than caching it, which
removes a whole class of staleness bug. Names come back in the user's language
(`Capotar PC`, `Resumir PDF`) — these are *his* shortcuts, so the list is
immediately meaningful, which is the main thing a settings pane has to achieve.

Invocation is a plain `posix_spawn` of `/usr/bin/shortcuts` and works from Swift
`Process` with stdin closed and a two-entry environment, which is what
`SecureProcessRunner` already does. Exit code 0/1 is the contract.

Input and output pass by **file path**, not by pipe: `--input-path` and
`--output-path`, with `--output-type` taking a Uniform Type Identifier. Nothing
comes back on stdout. Evie would write the input to a temporary file, run, and
read the output file — which fits her existing containment model well, because the
temporary directory is a root she controls rather than an arbitrary path.

The store on disk is TCC-protected and unreadable, but the CLI enumerates it
anyway. So the CLI is not a convenience wrapper around a file Evie could read
herself; it is the only door, and it is a door that is open.

Signing is the surprise. `shortcuts sign` turned a plist I wrote by hand into a
valid signed `.shortcut` container with no UI and exit 0. **Evie can author a
workflow file.** She cannot install it — opening it launched Shortcuts.app and the
shortcut never appeared in the list, because someone has to click *Adicionar*.
That is not a limitation to work around; it is the consent gate the rest of this
project would have had to build.

### The failure modes, which are the important part

1. **A shortcut that wants the user blocks forever.** `Transformar Texto em
   Áudio` produced no stdout, no stderr, and no exit after 60 s. There is no way
   to tell this apart from a slow shortcut from the outside. Evie must impose her
   own timeout and kill the process group — which `SecureProcessRunner` already
   does. Without that, one bad shortcut is a hung tool call.
2. **Errors are localised.** `Error: Atalho Vazio`, `Não foi possível conectar ao
   servidor.` These strings are in Portuguese because the Mac is in Portuguese.
   They must be shown to the user verbatim and **never parsed**. The only reliable
   signal is the exit code.
3. **Everything non-trivial is slow and looks identical to a hang.** The one real
   shortcut that completed took 9.9 s to fail on a network timeout. A progress
   state in the overlay is not optional.
4. **Names are not unique and are user-editable.** `shortcuts run` accepts either
   a name or a UUID; the UUID is stable and the name is not. Store the UUID, show
   the name.
5. **Permission attribution is inherited.** A shortcut that reads Contacts will
   raise the TCC prompt against whoever spawned the CLI. Measured here, that was
   Terminal, which already holds automation permission, so no prompt appeared.
   **Not measured: what prompts appear when Evie.app is the responsible process.**
   This is the single biggest unknown and is listed again below.

### What was not measured

- **A successful end-to-end run.** This Mac's library contains eight shortcuts:
  one empty, one a template gallery, two that shut down or reboot another machine
  (deliberately never run), one that failed on a network timeout, and one that
  hung. There was no non-interactive shortcut available to prove the
  input → output path works. I could author one but not install it, because that
  needs a click. **This must be measured before committing to the direction**, and
  it is a ten-minute test once one shortcut exists.
- Prompts raised when Evie.app rather than Terminal is the responsible process.
- Behaviour under Focus, screen lock, or on battery.
- Concurrency: what happens when two `shortcuts run` invocations overlap.
- Whether `--output-type` reliably coerces text (`public.plain-text`).

## Option 2 — Node-RED without Docker

**Not measured. Nothing was installed on this Mac.** What follows is from the
Node-RED documentation, plus one measurement of the Node.js runtime underneath it
that I *did* take here.

Documented: `npm install -g node-red` pulls "227 packages"; `node-red` starts and
prints `Server now running at http://127.0.0.1:1880/`; the editor is a browser
pointed at that port; the editor and admin API are **unsecured by default** and
securing them is a documented configuration exercise; autostart is a service
registration (`systemctl enable nodered.service` on Linux, a LaunchAgent here);
and on memory-constrained devices the docs tell you to cap the heap with
`node-red-pi --max-old-space-size=128` or `256`.

Measured here, as a floor rather than a figure for Node-RED itself:

```
bare node, idle event loop:  RSS 38,672 KB (37.8 MB)
node + http server listening: RSS 41,408 KB (40.4 MB)
```

So an empty Node.js process that does nothing already costs more than Evie's
TurboFieldfare server does when idle, and roughly 40% of Evie's entire shell.
Node-RED is that floor plus 227 packages, a flow runtime, and an editor server.
The real number is certainly well above it; I am not going to guess by how much.

Against the constraint — *tudo embutido no app, em segundo plano, o mais leve
possível, só usando processamento quando usar a ferramenta* — this fails on
"embutido" (it is a separate server with its own web UI), on "leve" (a resident
40 MB+ floor doing nothing), and on "só usando processamento quando usar" (it
listens continuously, which is the entire point of it). Removing Docker changes
the packaging and none of that.

There is one honest counter-argument, and it is the strongest thing that can be
said for Node-RED: **it is the only option here that can be triggered by an
external event.** A webhook from a phone, an MQTT message, a WhatsApp bridge, an
inbound email — these require something listening, and nothing that listens can
also be non-resident. If those triggers turn out to be the point of the feature,
this recommendation is wrong and the constraint has to be renegotiated rather than
engineered around. That trade is set out explicitly below.

## Option 3 — steps inside Evie herself

A third reading: an automation is a skill with steps, run by the existing agent
loop. She already has the loop, the tools, the bounded iteration count, and a
skills folder.

This is attractive and I think it is wrong as the *primary* answer, for two
reasons drawn from the code rather than from taste.

The first is written in `EvieSkill.swift`: a skill deliberately carries no
executable content, and the comment says a mechanism that does "should be a
separate mechanism with its own confirmation." Adding a `passos:` key that runs
things would be exactly the change that comment forbids.

The second is that the agent loop is the wrong shape for a workflow. It is capped
at four iterations, tools are withdrawn on the last pass, and the model decides
what to call. A workflow is deterministic by definition — the same steps, the same
order, every time — and a model choosing steps is not a workflow, it is an answer
that happens to have side effects. The existing comment in `EvieAgentLoop.swift`
measures one tool at 20 s and a three-tool chain at 37 s; a five-step automation
through the model would be minutes, and would sometimes do something different.

Where this option *is* right: Evie deciding **which** shortcut to run and **what
to pass it**. That is a judgement call, it is what she is good at, and it is the
half of the problem Shortcuts cannot do. Which is why the recommendation is a
`run_shortcut` tool inside the loop she already has, and not a step interpreter.

## Option 4 — AppleScript, Automator, launchd

Measured here:

```
osascript -e 'return 1+1'                                55, 76, 79 ms
osascript -e 'tell app "Finder" to return name of home'  138, 184, 119 ms (exit 0)
```

**AppleScript / `osascript`** costs ~60 ms for a trivial script and ~140 ms once an
Apple Event crosses to another app. Nothing resident. Its value is reaching apps
that expose no Shortcuts action, and it is the natural escape hatch — but it needs
per-target-app Apple Events permission (`MACOS_RUNTIME.md` already defers this as
"Apple Events for specific target applications"), and it is a scripting language
the user would have to write rather than draw. It belongs as a fallback action
type, not as the automation surface.

**Automator** is present (`/usr/bin/automator`) and is Apple's previous-generation
answer. It is superseded by Shortcuts, gets no new actions, and choosing it now
would be choosing the deprecated one of two Apple options. No reason to.

**`launchd`** is the right scheduler and there is no competitor. `launchctl list`
reports 562 jobs already loaded on this Mac, which is the point: this is how macOS
schedules everything, and a user LaunchAgent adds one more entry that costs nothing
until it fires. The `launchd.plist` man page documents `StartCalendarInterval`
(wall-clock), `StartInterval` (periodic), `WatchPaths`, and `QueueDirectories`
(a folder gaining a file) — which together cover "every morning at eight", "every
half hour", and "when something lands in Downloads" without a single resident
process. `MACOS_RUNTIME.md` already commits to `SMAppService`/user LaunchAgent
registration rather than root services, so this is consistent with the existing
plan and not a new dependency.

`WatchPaths` is worth flagging as the quiet win: it is a filesystem trigger with
no poller, which is exactly what the "Downloads staging" workflow in the appendix
needs and what the earlier design was going to spend a Node-RED node on.

## The trade-offs this asks him to accept

Stated plainly, because these are the reasons someone might say no.

1. **No external event triggers.** No webhooks, no MQTT, no inbound email or
   WhatsApp, no phone-pushed location. Every one of those needs something
   listening, and the constraint forbids something listening. Triggers reduce to:
   the user asks Evie, the user presses a key, or `launchd` fires on a clock or a
   folder. If the automations he actually wants are event-driven, this
   recommendation does not deliver them and no amount of engineering makes it.
2. **The workflow editor is not Evie's.** Building a workflow means Shortcuts.app
   opening. Evie can list, run, and even author, but the canvas is Apple's window,
   not a panel inside the overlay. This is arguably the most "Apple ecosystem"
   outcome available — it is literally Apple's editor — but it is not the single
   integrated surface Node-RED-in-a-panel would have been.
3. **Installing a generated shortcut needs a click.** Evie can write and sign the
   file; the user opens it and confirms. Good for safety, an extra step for flow.
4. **Errors are opaque and localised.** She can say *the shortcut failed* and show
   Apple's sentence. She cannot say *step 3 failed because the token expired*.
   Node-RED has a debug pane; this has an exit code.
5. **No partial state, no retry, no idempotency.** A shortcut either finished or
   did not. The reliability rules in the appendix — run state, idempotency keys,
   reconciling timeouts — mostly do not survive, because there is nothing to hold
   the state in between invocations.
6. **A dependency on Apple.** If a Shortcuts action he needs does not exist, the
   answer is `osascript` or nothing.

What is bought in exchange: no Docker, no server, no port, no browser, no npm tree,
no login item, no resident memory, a visual editor that already exists and that he
already uses, and roughly one week of work instead of a subsystem.

## What it would look like in Evie

**Menu.** One entry in the status menu, above the separator that precedes
*Encerrar Evie*: **Automações** — opening the settings window on its pane. Not a
submenu listing shortcuts: a menu that runs things is a menu that runs the wrong
thing when the cursor slips, and shortcuts have destructive names like *Capotar
PC* sitting next to *Resumir PDF*.

**Settings pane.** A sixth tab beside *O que ela sabe*, labelled **Automações**,
`systemImage: "wand.and.rays"`, built like `SkillsSettingsView`:

- a `Section` listing what `shortcuts list --show-identifiers` returned — name
  shown, UUID stored, a toggle per row for *ela pode chamar* (default **off**, so
  the model reaches nothing until the user says so, matching how
  `fileChangesEnabled` and `webSearchEnabled` already work);
- optionally a *quando* line per enabled shortcut, in the same trigger-word style
  as a skill's front matter, so the model knows when it is relevant;
- a footer in the house voice: *Os atalhos são seus e vivem no app Atalhos. A Evie
  só pode chamar os que você marcar aqui — ela não cria nem apaga nada.*
- two buttons mirroring the skills pane: **Abrir o app Atalhos** (`shortcuts
  view`) and **Reler a lista** (26 ms, so it is instant);
- an empty state that explains what a shortcut is, since the pane is useless
  until one exists.

**Triggering.** Three ways, in order of how much they cost to build:

1. *She is asked.* "Evie, resume esse PDF" → the agent loop is offered
   `run_shortcut` with only the enabled shortcuts in its enum → she calls it with
   an argument → `SecureProcessRunner` spawns `/usr/bin/shortcuts run <uuid>
   --input-path <tmp> --output-path <tmp>` with a timeout → the output file comes
   back as an answer or an artifact.
2. *A key is pressed.* `EvieShortcut` and `GlobalHotKeyController` already bind
   keys to actions; a shortcut UUID becomes another bindable action. No model in
   the path, so it is ~100 ms end to end.
3. *A clock or a folder.* A user LaunchAgent per scheduled automation, written by
   Evie, with `StartCalendarInterval` or `WatchPaths`, invoking Evie with the UUID.
   Nothing resident; `launchd` holds the schedule.

**When one fails.** The exit code is the truth and the stderr string is the
explanation. The overlay raises the same card shape as an agent-loop failure
(`EvieAgentLoopFailure`), saying which automation, that it failed, and Apple's
sentence verbatim in quotes. Three distinct cases, three distinct messages:

- exit 0 → done, output shown if any;
- exit non-zero → *«O atalho "Verificar PC" não terminou»* plus the stderr line;
- timeout → *«O atalho "…" ficou parado e foi interrompido. Atalhos que fazem
  perguntas não funcionam quando a Evie os chama.»* — because that is the actual
  cause and the user can fix it by editing his shortcut.

Nothing retries automatically. A failed automation is shown once and forgotten,
which is the honest behaviour when there is no run state to resume from.

## The first slice

The smallest thing that proves the direction, and the thing that would be wrong to
skip:

**Slice 0 — one measurement, before any code.** Create one non-interactive
shortcut by hand in Shortcuts.app (Receber Entrada → Texto → Parar e Enviar) and
run `shortcuts run "<name>" -i in.txt -o out.txt` from Evie.app rather than from
Terminal. This answers the two unknowns at once: does input → output actually
round-trip, and what prompt does macOS raise when Evie is the responsible process.
Half an hour. If either answer is bad, nothing below is worth building.

**Slice 1 — read-only, no model.** The *Automações* pane: enumerate, list, toggle,
and a **Testar** button per row that runs the shortcut with no input and shows the
exit code and stderr. No agent loop, no scheduling, no authoring. This proves
enumeration, invocation, timeout, and the failure card, and it is independently
useful the day it lands.

Estimated size, by analogy with `SkillsSettingsView` + `EvieSkillStore` +
`EvieSkillsViewModel`, which is the same shape:

| Piece | Lines |
|---|---:|
| `EvieCore/EvieAutomation.swift` — the record, UUID + name + enabled + trigger words | ~80 |
| `EvieCore/EvieShortcutsCatalogue.swift` — enumerate and parse `Nome (UUID)` | ~120 |
| `EvieCore/EvieShortcutRunner.swift` — invoke via `SecureProcessRunner`, timeout, classify exit | ~150 |
| `EvieShell/EvieAutomationsViewModel.swift` | ~120 |
| `EvieShell/Views/AutomationsSettingsView.swift` | ~160 |
| Persistence in `EviePreferences` (one array) | ~30 |
| Tests — parsing, malformed names, exit-code classification, timeout | ~220 |
| **Total** | **~880** |

Deliberately *not* in slice 1: the `run_shortcut` tool (slice 2, ~150 lines given
`EvieTool` exists), `launchd` scheduling (slice 3), and Evie authoring signed
shortcut files (slice 4, and possibly never — it is the least valuable and the most
surprising to a user).

---

# Second pass — three questions the section above did not answer

Everything in this half was run on this Mac on 2026-08-06, same hardware and OS as
above. Nothing was installed. The shortcut library was `shortcuts list`-verified
before and after and is unchanged: the same eight shortcuts, same order. Every
invocation went through a Python wrapper that spawns into a new session and
`SIGKILL`s the whole process group on timeout, so no run could be left hanging;
`ps` afterwards showed no surviving `/usr/bin/shortcuts`.

## 1. "O que daria pra fazer com as automações via Apple mesmo?"

`shortcuts list` shows shortcuts, not actions, and there is no CLI subcommand that
lists actions — the four subcommands are `run`, `list`, `view`, `sign`. So the
action library had to be read out of the operating system itself. Two independent
sources agreed, which is why the number below is trustworthy.

**Source one — the string table.** `WorkflowKit.framework`'s
`Localizable.loctable` (12.1 MB, 45 languages) contains **365 keys ending in
`(Action Name)`**, all 365 of which have a Portuguese translation.

**Source two — the identifiers.** The WorkflowKit binary is not on disk; it lives
in the dyld shared cache. Scanning the whole cache
(`/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e.*`,
4.8 GB, 202,673,890 strings) for `is.workflow.actions.*` yields **365 unique
identifiers**. Two different files, two different extraction methods, the same
number.

Of those 365, **23 name a third-party service** (Bear, Drafts, Things, Todoist,
Trello, OmniFocus, Dropbox, Evernote, Instapaper, Pocket, Pinboard, Ulysses, Day
One, Skype, Fantastical, 2Do, Clear, Overcast…). None of those apps is installed
here, so treat the usable built-in library as **≈342 actions**. Grouped by their
second segment, the big families are `properties.*` (19 — read a field off a
file, an event, a contact, a web page), `filter.*` (15 — query notes, reminders,
calendar events, files), `file.*` (11), `image.*` (11), `detect.*` (10), `text.*`
(7), `dnd.*` (5 — Focus), `url.*` (3), `setters.*` (3 — write back to calendar,
contacts, reminders).

The ones that matter for Evie, each confirmed present by identifier:

| Identifier | Why it matters |
|---|---|
| `is.workflow.actions.runshellscript` | **The escape hatch.** A shortcut can run `/bin/zsh`. Anything reachable from a shell — his Obsidian vault, `git`, `ffmpeg`, MATLAB — is reachable from a shortcut. |
| `is.workflow.actions.askllm` | Apple Intelligence as a step. Apple's own bundled shortcuts use it (see below); it is the LLM call *inside* a workflow. |
| `is.workflow.actions.output` | Stop and return a value — this is how a shortcut answers a caller. |
| `is.workflow.actions.file.append` / `.move` / `.rename` / `.delete` / `.getfoldercontents` / `.createfolder` | File plumbing without a shell. |
| `is.workflow.actions.filter.notes` / `.reminders` / `.calendarevents` / `.files` | Query the Apple apps by predicate. |
| `is.workflow.actions.conditional`, `.repeat.each`, `.repeat.count`, `.choosefrommenu`, `.setvariable`, `.getvariable` | Real control flow: if, for-each, menus, variables. |
| `is.workflow.actions.downloadurl`, `.openurl`, `.url.getheaders` | HTTP requests out. |
| `is.workflow.actions.sendemail`, `.sendmessage`, `.addnewevent`, `.addnewreminder`, `.notification`, `.speaktext` | Side effects into the Apple ecosystem. |
| `is.workflow.actions.gettextfrompdf`, `.makepdf`, `.encodemedia` | Documents and media. |
| `is.workflow.actions.dnd.set`, `.dnd.getfocus` | Focus modes. |
| `is.workflow.actions.homeaccessory`, `.gethomeaccessorystate` | HomeKit. |
| `is.workflow.actions.runworkflow` | A shortcut can call another shortcut — composition. |

Notably **absent**: no screenshot action, no transcription action, no SSH action
(`WFSSHScript` appears as a parameter name but there is no `.ssh` identifier), no
generic "get contents of URL" identifier under that name.

### Which apps on this Mac publish their own actions

Modern app actions are App Intents, shipped as a `Metadata.appintents` bundle
inside the `.app`. Counting the `actions` array in every `extract.actionsdata` on
this machine gives **215 app-provided actions across 24 apps**:

| App | Actions | Examples |
|---|---:|---|
| Notes | 51 | AppendToNote, AddTagsToNotes, ApplyFormatting, AddOrRemoveNoteLock |
| Books | 28 | AudiobookSleepTimer, NavigatePageInBook, ChangeFontSize |
| Freeform | 24 | AddStickyNoteToBoard, AddTextToBoard, ChangeSelectionColor |
| Mail | 23 | ComposeMessage, ArchiveMessage, ForwardMessage, DeleteDraft |
| Preview | 17 | Export, DeletePage, AutoEnhance, Flip, Bookmark |
| Shortcuts | 15 | **CreateWorkflowAction**, DeleteWorkflowAction, CreateShortcutiCloudLink |
| Voice Memos | 14 | PlaybackVoiceMemo, CreateFolder, DeleteRecording |
| Music | 8 · Weather 6 · Maps 5 · Journal 4 · Print Center 3 | |
| Home, News, Calculator, Reminders, App Store, Tips | 1 each | |
| **Microsoft Word / Excel / PowerPoint** | 2 each | Create…, Open… — that is *all* Office exposes |
| **WhatsApp** | 5 | all Meta-AI-call plumbing (OpenMetaAI, ToggleCallingMic) — **nothing for sending a message** |

And the ones he actually lives in, checked directly:

- **Obsidian — no App Intents bundle. No Shortcuts actions at all.**
- **Google Chrome — none.** Claude, Telegram, Discord, Canva, Safari — none.
- **Notion and Figma are not installed on this Mac** (`/Applications/Notion.app`,
  `/Applications/Figma.app` do not exist).

This is the honest shape of the answer. Anything involving Obsidian, Chrome,
Notion or Figma has to go through `runshellscript`, `openurl` (Obsidian has an
`obsidian://` URL scheme), or AppleScript — not through a published action. What
Shortcuts gives him natively is **Notes, Mail, Calendar, Reminders, Files,
Preview, Freeform, Focus, Home, Music, and Apple Intelligence**, plus a shell.

### Apple ships six worked examples, on disk, readable

`WorkflowKit.framework/.../Gallery.bundle/Contents/Resources` contains six real
`.wflow` files — Apple's own shortcuts, in the exact format Evie would have to
emit. These were read directly (they are world-readable; the *user's* library at
`~/Library/Shortcuts` is still TCC-blocked):

| File | Actions |
|---|---|
| `Haiku.wflow` | ask → askllm → showresult |
| `LeftoverRecipes.wflow` | ask → askllm |
| `MorningReport.wflow` | weather.currentconditions → filter.calendarevents → filter.reminders ×2 → askllm |
| `ActionItems.wflow` | ask → filter.notes → askllm → repeat.each → addnewreminder → repeat.each |
| `SummarizePDF.wflow` | gettextfrompdf → `com.apple.WritingTools.…SummarizeTextIntent` → showresult → share |
| `DocumentReview.wflow` | 11 actions incl. choosefrommenu ×4, downloadurl, askllm, repeat.count |

These are the ground truth for the format, and they are worth reading before
writing any of this by hand. `MorningReport.wflow` is, almost exactly, the
"briefing da manhã" from the appendix — Apple already wrote it.

## 2. "Qual a Evie vai conseguir programar sozinha sem minha ajuda?"

This is the question he cares most about, and the second-pass answer is worse
than the first pass suggested. **Neither engine lets Evie build an automation
end to end today**, but for different reasons, and the Shortcuts reason is
specific enough to fix or to accept.

### The on-disk format, well enough to emit one

A `.shortcut` file is a plist. Signed, it is an `AEA1` container (Apple Encrypted
Archive) with a binary plist starting at byte offset 12. Unsigned, the top-level
keys — taken from `Haiku.wflow`, verbatim — are:

```
WFWorkflowActions                    array of action dicts (the program)
WFWorkflowClientVersion              '4018.0.4'   (this OS's Shortcuts build)
WFWorkflowMinimumClientVersion       900
WFWorkflowMinimumClientVersionString '900'
WFWorkflowIcon                       {WFWorkflowIconGlyphNumber, WFWorkflowIconStartColor}
WFWorkflowInputContentItemClasses    array of WF*ContentItem strings
WFWorkflowOutputContentItemClasses   array
WFWorkflowTypes                      array  (empty = plain shortcut)
WFWorkflowHasShortcutInputVariables  bool
WFWorkflowHasOutputFallback          bool
WFWorkflowImportQuestions            array
WFQuickActionSurfaces                array
```

Each action is `{WFWorkflowActionIdentifier: <one of the 365>,
WFWorkflowActionParameters: {UUID: <uuid>, …}}`. Values that reference an earlier
step are not variables by name — they are **byte-range attachments into a
string**. From `ActionItems.wflow`, unedited:

```xml
<key>WFLLMPrompt</key>
<dict>
  <key>Value</key>
  <dict>
    <key>attachmentsByRange</key>
    <dict>
      <key>{127, 1}</key>                      <!-- offset 127, length 1 -->
      <dict>
        <key>OutputName</key><string>Note</string>
        <key>OutputUUID</key><string>7309E37E-…</string>
        <key>Type</key><string>ActionOutput</string>
      </dict>
    </dict>
    <key>string</key>
    <string>Here's the contents of a meeting note…&#xFFFC;</string>
  </dict>
  <key>WFSerializationType</key><string>WFTextTokenString</string>
</dict>
```

`{127, 1}` is a **character offset into the prompt string**, pointing at a U+FFFC
object-replacement character. Change one word of the prompt and every offset after
it must be recomputed. This one detail is the crux of the whole authoring
question and comes back in section 3.

### What `shortcuts sign` actually checks: nothing

The previous pass concluded "Evie can author a workflow file" from `sign` exiting
0. That conclusion does not hold. Measured, each run under a 30 s kill-timeout:

| Input | Extension | Result |
|---|---|---|
| Apple's own `Haiku.wflow`, byte-identical | `.plist` | **exit 1** — *"The file couldn't be opened because it isn't in the correct format."* |
| Same file | `.shortcut` | exit 0, 22,332 B |
| Same file | `.wflow` | exit 0, 22,331 B |
| Same content converted XML→binary plist | `.shortcut` | exit 0, 22,331 B |
| Haiku with the action identifier replaced by `zz.not.real.action` | `.shortcut` | **exit 0**, 22,346 B |
| Haiku with a junk parameter key added | `.shortcut` | **exit 0**, 22,353 B |
| Haiku with `WFWorkflowClientVersion` deleted | `.shortcut` | **exit 0** |
| Haiku with both minimum-client-version keys deleted | `.shortcut` | **exit 0** |
| `{"WFWorkflowActions": []}` | `.shortcut` | **exit 0**, 21,429 B |
| `{"hello": "world"}` | `.shortcut` | **exit 0**, 21,430 B |
| An empty dict | `.shortcut` | **exit 0**, 21,430 B |
| The literal text `this is definitely not a plist` | `.shortcut` | exit 1 — *"The data couldn't be read…"* |

Two findings, both load-bearing:

1. **`shortcuts sign` reads the file extension, not the content.** A perfectly
   valid Apple shortcut named `.plist` is rejected; garbage named `.shortcut` is
   accepted. The error message blames the format and means the filename.
2. **`sign` performs no semantic validation whatsoever.** It will happily sign an
   empty dictionary and a nonexistent action identifier. So **exit 0 from `sign`
   is not evidence that the shortcut works** — it is evidence that the bytes
   parsed as a plist. Any pipeline where Evie writes a shortcut and reports
   success on exit 0 would be reporting nothing.

Timing, and a difference worth knowing:

| Mode | Time | Size |
|---|---:|---:|
| `-m people-who-know-me` (default) | **79 ms** | 27,079 B |
| `-m anyone` ×3 | **4,208 / 2,923 / 4,148 ms** | 22,427 B |

The 50× gap is consistent with `anyone` making a network round trip to Apple's
signing service while the default signs locally — **not proven** (network was not
disabled to confirm), but it means: if Evie ever signs in `anyone` mode she must
budget ~3–4 s and handle being offline.

### Installing is still a click, and there is no back door

Three routes tested, all under timeout:

- `shortcuts run /path/to/signed.shortcut` → exit 1 in 78 ms, *"Não foi possível
  encontrar o atalho"*. It resolves names and UUIDs in the library, not paths.
- `shortcuts run /path/to/unsigned.shortcut` → same, 54 ms.
- There is no `import`, `add`, or `install` subcommand — `shortcuts --help` lists
  exactly `run`, `list`, `view`, `sign`.

`Shortcuts.app` does publish a `CreateWorkflowAction` App Intent (one of its 15),
so a shortcut can create a shortcut — but reaching it requires running a shortcut,
so it does not break the circle. **The only door into the library is a human
clicking *Adicionar* in Shortcuts.app.** Confirmed unchanged after all of the
above: `shortcuts list` still returns the same eight shortcuts.

### And the round trip is still unmeasured

**Not measured, and it is still the most important missing number:** whether
`shortcuts run <name> -i in.txt -o out.txt` actually round-trips text. It cannot
be measured without a non-interactive shortcut in the library, and putting one
there needs the click. What *was* measured: on a failing run (`Novo Atalho`, exit
1, 82 ms) the `--output-path` file is **not created** — so Evie must treat a
missing output file as a failure signal, not as an empty answer.

The three-minute test that closes this, for him to run once:

1. Shortcuts.app → new shortcut → *Receber Entrada* → *Parar e Enviar* the input.
   Name it `Eco`.
2. `printf 'ping' > /tmp/in.txt`
3. `shortcuts run "Eco" -i /tmp/in.txt -o /tmp/out.txt --output-type public.plain-text`
4. `cat /tmp/out.txt` — if it says `ping`, the whole direction is sound.

### So: what can Evie do alone, per engine

| | Shortcuts | Node-RED |
|---|---|---|
| Author the file from a description | Yes — plist, format documented above | Yes — flow JSON, publicly documented |
| Know whether what she wrote is valid | **No.** `sign` validates nothing. She would find out when the user opens it. | Yes — the admin API returns an error on a bad flow (*documented, not measured here*) |
| Install it without a human | **No.** One click, in Shortcuts.app. | Yes — `POST /flows` to the local admin API, which is unsecured by default (*documented, not measured*) |
| Run it and get an answer back | Probably — by file path, `-i`/`-o`; **unmeasured** | Yes, over HTTP |
| Delete or edit one she made | No CLI verb for it | Yes |

The honest one-line answer to his question: **on Shortcuts, Evie can write it but
not install it or check it; on Node-RED she could do the whole loop, and that is
the single strongest argument for Node-RED in this document.** It is bought with a
resident Node process, which is the thing he said he did not want.

## 3. "O quão diferente vai ser Node-RED ou Shortcuts?"

### What only Node-RED can do

- **Be triggered by something outside the Mac.** Webhooks, MQTT, inbound email,
  a message from his phone, a callback from a Cluemed or Keymatic service. All of
  these need a listener; a listener is resident by definition.
- **Hold state between steps and between runs.** Retries, idempotency keys,
  "resume where it failed". `shortcuts run` is one process that either exits or
  does not.
- **Be built, edited, deleted and inspected programmatically**, including by
  Evie, via its admin API — see the table above.
- **Show you why step 3 failed.** It has a debug pane. Shortcuts has an exit code
  and a localised sentence.
- **Speak protocols.** MQTT, Modbus, WebSocket, TCP, serial — thousands of
  community nodes.

### What only Shortcuts can do, on this Mac

- **The 365 + 215 actions catalogued above.** Notes, Mail, Reminders, Calendar,
  Freeform, Preview, Focus, Home, Music, Voice Memos — with the user's own
  permissions, already granted, no OAuth, no tokens, no API keys.
- **Apple Intelligence as a workflow step** (`is.workflow.actions.askllm`), on
  device.
- **Cost nothing when idle.** Zero processes belonging to Evie. Node's floor was
  measured in the first pass at 37.8 MB for an empty event loop.
- **Be edited by him, visually, in an editor he already has and Apple maintains.**

One correction to the first pass: **Node.js is already installed on this Mac**
(`~/.local/node22/bin/node`, v22.23.1, npm 10.9.8). So Node-RED would not add a
runtime — only 227 packages, a listener, and a port. That removes one objection
and none of the others.

### Which is faster, which is lighter

| | Shortcuts | Node-RED |
|---|---|---|
| Enumerate | **11 ms** (3 runs, warm; 26 ms cold in the first pass) | HTTP GET to a running server — *unmeasured* |
| Invoke, trivial | **91 ms** | *unmeasured* |
| Idle cost to Evie | **0 processes** | ≥37.8 MB resident, always |
| Cost to install | 0 — `/usr/bin/shortcuts` ships with macOS | 227 npm packages |
| Author a file | 79 ms local / ~3.4 s signed for `anyone` | file write |

Shortcuts is faster and lighter on every axis that was measured, and Node-RED's
numbers here are **not measured** — nothing was installed.

### Which one can an LLM write correctly on the first try

This is the axis he actually asked about, and it can be argued from measurements
rather than taste. For the same three-step automation — take text, stamp it with
the time, append it to a file:

| | bytes | nesting depth | scalar values |
|---|---:|---:|---:|
| Node-RED flow JSON, 3 nodes + tab | 529 | 4 | 31 |
| Shortcut plist, 3 actions (written below) | 3,258 | 8 | 26 |
| Apple's own `Haiku.wflow`, 3 actions | — | 8 | 44 |
| Apple's `ActionItems.wflow`, 6 actions | — | **13** | 77 |

Node-RED wins this, and by more than the numbers show:

- Its schema is **published**. Shortcuts' is not — everything above had to be
  reverse-engineered out of the OS this afternoon.
- Node-RED node types are **discoverable at runtime** through the admin API. The
  365 shortcut identifiers exist only inside a binary in the dyld shared cache,
  and **no source on this machine maps an identifier to its parameter names** —
  the parameter keys used below were recovered from the localisation table, where
  they appear as translation-key suffixes like `Rate (WFSpeakTextRate)` (575
  distinct parameter keys named that way).
- Wiring in Node-RED is `"wires": [["n2"]]` — a symbolic reference. Wiring in
  Shortcuts is `{127, 1}` — **a character offset into a prompt string**. A model
  that edits the prompt and forgets to recompute the offset produces a file that
  signs fine, installs fine, and silently substitutes the wrong text. That is the
  worst failure mode in this document, and it is inherent to the format.
- Node-RED validates on POST; Shortcuts validates nothing until a human opens it.

So: **Shortcuts is the better place for a human to build an automation and the
worse place for a model to write one.** That inversion is the real finding of this
pass, and it is exactly why the recommendation stays "the editor is Apple's, the
trigger is Evie's" — and why slice 4 (Evie authoring shortcuts) should probably
never ship.

## A worked example — *Capturar na Inbox*

Genuinely useful to him: he keeps a single Obsidian vault in iCloud, with `EU/`
as the hub. This shortcut takes text, timestamps it, appends it to
`EU/Inbox.md`, and returns a confirmation — so "Evie, anota que a reunião da IC
mudou pra quinta" lands in the vault and she can say what she wrote.

It uses `runshellscript` rather than `file.append` on purpose: the vault path
contains spaces and lives under `Mobile Documents`, and a shell script is the one
construct whose behaviour is not guessed.

**Status of this file: it is a real plist, it passes `plutil -lint`, and it
signed successfully (exit 0, 22,427 B, three runs, 2.9–4.2 s in `anyone` mode).
It has NOT been run, because running it requires installing it, which requires a
click. Since `sign` validates nothing, treat it as a well-informed draft, not as
a tested artifact.** Everything in it is corroborated from something on this Mac
except one thing, flagged inline: the `ExtensionInput` attachment that carries
*Shortcut Input* into the script. `WFSerializationType`, `WFTextTokenString`,
`ActionOutput`, `OutputUUID` and `attachmentsByRange` all come verbatim from
Apple's `ActionItems.wflow`; `Shell`, `Script`, `InputMode` and `WFOutput` are
parameter keys named in this OS's own string table; `ExtensionInput` and
`WFTextTokenAttachment` could not be found in any file on disk here, so that is
the line most likely to be wrong.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>WFWorkflowActions</key>
  <array>

    <!-- 1. A comment action. Purely documentation; shows up in the editor. -->
    <dict>
      <key>WFWorkflowActionIdentifier</key>
      <string>is.workflow.actions.comment</string>
      <key>WFWorkflowActionParameters</key>
      <dict>
        <key>UUID</key><string>1B4E9E1F-0000-4000-8000-000000000001</string>
        <key>WFCommentActionText</key>
        <string>Capturar na Inbox — recebe texto da Evie, grava na Inbox do vault com data e hora, devolve a confirmacao.</string>
      </dict>
    </dict>

    <!-- 2. Run Shell Script. Its UUID is what step 3 points at. -->
    <dict>
      <key>WFWorkflowActionIdentifier</key>
      <string>is.workflow.actions.runshellscript</string>
      <key>WFWorkflowActionParameters</key>
      <dict>
        <key>UUID</key><string>1B4E9E1F-0000-4000-8000-000000000002</string>
        <key>Shell</key><string>/bin/zsh</string>
        <key>InputMode</key><string>to stdin</string>

        <!-- The one unverified construct: Shortcut Input as an attachment.
             If the shortcut misbehaves, this is the line to fix by hand
             in Shortcuts.app (set the input pill to "Entrada do Atalho"). -->
        <key>Input</key>
        <dict>
          <key>Value</key>
          <dict><key>Type</key><string>ExtensionInput</string></dict>
          <key>WFSerializationType</key><string>WFTextTokenAttachment</string>
        </dict>

        <key>Script</key>
        <string>set -e
VAULT="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault"
INBOX="$VAULT/EU/Inbox.md"
mkdir -p "$(dirname "$INBOX")"
TEXTO=$(cat)
[ -n "$TEXTO" ] || { echo "nada para capturar"; exit 0; }
printf -- "- %s — %s\n" "$(date '+%Y-%m-%d %H:%M')" "$TEXTO" &gt;&gt; "$INBOX"
echo "capturado na Inbox: $TEXTO"</string>
      </dict>
    </dict>

    <!-- 3. Stop and Output. The {0, 1} range and the U+FFFC character in
         `string` are how a shortcut references step 2's result — this is
         the byte-offset wiring described above, copied from Apple's own file. -->
    <dict>
      <key>WFWorkflowActionIdentifier</key>
      <string>is.workflow.actions.output</string>
      <key>WFWorkflowActionParameters</key>
      <dict>
        <key>UUID</key><string>1B4E9E1F-0000-4000-8000-000000000003</string>
        <key>WFOutput</key>
        <dict>
          <key>Value</key>
          <dict>
            <key>attachmentsByRange</key>
            <dict>
              <key>{0, 1}</key>
              <dict>
                <key>OutputName</key><string>Shell Script Result</string>
                <key>OutputUUID</key><string>1B4E9E1F-0000-4000-8000-000000000002</string>
                <key>Type</key><string>ActionOutput</string>
              </dict>
            </dict>
            <key>string</key><string>&#xFFFC;</string>
          </dict>
          <key>WFSerializationType</key><string>WFTextTokenString</string>
        </dict>
      </dict>
    </dict>

  </array>

  <!-- Envelope. Values copied from Apple's Haiku.wflow on this machine. -->
  <key>WFQuickActionSurfaces</key><array/>
  <key>WFWorkflowClientVersion</key><string>4018.0.4</string>
  <key>WFWorkflowHasOutputFallback</key><false/>
  <key>WFWorkflowHasShortcutInputVariables</key><true/>
  <key>WFWorkflowIcon</key>
  <dict>
    <key>WFWorkflowIconGlyphNumber</key><integer>61699</integer>
    <key>WFWorkflowIconStartColor</key><integer>946986751</integer>
  </dict>
  <key>WFWorkflowImportQuestions</key><array/>
  <key>WFWorkflowInputContentItemClasses</key>
  <array><string>WFStringContentItem</string></array>
  <key>WFWorkflowMinimumClientVersion</key><integer>900</integer>
  <key>WFWorkflowMinimumClientVersionString</key><string>900</string>
  <key>WFWorkflowOutputContentItemClasses</key>
  <array><string>WFStringContentItem</string></array>
  <key>WFWorkflowTypes</key><array/>
</dict>
</plist>
```

To build and install it:

```sh
# 1. Save the plist above. THE EXTENSION MATTERS — .plist is rejected.
#    (measured: same bytes as .plist → exit 1; as .shortcut → exit 0)
$EDITOR ~/Desktop/CapturarNaInbox.shortcut

# 2. Sanity-check it parses at all.
plutil -lint ~/Desktop/CapturarNaInbox.shortcut

# 3. Sign it. Local, ~80 ms, no network:
shortcuts sign -i  ~/Desktop/CapturarNaInbox.shortcut \
                -o ~/Desktop/CapturarNaInbox.signed.shortcut
#    Or, if it should be shareable — ~3.4 s, appears to need internet:
#    shortcuts sign -m anyone -i … -o …

# 4. Install. This is the step Evie cannot do.
open ~/Desktop/CapturarNaInbox.signed.shortcut
#    → Shortcuts.app opens a preview sheet → click "Adicionar Atalho".
#    Shortcuts will also ask, on first run, to allow running shell scripts
#    and to allow access to the vault folder. Both are one-time and yours.

# 5. Then, and only then, the thing that is still unmeasured:
printf 'a reunião da IC mudou pra quinta' > /tmp/in.txt
shortcuts run "Capturar na Inbox" -i /tmp/in.txt -o /tmp/out.txt \
          --output-type public.plain-text
cat /tmp/out.txt
tail -1 ~/Library/Mobile\ Documents/iCloud~md~obsidian/Documents/Obsidian\ Vault/EU/Inbox.md
```

If step 5 works, `run_shortcut` in the agent loop is a two-hour job and the whole
recommendation is proved. If it does not, the *Automações* pane is still worth
building — it just lists and runs, and Evie never authors anything.

## What this pass measured, and what it still did not

Measured today: the action inventory (two independent sources), the App Intents
inventory per app, the on-disk `.wflow` format from six of Apple's own files, the
extension sensitivity of `shortcuts sign`, the complete absence of semantic
validation in `sign`, the two signing modes and their timings, that no CLI path
installs a shortcut, that `shortcuts run` does not accept file paths, that a
failed run does not create the output file, and the structural complexity of both
authoring formats.

Still not measured, unchanged from the first pass and now more sharply: the
input → output round trip; the prompts raised when Evie.app rather than Terminal
is the responsible process; concurrency; behaviour under Focus or on battery.
Added to that list: whether `-m anyone` truly requires the network, and whether
the `ExtensionInput` attachment above is the correct serialisation.

Nothing was installed. The library is the same eight shortcuts it was this
morning.

---

## Appendix — what survives from the Node-RED design

The engine changes; most of the thinking does not. Recorded here so it is not
lost.

**Workflows worth having first**, unchanged and all expressible as a shortcut plus
a trigger:

1. **Morning briefing** — `StartCalendarInterval` → read-only calendar/mail →
   summarise → card, optionally spoken.
2. **Meeting preparation** — schedule → retrieve related messages and documents →
   sourced brief.
3. **Voice capture** — hotkey or voice → classify as note/task/event → propose a
   destination → confirm.
4. **Downloads staging** — `WatchPaths` on Downloads → classify → propose names and
   folders → show a move manifest → confirm into approved roots.
5. **Weekly review** — schedule → summarise completed tasks, unread priorities,
   calendar, pinned artifacts.

Chosen because they are frequent, measurable, and can start read-only or
proposal-only.

**Rules that still apply.** Fail closed when a credential or approval is missing.
Rate-limit anything triggered by messages. Provide a one-click disable per
automation — here, the toggle in the pane. Never let the model reach an automation
the user has not enabled.

**Rules that do not survive**, and should not be pretended to. Idempotency keys,
persisted run state across external side effects, timeout reconciliation, and loop
detection between systems all assume a runtime that holds state between steps.
`shortcuts run` is one process that either exits or does not. If these turn out to
be needed, that is evidence the constraint is wrong, not that the design is.

**Location triggers** are unchanged in principle and unavailable in practice: they
need something listening. An iPhone Shortcut can push to a Mac, but only if
something on the Mac is awake to receive it. Deferred.

**AI-generated workflows** remain possible in the strong sense — `shortcuts sign`
works headlessly, so Evie can produce a real signed workflow file from a
description. The approval gate the old design specified as policy ("create/import
disabled → preview → user approval → activate") is here enforced by macOS itself:
the file does nothing until a human opens it and clicks *Adicionar*. That is a
better version of the same rule, because it cannot be bypassed by a bug in Evie.
