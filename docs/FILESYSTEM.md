# Reaching the Mac

Status: **reading works end to end.** A folder is granted in Settings > Pastas,
Evie is offered five read-only tools, and she chains them to answer. Verified
against the running model on 5 August 2026 — see "What was measured" below.
Nothing writes, moves, or deletes; that remains unbuilt by design.

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

Five flat functions, all read-only:

`list_folder`, `read_file`, `search_files`, `file_info`, `list_roots`.

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

**The inference server degrades badly with uptime, and this is the single largest
risk to the feature being usable.** The same four questions against a server that
had been up ten hours took 102 s, 123 s, 318 s and 235 s. A trivial `"oi"` with
eight completion tokens took **1657 seconds** — 27 minutes. Per-request cost had
grown from about 6 s to nearly 60 s and no longer varied with prompt size
(148 prompt tokens cost the same as 1322), and prefix caching had stopped hitting
entirely — `cached=0` on every request, against `cached=1077` after a restart.
The process held 1.6 GB resident and used 115% CPU, barely more than one core of
an M5. Restarting restored 5.8 s immediately. This is a defect in
TurboFieldfareServer, not in the loop, and it needs its own investigation; until
then, `Scripts/evie-runtime stop && start` is the workaround, and a slow Evie is
the symptom to watch for.

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
