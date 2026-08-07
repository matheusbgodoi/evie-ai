# Security and privacy model

Status: mandatory architecture boundary.

## Threat model

Evie processes high-risk untrusted content:

- email and message bodies;
- web pages and search results;
- retrieved personal documents;
- filenames and document metadata;
- calendar descriptions and invitations;
- model and tool output;
- workflow payloads and webhooks.

Attackers may embed instructions that try to change Evie's goals, invoke tools,
exfiltrate data, weaken permissions, or send messages. Model alignment and a system
prompt are not a security boundary.

## Capability levels

### Read

May inspect explicitly scoped data and return it to the local user. Read operations
still require least-privilege accounts, collection scopes, rate limits, and logs.

### Propose

May create a local draft, manifest, disabled workflow, calendar proposal, file plan,
or outbound-message preview. Proposals have no external effect.

### Commit

May cause an external or filesystem state change only through a typed broker that
checks exact target, revision, scope, approval, idempotency, and audit metadata.

Separate tools and credentials should enforce these levels. A prompt saying "ask
before sending" is insufficient.

`CORE-005` now encodes these levels as nominal Swift types. Serializable read and
proposal values may carry untrusted model/tool data, but commit authority has no
public initializer or serialization conformance and is emitted only by an internal
factory after lifetime, revision, binding, and approval-evidence checks. Delete is
always classified destructive and rejects standing-policy evidence. This is a
tested contract only: serialized metadata also has hard byte/count/depth/node and
15-minute lifetime ceilings. No executor, filesystem access, integration, or
approval UI is enabled yet, and the future broker must independently derive
trust/evidence.

## Default confirmation policy

Always confirm initially:

- sending/replying to email or messages;
- creating, editing, or deleting calendar events;
- moving files outside a dedicated staging area;
- activating or materially changing a workflow;
- sharing/uploading content;
- terminal commands with meaningful host state effects;
- account, permission, or credential changes.

Always deny by default:

- permanent deletion without a recoverable staging/trash path;
- financial transactions and purchases;
- credential disclosure;
- disabling security controls;
- autonomous outbound bulk messaging;
- cron execution of dangerous terminal commands;
- instructions from retrieved content to expand permissions.

Policies may become narrower and more convenient only after a specific workflow is
tested, documented, reversible, and explicitly approved.

## macOS process boundary

The UI should own microphone permission and visual feedback. The supervisor runs as
a standard user, never root. Heavy workers do not need Accessibility or broad file
access merely because the UI can display their output.

A single App-Sandboxed executable is unlikely to cover the full assistant because
arbitrary Apple Events and accessibility automation are intentionally constrained.
Use separately permissioned brokers for any future UI automation. Normal API-based
tools must not inherit Accessibility.

Avoid Full Disk Access. Use user-selected roots/bookmarks or an explicit local
allowlist. Consider a separate macOS user for high-risk autonomous experiments.

### The current boundary

The sentence that used to sit here — that the native executable has no account,
filesystem, Accessibility, microphone, automation, web-search, RAG, or tool
capability — is now false in most of its parts, and leaving it would be worse than
having written nothing. What is true today:

- **Microphone**: granted and used, including continuously while the wake phrase
  is armed. macOS shows the orange dot throughout and it cannot be suppressed.
- **Filesystem**: read inside folders the user authorised, contained by the kernel
  rather than by path-string checks. Writing exists and proposes: the tool the
  model calls performs nothing, and a person presses the button. Deleting means
  the Trash.
- **Web**: off by default, and the one switch in the application that changes what
  leaves the Mac. Addresses that are not the public web — loopback, private
  ranges, `.local`, the cloud metadata endpoint — are refused before any request
  is made.
- **Retrieval**: over authorised folders only, into a cache under Application
  Support. Retrieved text is fenced as data.
- **Apple Events**: Mail and Calendar are read through `osascript`, off by
  default. Three read-only tools and nothing that writes. See below.
- **Accessibility**: still none. No shortcut is run, authored, or installed;
  nothing in `docs/AUTOMATIONS.md` has been implemented.
- **Scheduled runs**: user LaunchAgents can wake the application to ask a
  question she was given in advance. Nothing of Evie's runs between firings. See
  below.
- **Arithmetic**: `calculate` evaluates a fixed grammar in process. It has no
  I/O, no preference, and is declared on every turn.
- **Accounts and credentials**: still none. Mail and Calendar are read through
  the accounts the Apple apps already hold, so there is no OAuth application, no
  token on disk, and nothing to revoke inside Evie.

The invariant that has not moved: no tool the model can call changes anything.

Its direct TurboFieldfare adapter
rejects non-loopback hosts, sends no credential, and logs no prompt/result body.
Visible conversation history persists under Application Support using
an actor-isolated, schema-versioned, per-record store. The directory is mode
`0700`, records are `0600`, writes replace atomically, and hidden system/developer
messages never enter the record. The system prompt accurately describes these
limitations, but remains presentation guidance rather than a security boundary.

History deletion requires a deliberate window and confirmation. This is separate
from future filesystem tools: user-file deletion must always use an approved,
recoverable Trash operation and must never expose a model-callable permanent
delete primitive.

The loopback server itself has no authentication or TLS and must never be exposed
through a proxy, tunnel, wildcard bind, or remote interface. Future tools cannot be
added to the direct UI adapter; they require the supervisor/policy boundary and
separate read/propose/commit capabilities.

### Reading Mail and Calendar

Three read-only tools — `read_mail`, `search_mail`, `read_calendar` — against the
two Apple applications, which already hold the user's Gmail and iCloud accounts.
No OAuth application, no token, no account to configure. Off by default behind
`mail_and_calendar_enabled`, in Settings › O que ela sabe › Mail e agenda.

The door is AppleScript, and AppleScript has `do shell script`, so the whole
design turns on one rule: **no script is ever built by interpolation.** The three
programs are string constants in the binary. Inputs arrive through `on run argv`,
passed by `osascript -e <script> -- <args>` as process arguments, which are never
parsed as code. A subject line, a sender, or a search term is inert data on the
way in as well as on the way out.

Two tests hold that boundary rather than a comment:

| Test | What it asserts |
|---|---|
| Source inspection | the script literals contain no `\(`, no `do shell script`, and none of the writing verbs |
| Break-out execution | `osascript` is handed three real break-out payloads; afterwards the file they try to create does not exist |

Measured for all three payloads: exit 0, empty stderr, no file
(`1932f5a`, `Tests/EvieCoreTests/EvieMailCalendarTests.swift`).

Read-only by construction, not by policy. No function that sends, deletes, marks
or creates was declared, so a message saying "apague os backups" is asking for
something that does not exist — the structural defence this document already
states for the filesystem: prompt injection cannot call a function that was never
declared. `refusedWritingNames` catches the model inventing `send_mail` anyway
and answers with a sentence, rather than with a "no such tool" error that reads
like a spelling problem and gets retried.

What comes out of the inbox is fenced exactly like a web page, and for a sharper
reason: anyone who knows the address can put text in there. Bounded, too — eight
messages by default and twenty at most, a 220-character snippet rather than a
body, forty events shown out of at most 120 collected, and a calendar window that
may not exceed a year (`Sources/EvieCore/EvieMailCalendar.swift`).

A denial from macOS Automation comes back as `errAEEventNotPermitted` (-1743),
which is a number nobody can act on; it is translated into the application and
the pane that grants it, Ajustes do Sistema › Privacidade e Segurança ›
Automação. `NSAppleEventsUsageDescription` is in the generated `Info.plist`, in
Portuguese, saying plainly what she reads. Neither application is launched by
Evie: closed means "abra o Mail", not a window appearing by surprise.

The Automation consent prompt itself was not observed. The terminal used for
verification already held the grant, and every attempt to provoke a refusal was
authorised too; the -1743 path is covered by unit tests against the Portuguese
and English wording rather than by having been seen (`1932f5a`).

### Scheduled runs

A schedule is a prompt and a trigger, and each one becomes a user LaunchAgent in
`~/Library/LaunchAgents` that runs this bundle with `--run-schedule <id>` and
nothing else. Between one firing and the next there is no timer, no daemon, and
no process of Evie's at all.

**The prompt is deliberately not in the plist.** `~/Library/LaunchAgents` is
readable by anything running as this user, and a prompt may say "resume meus
e-mails não lidos". What travels on the command line is only which schedule to
run; the text lives in `schedules.json` beside the rest of Evie's state, mode
`0600` in a `0700` directory (`Sources/EvieCore/EvieScheduleAgent.swift`,
`Sources/EvieShell/EvieScheduleStore.swift`).

The identifier reaches a filename and a `launchctl` argument, so it is validated
before anything is written — eight lowercase hex characters, the same shape
`EvieFileRoot` uses. A hand-edited `../../something` in the store would otherwise
write a plist wherever it liked (`Sources/EvieCore/EvieSchedule.swift`).

A scheduled question is the same question a typed one is: the same
`EvieAgentLoop`, the same persona, memories, granted folders and web setting. It
gains no authority by being asked at eight in the morning, and it loses none.

Two schedules that overlap do not queue. The model is a single worker, and a
summary of the morning delivered after the morning has started is worth less than
the next run of the same schedule, so the second run takes an exclusive
non-blocking `flock`, finds it held, writes `PULEI` to its log and exits
(`Sources/EvieShell/EvieScheduleLock.swift`).

Notifications are a fallback rather than a preference.
`UNUserNotificationCenter` needs no entitlement, but on this Mac it refuses a
locally-signed bundle outright: `requestAuthorization` throws `UNErrorDomain 1`,
"Notifications are not allowed for this application", both ad-hoc and signed with
this project's own certificate, and `add()` then reports success while showing
nothing. `NSUserNotification` is not an alternative; it has been undeliverable
for years. So the framework is tried first, `osascript` posts the banner when it
is refused, and the whole answer reaches the conversation history either way —
history first, deliberately, so a refused notification never loses the answer
(`c8ef4f3`, `Sources/EvieShell/EvieScheduleNotifier.swift`).

### Development runtime boundary

`Scripts/evie-runtime` is an explicit local test controller, not an authorization
or security broker. It:

- pins the expected TurboFieldfare source revision and refuses an unexpected or
  locally modified runtime checkout;
- binds/checks only `127.0.0.1:8080` and refuses to start when the port or another
  known model-owning process conflicts;
- validates a recorded PID and command/model path before sending `SIGTERM`, and
  never escalates automatically to a force kill;
- creates runtime state under `~/Library/Application Support/Evie/` and its server
  log under `~/Library/Logs/Evie/` with a user-only umask;
- does not create a LaunchAgent, login item, credential, remote listener, or
  automatic restart policy.

The local JSON config contains only model endpoint/generation settings. Its
versioned tracked example is intentionally non-secret, while the real file remains
outside Git and is created with user-only permissions. Supported environment
overrides are also non-secret; future credentials must not be added to this loader
or passed through the model process environment.

## Secrets

Preferred order:

1. macOS Keychain for credentials supported by the Evie broker;
2. upstream protected local stores when the integration owns its credential flow;
3. permission-restricted ignored files only when necessary.

Never place secrets in tracked config, workflow JSON, logs, shell history, prompts,
RAG indexes, screenshots, crash reports, or model-visible diagnostics.

Particularly sensitive state:

- WhatsApp Baileys session credentials grant account access;
- Google OAuth refresh tokens grant scoped Workspace access;
- Node-RED credential state may unlock multiple connectors;
- voice references are biometric-like personal data;
- indexed personal content can reveal more than its source file names suggest.

## Prompt-injection boundary

Every tool/result envelope identifies content provenance and trust. Untrusted text
cannot:

- modify system/personality/policy prompts;
- define a new tool or target;
- supply approval;
- select a secret;
- expand a filesystem/account scope;
- activate a workflow;
- cause a commit action without the broker's independent checks.

Security evaluation includes adversarial email, web, document, calendar, image OCR,
and WhatsApp cases.

## Logging

Audit logs record action type, integration, target identifier, policy decision,
approval identity/time, result, duration, and error class. They avoid full message
bodies, document excerpts, raw prompts, credentials, and unnecessary phone/email
addresses.

User-facing history and low-level diagnostic logs have separate retention and
redaction policies.

Conversation JSON is user-facing private state, not a diagnostic log. No worklog,
crash report, test fixture, RAG index, or audit event may copy its message bodies.
The future supervisor must become its single writer before more than one process
can access it.

The current TurboFieldfare development log is local operational output and is not
committed. Evie's smoke prompts are fixed synthetic strings. Verification and
handoff output must record only status/metrics—not model assets, personal prompt
bodies, or the full local configuration. Rotation and purge remain `OPS-003`; the
development controller does not claim production log management.

The source-only OmniVoice adapter passes offline-resolution flags only to supported
libraries; it does not sandbox a configured executable from the network. Treat that
executable as trusted local code and do not activate TTS until its identity/version
and model manifest are pinned, outputs are supervised, and orphan cleanup exists.

## Updating the application

Evie can replace herself with a build from a GitHub release. That is a path from
the internet to executable code on this Mac, so it is the most security-relevant
thing in the application, and it is built to fail closed.

**Three separate presses.** Look, download, install. Nothing happens in the
background and nothing is installed silently.

**A download is installed only when its code signature matches the running copy.**
The verification is two checks, because neither is enough alone, and which catches
what was measured against tampered copies of this very bundle:

| Check | Catches |
|---|---|
| The signature seal | an edited `Info.plist`, a flipped byte, an added resource |
| The leaf certificate | an attacker who re-signs the bundle with their own key |

The seal alone would be defeated by re-signing. The certificate alone would not
notice a modified bundle that was never re-signed. Together they mean that an
attacker who takes over the GitHub account still cannot produce a bundle Evie will
install, because they cannot produce one signed with a key that never left this
Mac.

**It fails closed in both directions.** An ad-hoc running copy has no certificate
to compare against, so it refuses every update rather than accepting any. That is
the correct behaviour and it is also a real consequence: until
`Scripts/evie-app identity` has been run on a machine, that copy cannot update
itself at all.

`Scripts/evie-app identity` had never once worked. It passed `openssl`'s `-legacy`
flag, which the LibreSSL macOS ships does not have, and sent both `openssl`
invocations to `/dev/null` — so the p12 was never written, the import failed
against a missing file in silence, and Evie stayed ad-hoc signed while the script
reported nothing wrong. Errors are no longer discarded, the trust step is scripted
rather than a trip through Keychain Access, and the result is asserted rather than
assumed.

The identity is self-signed, so the build is not notarized and cannot be. That
constrains what a release can be; see `docs/PROJECT_STATUS.md`.

## Update and dependency policy

- Pin model/runtime/plugin revisions used in validated builds.
- Run the Evie evaluation suite before upgrades.
- Review new Node-RED nodes and Hermes plugins as code with user privileges.
- Preserve a rollback path for Hermes, TurboFieldfare, model assets, workflow
  revisions, and the native app.
- Unofficial WhatsApp protocol changes are expected; failure disables that channel
  rather than weakening validation.

## Incident response

Document one-step procedures to:

- mute microphone/wake word;
- stop Evie and all workers;
- disable all workflows;
- revoke Google OAuth;
- unlink the WhatsApp device;
- rotate compromised secrets;
- inspect redacted audit history;
- rebuild RAG indexes;
- restore the last known-good configuration.
