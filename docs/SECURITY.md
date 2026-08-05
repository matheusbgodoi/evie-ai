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

### VS-001 boundary

The first native executable has no account, filesystem, Accessibility, microphone,
automation, or tool capability. Its direct TurboFieldfare adapter rejects
non-loopback hosts, sends no credential, logs no prompt/result body, and retains
conversation text only in process memory. The system prompt accurately describes
those limitations, but remains presentation guidance rather than a security
boundary.

The loopback server itself has no authentication or TLS and must never be exposed
through a proxy, tunnel, wildcard bind, or remote interface. Future tools cannot be
added to the direct UI adapter; they require the supervisor/policy boundary and
separate read/propose/commit capabilities.

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

The current TurboFieldfare development log is local operational output and is not
committed. Evie's smoke prompts are fixed synthetic strings. Verification and
handoff output must record only status/metrics—not model assets, personal prompt
bodies, or the full local configuration. Rotation and purge remain `OPS-003`; the
development controller does not claim production log management.

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
