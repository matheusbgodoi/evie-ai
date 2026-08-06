# Automations

Status: recommendation, for a decision. Supersedes the Node-RED design previously
recorded under this name; that design is kept as an appendix because most of it
survives the change of engine.

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
