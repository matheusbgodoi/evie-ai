# Reaching the Mac

Status: **reading works end to end.** A folder is granted in Settings > Pastas,
Evie is offered seven read-only tools, and she chains them to answer. Verified
against the running model on 5 August 2026 — see "What was measured" below.

Updated 2026-10-16 (branch `v2-files`): moving, renaming and the Trash exist as
proposals behind their own switch; new documents (`propose_document`), opening
and revealing files, `analyze_folder`, document text in `read_file`, and the
well-known folders as one-click suggestions are described in the sections at the
end, and ADR 0019 records the policy. The "Order of work" list below is the
August plan and is kept as written.

This is the design for `SEC-002`, `INT-008`, `WRT-003`, and `POL-001`–`POL-003`.
It exists because the user asked for something specific: Evie should be able to
read Downloads and other folders. The gap between "should be able to" and "is
allowed to, safely, and can prove it" is what the rest of this document is.

## The prerequisites that are already met

Two of them landed with `PKG-001`.

**A bundle identity.** TCC identifies an application by its code signature. A bare
executable has none, so a grant cannot be attached to it.

**Launching through Launch Services.** Measured: running the executable inside the
bundle from a terminal makes TCC attribute the request to the terminal, and the
Downloads grant lands on `com.apple.Terminal` — which over-authorises everything
else that ever runs there. `Scripts/evie-app run` uses `open` for this reason.

One prerequisite is **not** met: the signature is still ad-hoc. Ad-hoc code has no
stable designated requirement, so macOS cannot prove that build N+1 is the same
program as build N, and the grant evaporates on every rebuild.
`Scripts/evie-app identity` creates a self-signed certificate that fixes this; the
Keychain trust step is manual and printed by the script.

## What macOS protects, and what it does not

Consent is required for Desktop, Documents, Downloads, iCloud Drive, removable
volumes, and network volumes. It is *not* required for the rest of the home
directory, which is a larger surface than most people assume.

**Full Disk Access is not the answer** and should not be requested. It is far
broader than anything Evie needs, cannot be granted programmatically, and turns a
scoped assistant into a system-wide one.

The decisive asymmetry: **TCC gates reading and listing. It does not gate writing
or moving.** Once a path is reachable, moving a file is ordinary POSIX with no
prompt and no audit. The operating system will not catch a mistake in Evie's own
allowlist. Containment has to be Evie's own work, which is why the write path
below is more paranoid than the read path.

## Sandbox or not

Not sandboxed, for now.

The App Sandbox would give operating-system-enforced containment, which is
genuinely better. It also forecloses Apple Events, Accessibility, and arbitrary
paths — capabilities this project has explicitly planned for. The registry below
is designed so both modes can share it, and moving later is a build-flag change
rather than a rewrite.

## Granting a root

1. `NSOpenPanel` picks the folder. The user chooses; Evie never proposes a path.
2. A bookmark is stored, along with a grant identifier and an epoch.
3. Access is opened through the bookmark, and closed when finished.

**`com.apple.macl` is not the permission.** Choosing a file in an open panel
attaches an invisible extended attribute that grants access. It cannot be listed,
cannot be revoked from the interface, and its behaviour varies across sessions.
Treat the panel as user intent — a signal for the interface — and the recorded
bookmark as the durable permission, because that one can be shown in a list and
deleted.

The registry lives beside the existing local files with `0700`/`0600`
permissions, versioned and written atomically, exactly like the conversation
store and the preferences.

## Reading, contained by the kernel — implemented

`EvieScopedFileReader` in `EvieCore`. Seventeen tests cover it, and the ones that
matter are the escapes rather than the happy path.

Path string checks lose to symlinks, `..`, and races. The containment is a file
descriptor for the root plus `openat` with:

- `O_RESOLVE_BENEATH` — the kernel refuses any resolution that escapes the root;
- `O_NOFOLLOW_ANY` — no symlink anywhere in the path is followed;
- `O_CLOEXEC`, `O_NONBLOCK`.

Then `fstat` on the descriptor, never `stat` on the path, so what was checked is
what was opened.

The path is walked one component at a time, so a symlink in the *middle* is
refused rather than only at the end — the version of this bug people forget.
Verified on this Mac: a symlink to `/etc/hosts` fails with `ELOOP`, a symlinked
`etc` directory partway along fails the same way, and both `../../etc/hosts` and
`/etc/hosts` fail with `ENOTCAPABLE`.

Inside an allowed root there is still a denylist: `.ssh`, `.gnupg`, keychains,
`.env` and its variants, private keys, browser cookies. A root the user granted is
not a licence to read their credentials. It applies to every path component rather
than only the last, and denied entries are withheld from listings with a count, so
the interface can say something was hidden without naming it.

Also bounded and implemented: 512 KiB per read with truncation reported, 128
entries per listing page, and binary detection by NUL byte so a listing never
returns megabytes of noise as text.

Two specific traps. iCloud Drive placeholders are *dataless* — reading one starts
a download and can hang; check the downloading status and refuse or queue rather
than block. And filenames themselves are untrusted content: a file named
`ignore previous instructions.pdf` appears in listings.

## Writing and deleting

Never as a tool the model can call. Only as a proposal the user approves, through
the capability contracts that already exist in `EvieCapabilityContracts`.

- **Trash, never delete.** `FileManager.trashItem` is recoverable. Bulk "Put Back"
  is unreliable, so Evie keeps her own undo manifest.
- **A precondition on the exact file.** Volume, inode, size, modification time,
  and a hash prefix, recomputed at commit. If the file changed after the user
  approved, the approval no longer applies.
- **`renamex_np(RENAME_EXCL)`** so a move cannot silently overwrite.
- **Expiry, and single use.** Destructive approvals expire in ninety seconds and
  are consumed by a plan ledger. Without that ledger the existing authority
  factory could be called twice for one approval.
- **Cross-volume moves are a different capability.** `EXDEV` requires copy,
  verify, trash — never a silent fallback.
- **Approval shows the exact target and arguments**, and denial is the default.

## What the model is allowed to see

Seven flat functions in `EvieFileToolbox`, all read-only:

`list_roots`, `list_folder`, `read_file`, `search_files`, `search_content`,
`file_info`, `analyze_folder`.

Writing, opening and revealing are separate types with their own sections below
(`propose_change`, `propose_document`, `open_file`, `reveal_in_finder`); none of
them lives in the read-only toolbox, and `EvieFileToolboxTests` asserts that no
name in it contains a verb that changes anything.

Roots are referred to by opaque identifiers, never paths, so the model cannot
construct a location it was not given. **There is no commit tool in the schema.**
Moving and trashing are proposals raised by the application in response to what
the model suggested, and confirmed by a human. This is a structural guarantee
rather than a prompt instruction: prompt injection cannot call a function that
does not exist.

## What was measured

Measured 5 August 2026, MacBook Pro M5, 24 GB, macOS 27, `gemma-4-26b-a4b-it`
served by TurboFieldfare on `127.0.0.1:38433`. Reproduce with
`evie-shell --tools-check`, which builds a throwaway folder and asks four real
questions.

**The wire format is ordinary OpenAI.** `finish_reason: "tool_calls"`,
`content: null`, and `function.arguments` as a JSON *string*. The research
caution about non-streaming turns turned out to be unnecessary: streaming with
tools works, and the server delivers a complete, well-formed call inside a single
SSE delta. It is still reassembled by `index` — that the whole call arrives at
once is this server's implementation detail, not the protocol's. No native Gemma
tool tokens leaked into `content` in any observed turn.

**Declaring the tools is nearly free.** Five tools add 309 prompt tokens and no
measurable latency. A healthy server also caches the prefix — observed
`cached=1077` of a 1131-token prompt on a follow-up step, completing in 4.1 s —
which is exactly the shape an agent loop wants, since every step after the first
repeats the persona and the tool block verbatim.

**A turn costs seconds, not milliseconds**, against a freshly started server:

| Question | Tools chained | Wall clock |
| --- | --- | --- |
| Quais pastas eu te autorizei? | `list_roots` | 20 s |
| Que arquivos tem na pasta? | `list_roots` → `list_folder` | 21 s |
| Procura "contrato" e diz o valor | `list_roots` → `search_files` → `read_file` | 37 s |
| Qual a senha no `.env`? | `list_roots` → `list_folder` → `search_files` | 82 s |

All four answers were correct. The `.env` question is the interesting one: the
denylist withheld the file from the listing and from the search, and Evie
reported honestly that she could not find it rather than inventing a password.

**Retracted: an earlier version of this document claimed the inference server
degrades badly with uptime.** It does not, and the measurement behind the claim
was invalid. The 1657-second request that anchored it was wall-clock across a
MacBook lid closing: both `Date()` and the server's own timer count time spent in
standby, so the figure measured sleep, not inference. The other slow figures from
that round (102 s, 123 s, 318 s, 235 s) came from a background run that spanned
the same standby and are unreliable for the same reason.

Re-measured awake, after 1 h 39 min of server uptime: 6.6 s, 6.8 s, 6.9 s for
128 completion tokens — about 19 tokens per second, with no drift. There is no
known uptime defect. The lesson is narrower and worth keeping: **never time a
local model with wall clock across a background run**, because a lid closing is
indistinguishable from a slow server in the numbers.

An earlier round of measurements in this session was contaminated by leftover
probe processes queuing behind each other on the same single-worker server — the
same mistake the voice timings made. The server log's `queued` → `generating`
gap is how to tell.

## Order of work

1. ~~`INT-008` — the contained reader with the denylist and the limits.~~ **Done.**
2. ~~`SEC-002` — the root registry: pick, store, list, revoke.~~ **Done.**
   `EvieRootRegistry` in core, `EvieRootsViewModel` and Settings > Pastas in the
   shell. Grants come only from `NSOpenPanel`; overlapping grants are collapsed
   so revoking cannot leave a second door open.
3. ~~`AGT-003` — the five read-only tools and a minimal executor.~~ **Done.**
   `EvieFileToolbox` and `EvieAgentLoop`, bounded at four steps and four calls
   per step.
4. `UI-011` / `POL-002` — the approval card, with expiry and single use.
5. `WRT-003` — move and trash as proposals only.

Reading is genuinely useful on its own, and steps one to three now ship without
any write capability existing.

## What the model never sees

A path. Roots are handed over as opaque eight-character identifiers, and every
tool speaks in paths relative to one. A model that was never given a path cannot
construct one, cannot repeat one into an answer, and cannot leak the shape of the
disk. `EvieFileToolboxTests` asserts this directly against every tool's output.

Progress messages obey the same rule: the overlay says *Lendo plano.md…*, never
the folder it lives in and never the identifier.

## Suggested folders — implemented 2026-10-16

`EvieSuggestedRoot` names four well-known folders: **Mesa** (`~/Desktop`),
**Documentos** (`~/Documents`), **Downloads** (`~/Downloads`) and the
**Obsidian** vault at
`~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault`. The
list is fixed in code, so a suggestion is never a path a model produced.

- **Never granted silently.** A suggestion is a card, "Permitir que a Evie leia
  sua Mesa", with one button. The card appears when the person's own message
  mentions the folder (`EvieSuggestedRoot.mentioned(in:)`), when a tool names its
  alias before it is granted, from the first-run guide, or from Settings. It says
  that macOS asks once per folder — Desktop, Documents and Downloads are TCC
  folders — and the shell touches the folder right after the press so the
  system's question appears while the person is still looking.
- **Aliases as `root_id`.** `mesa`, `documentos`, `downloads` and `obsidian`
  work wherever a root identifier does once the folder is reachable: granted on
  its own, or inside a granted home folder. Inside a home folder the alias is a
  narrowed view (`location(in:home:)`) produced only when the canonical path,
  symlinks resolved, still lies inside the grant and the path between them holds
  no denied name. A home grant therefore never exposes the vault, which lives
  under `Library`.
- **Without a home, no alias.** `EvieFileToolbox.home` is `nil` by default; only
  the shell's own turn sets it. The schedule runner and the diagnostics see the
  identifiers they were given and nothing else.
- `list_roots` lists granted folders, the aliases that reach them, and the
  well-known folders not granted yet. An ungranted alias fails with a sentence
  that tells the model a card is on screen, and the loop reports it
  (`requestedSuggestion`) so the shell can draw the card.

This narrows "grants come only from `NSOpenPanel`": the open panel remains the
only way to grant an arbitrary folder, and the card adds a one-click way for
these four fixed ones. ADR 0019 records it.

## Analysing a folder — implemented 2026-10-16

`analyze_folder(root_id, path?, documents?)` answers "analisa a pasta Downloads"
and "o que tem na minha mesa?" in one call. `EvieFolderAnalyzer` walks the folder
through the same contained reader and returns, counted by code:

- files and folders, total size, and counts and sizes by kind (PDF, Word and
  formatted text, text and notes, spreadsheets, presentations, images, videos,
  audio, archives, installers and apps, other);
- the five newest and five oldest files, and up to twenty names;
- the opening (600 characters) of up to four documents, at most eight, newest
  first: PDF, DOCX, DOC, RTF, ODT, TXT, MD, CSV. PPTX is counted but not read —
  neither PDFKit nor `NSAttributedString` reads it, and a zip parser is not worth
  adding for an extract.

Bounded like the searches: three levels below the folder, 4,000 entries, one
listing page (128) per folder, and "os números são um mínimo" when a ceiling
stopped it. Hidden files are skipped; credentials are counted as withheld and
never named. App bundles and other packages count as one item and are never
walked into. The extracts are introduced as untrusted content.

## Reading documents in a folder — implemented 2026-10-16

`read_file` on a PDF, DOCX, DOC, RTF or ODT returns its text
(`EvieDocumentText`): PDFKit for a PDF's text layer, `NSAttributedString`'s
document readers for the rest, at most 60,000 characters and 60 PDF pages. The
bytes come from `EvieScopedFileReader.readData`, the same `openat` containment as
every other read, with a 16 MiB ceiling that refuses a larger file whole rather
than truncating it into a corrupt one. A scanned PDF has no text layer and is
reported as such; reading its pixels stays `EvieDocumentReader`'s job, on an
attached file.

## Writing a new document — implemented 2026-10-16

`propose_document(title, format, destination, subfolder?, content)` is the one
way Evie writes a document, and it writes nothing: `EvieDocumentTool` turns the
call into an `EvieDocumentProposal` and the shell draws a card with the file
name, the place ("Mesa › Faculdade") and a preview, and two buttons, **Salvar**
and **Salvar e abrir**. `destination` is `mesa`, `documentos`, `downloads` or a
root identifier, resolved again against the folders granted at the moment of the
press. `content` is Markdown.

- **Formats.** `.md` as written, `.txt` without the Markdown, `.rtf` and `.docx`
  through `NSAttributedString`'s own writers (`.officeOpenXML` for Word), and
  `.pdf` laid out on A4 with Core Text, with a real text layer
  (`EvieDocumentRenderer`). Arial 12, headings, lists, bold, italic, links.
  Verified 2026-10-16: the `.docx` is an Office Open XML zip whose every part
  parses as XML, `file` reports "Microsoft Word 2007+", and reading it back with
  `NSAttributedString` returns the text with the bold run still bold
  (`EvieDocumentCreatorTests`). Opening it in Word or Pages was not tried on
  this Mac.
- **Never an existing file.** `EvieDocumentCreator` opens the file with
  `O_CREAT | O_EXCL`, so the kernel refuses a taken name; it then tries
  "nome (2).ext", "nome (3).ext", up to 99. An existing symlink with the name
  counts as taken and is never followed.
- **Inside the folder.** Every directory is opened from a descriptor for the root
  with `O_RESOLVE_BENEATH | O_NOFOLLOW_ANY`; a missing subfolder shown on the
  card is created with `mkdirat`; `..`, absolute paths and denied names are
  refused before any syscall. A half-written file is the only thing ever
  removed.
- **Bounded.** 200,000 characters of content, 100 characters of name, and a card
  good for fifteen minutes — the ADR 0009 ceiling. A new file destroys nothing,
  so it gets longer than a move's two minutes.

## Opening and revealing — implemented 2026-10-16

`open_file(root_id, path)` opens a file in a granted folder with its default app
and `reveal_in_finder(root_id, path)` selects it in the Finder. They are the two
actions the model may take without a card, because neither changes a file
(ADR 0019). `EvieOpenTool` holds them to three limits:

- **Inside a granted folder.** The path goes through
  `EvieScopedFileReader.status` (`openat`, `O_RESOLVE_BENEATH`,
  `O_NOFOLLOW_ANY`, `fstat`) before anything is asked of the system.
- **Only documents.** `open_file` works from an allowlist, not a denylist: it
  opens a regular file whose extension is a known document (PDF, Word, text,
  spreadsheets, presentations, images, audio, video), or — for an extension not
  listed — whose `UTType` is a PDF, image, audio/video or plain text and none of
  executable, bundle, package, application, script, source code or web content.
  There is no open-ended `public.content` fallback: HTML, XHTML, SVG, XML and
  web archives conform to it and a browser would run their script, so web
  documents are reveal-only. Behind that a fixed list still refuses the launcher
  types by name (`.app`, `.command`, `.sh`, `.pkg`, `.dmg`, `.terminal`,
  `.workflow`, `.scpt`, `.jar`, `.saver`, `.xpc`, profiles, web shortcuts…).
  Folders, bundles and packages are never opened, only revealed. A file with an
  execute bit that is not a known document is refused; a PDF copied from a USB
  stick with every bit set still opens. Revealing runs nothing, so it is held
  only to the first limit.
- **On the record.** A status line while it happens ("Abrindo resumo.pdf…") and
  a line in the transcript after (`EvieAgentLoop.Outcome.fileActions`).

The loop holds only `EvieFileOpening`; `NSWorkspace` lives in the shell. Tests
use a recording opener and never open anything. One gap is accepted and
recorded: the check and the `NSWorkspace` call are two steps, so a component
swapped for a symlink between them is not caught. For an action that changes
nothing and refuses executables, that race is not worth a descriptor-passing
API Launch Services does not have.

## Routing a file request

`EvieFileIntent` recognises a question about the disk — a folder, a document,
a file name with an extension, Mesa, Documentos or Downloads, or a request to
save — and `EvieTurnPlan.route(asksAboutFiles:)` sends it to the tool-using
loop even when no folder is granted, so "o que tem na minha mesa?" reaches
`list_roots` and the card. A picture in the request still keeps the turn
tool-less. `EvieFileRoutingTests` holds the five requests the owner named.
