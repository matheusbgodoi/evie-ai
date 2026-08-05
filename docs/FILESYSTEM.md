# Reaching the Mac

Status: designed and researched, not implemented. Evie currently answers "essa
parte ainda não está ligada" when asked to open a folder, and that is accurate.

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

## Reading, contained by the kernel

Path string checks lose to symlinks, `..`, and races. The containment is a file
descriptor for the root plus `openat` with:

- `O_RESOLVE_BENEATH` — the kernel refuses any resolution that escapes the root;
- `O_NOFOLLOW_ANY` — no symlink anywhere in the path is followed;
- `O_CLOEXEC`, `O_NONBLOCK`.

Then `fstat` on the descriptor, never `stat` on the path, so what was checked is
what was opened.

Inside an allowed root there is still a denylist: `.ssh`, `.gnupg`, keychains,
`.env` and its variants, private keys, browser profiles. A root the user granted
is not a licence to read their credentials.

Also bounded: bytes read per file, results per page (128 entries), and binary
detection so a listing does not return megabytes of unreadable bytes as text.

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

The inference client does not send or execute tools today. Making it do so needs
tool definitions in the request, tool calls decoded from the response, and a tool
result role. Two cautions recorded during research: this model family has been
observed leaking native tool tokens into ordinary content in other stacks, so a
sentinel must fail closed rather than parse free text; and the streaming shape of
tool calls is undocumented for this server, so the first implementation should use
non-streaming turns when tools are present.

## Order of work

1. `SEC-002` — the root registry: pick, store, list, revoke.
2. `INT-008` — the contained reader with the denylist and the limits.
3. `AGT-003` — the five read-only tools and a minimal executor.
4. `UI-011` / `POL-002` — the approval card, with expiry and single use.
5. `WRT-003` — move and trash as proposals only.

Reading is genuinely useful on its own. Steps one to three are worth shipping
before any write capability exists, and that is the recommended split.
