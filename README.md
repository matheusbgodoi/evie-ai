# Evie

A personal assistant that lives on your Mac and never leaves it. Pronounced
**"ívi"**. No account, no subscription, no network — the model, your voice, your
notes, and your conversations all stay on the machine.

She is a shortcut away rather than a window you keep open: press `⌥Space`, ask,
and she goes back to being invisible.

---

## Install

Four commands, once. Everything lands outside this checkout, in
`~/Library/Application Support/Evie/`.

```bash
Scripts/evie-runtime setup     # fetch and build the model server, download the model
Scripts/evie-app identity      # a signing identity, so permissions survive rebuilds
Scripts/evie-app build
Scripts/evie-app install       # into ~/Applications
```

`identity` prints one manual step: open Keychain Access and mark the certificate
as trusted for code signing. It cannot be scripted, and without it every rebuild
asks for the microphone again.

Then, whenever you want her running:

```bash
Scripts/evie-runtime start     # the model. ~15 GB resident, so it is explicit
Scripts/evie-app run           # Evie herself
```

**Always launch with `Scripts/evie-app run` or from `~/Applications`, never the
binary directly.** Running the executable from a terminal makes macOS attribute
the microphone and folder permissions to the terminal instead of to Evie.

For a voice that does not sound synthetic, pick a trained voice in Settings ›
Vozes. Evie starts the engine herself the first time she is asked to speak with
one — about seven seconds, and roughly 2.4 GB resident while it is up. Nothing
loads at login, and a system voice never starts it.

To manage that process by hand, or to release its memory:

```bash
Scripts/evie-voice status
Scripts/evie-voice stop
```

Requirements: Apple Silicon, macOS 26 or newer, about 25 GB free, and Apple's
Command Line Tools. Full Xcode is not required.

---

## Using her

| Shortcut | What it does |
|---|---|
| `⌥Space` | show or hide Evie |
| `⌥⇧Space` | open the text field |
| `⌥V` | hold to speak |
| `⌥⇧C` | enter or leave call mode |
| `⌥⇧N` | new conversation |
| `⌥⇧H` | history |
| `⌥⇧,` | settings |
| `⌥⇧Esc` | stop everything now |

All of them are reassignable in Settings › Atalhos, and every one also appears in
the menu-bar menu, so a shortcut the system refuses can never make something
unreachable.

**Typing.** `⌥Space`, type, `Return`. She answers in writing.

**Talking.** Click her mark, or hold `⌥V`. Stop talking and she notices — there is
nothing to press to say you have finished. She answers out loud, because you asked
out loud.

**Call mode.** `⌥⇧C`, then click the mark: the window becomes voice only. She
speaks, the microphone reopens by itself, and it keeps going until you click again.

**Reading your files.** Settings › Pastas. Authorise a folder and she can list it,
search it by name, search inside the text, and read what is in it. Nothing else —
there is no tool in her vocabulary that writes, moves, or deletes, which is why a
document telling her to delete your backups cannot work.

**Your notes.** If you use Obsidian, Settings › Pastas offers your vault directly.
She reads it to answer — what you wrote about a project, a company, a decision —
and never writes to it.

**What she remembers.** When she thinks she has learned something durable about
you, she asks — a card with two buttons. Nothing is stored until you press one.
Settings › Memória shows everything she keeps, one line each, deletable.

**Her voice.** Settings › Vozes. Remove the system voices you dislike, or train
your own: pick a clean ten-to-thirty-second recording, name it, and it becomes one
of her voices. Writing out what the recording says is optional and saves about
twenty-three seconds the first time she uses it.

---

## What works

- Conversation with a local model, streamed, with history kept on this Mac
- Speech in Portuguese, with automatic end-of-turn detection
- Speaking out loud, with system voices or voices you trained
- Call mode
- Reading images and PDFs, including scanned ones
- Seeing what a photo, chart or screenshot shows, not only the text in it
- Reading, searching, and searching inside folders you authorise
- Memory of what you told her, when you confirm it
- Skills you write, loaded only when they match what you asked
- Web search, if you switch it on — off by default
- A movable, resizable overlay, and configurable everything

## What does not, yet

- Email, calendar, Drive, WhatsApp
- Automations and scheduled work

She is told exactly which of these are wired up and will say so rather than
pretend. `evie-shell --print-persona` prints what she has been told about herself.

---

## Diagnostics

None of these open a window or ask for permission.

```bash
evie-shell --print-persona                 # exactly what Evie is told about herself
evie-shell --audio-check                   # bundle identity and microphone status
evie-shell --speech-check                  # whether this Mac can transcribe Portuguese
evie-shell --voice-check                   # opens the microphone briefly, writes a report
evie-shell --speak-check                   # says one sentence through the whole path
evie-shell --read <file>                   # what Evie would read from an image or PDF
evie-shell --tools-check                   # a real agentic turn over a throwaway folder
evie-shell --ask-folder <folder> "<question>"   # ask a real question of a real folder
evie-shell --voices-check <audio.wav>      # train a throwaway voice, speak with it, delete it
evie-shell --web-check "<query>"           # search, read a page, and show what is refused
evie-shell --ask-web "<question>"          # a real turn with the web switched on
evie-shell --see <image>                   # what she sees in a picture, and reads in it
evie-shell --skill-check "<question>"      # which skills a question loads, and the answer
evie-shell --change-check                  # the whole propose-approve-perform path
```

Server lifecycle:

```bash
Scripts/evie-runtime status|start|stop|doctor|smoke
Scripts/evie-voice   status|start|stop|voices|warm
Scripts/test                                # the Swift test suite
```

---

## Where things live

| What | Where |
|---|---|
| Model server, weights | `~/Library/Application Support/Evie/Runtimes/` |
| Settings | `~/Library/Application Support/Evie/preferences.json` |
| Model configuration | `~/Library/Application Support/Evie/config.json` |
| Authorised folders | `~/Library/Application Support/Evie/roots.json` |
| What she remembers | `~/Library/Application Support/Evie/memory.json` |
| Skills you wrote | `~/Library/Application Support/Evie/Skills/` |
| Conversations | `~/Library/Application Support/Evie/Conversations/` |
| Logs | `~/Library/Logs/Evie/` |

All of it is `0700`/`0600` and none of it is in this repository. Configuration is
built-in defaults, then that JSON file, then environment overrides; invalid
settings are shown in the overlay rather than silently accepted.

---

## Design commitments

These are not aspirations; they are enforced in the code and covered by tests.

**Nothing leaves the Mac.** The inference client refuses a non-loopback endpoint.

**She cannot claim a capability she does not have.** The system prompt is generated
from a snapshot of what is actually wired up, so a preference that is switched on
but unimplemented does not become a promise.

**The model never sees a filesystem path.** Authorised folders are opaque
identifiers; every lookup is relative to one. A path she was not given is a path
she cannot name or repeat.

**Authorising a folder is not authorising its credentials.** `.ssh`, `.env`,
keychains, private keys, browser cookies, and `~/Library` stay unreadable inside
an authorised folder, and listings say how many entries were withheld.

**Untrusted text is fenced, never obeyed.** File contents, tool results, and
document text arrive wrapped in a marker that says they are data. Verified: a PDF
instructing her to ignore her instructions was reported as an attack.

**Nothing destructive exists.** Not gated behind a confirmation — absent from the
vocabulary. When writing arrives it will be a proposal you approve, and deletion
will mean the Trash.

---

## Documentation

Start with [Project status](docs/PROJECT_STATUS.md) for what is true today and
[the work log](docs/WORKLOG.md) for how it got there. Design documents:
[architecture](docs/ARCHITECTURE.md) ·
[reaching the Mac](docs/FILESYSTEM.md) ·
[voice](docs/VOICE.md) ·
[security](docs/SECURITY.md) ·
[interface](docs/UI_UX.md) ·
[models](docs/MODEL_STRATEGY.md) ·
[RAG](docs/RAG.md) ·
[web search](docs/WEB_SEARCH.md) ·
[automations](docs/AUTOMATIONS.md) ·
[roadmap](docs/ROADMAP.md) ·
[decisions](docs/adr/README.md).

Working on this repository: read [AGENTS.md](AGENTS.md) first.

Nothing private belongs in Git — tokens, sessions, voice recordings, documents,
transcripts, indexes, and weights all live outside it. See
[.gitignore](.gitignore) and [Security](docs/SECURITY.md) before adding an
integration.
