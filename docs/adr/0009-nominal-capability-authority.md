# ADR 0009: nominal read/propose/commit with process-local authority

Status: Accepted for the policy-broker foundation

Date: 2026-08-04

## Context

Evie will eventually read personal data and propose or execute filesystem/account
changes while processing untrusted model, web, email, document, and tool content.
A prompt instruction to “ask first” cannot prevent forged tool JSON, stale plans,
confused-deputy calls, or an integration accidentally treating a proposal as
approval.

The future UI, Hermes plane, and supervisor cross process boundaries. Serializable
data is therefore attacker-controlled unless the trusted broker independently
validates it. In particular, a field named `approved: true` must never become
authority merely because it decoded successfully.

## Decision

Encode each stage as a distinct nominal type:

- a serializable read request accepts only a read operation;
- a serializable proposal has no side effect and binds request/plan IDs,
  capability, target identity, material arguments, revision, provenance, creation,
  and expiry;
- a commit contains a process-local opaque authority value with no public
  initializer and no `Codable`/`Decodable` conformance.

Only an internal trusted-broker factory may create commit authority. It validates
the proposal lifetime, approved revision, immutable binding, and approval evidence.
Immediately before execution it revalidates current revision, full plan equality,
expiry, and authority binding. Delete is intrinsically destructive and always
requires explicit-user evidence; a standing policy cannot authorize it.

Material values, canonical target identity, provenance references, revisions, and
authority are redacted from default descriptions and errors. Trust labels carried
by serialized data are context, not proof; the broker derives its own trust and
approval evidence.

The serialized contract also has hard ceilings for identifier/text bytes,
top-level and nested collection counts, recursive depth, total argument nodes and
payload bytes, finite numeric values, decoder nesting, and a 15-minute maximum
proposal lifetime. Construction and decoding fail with a redacted error when any
ceiling is exceeded. These are transport/resource limits, not permission grants.

No executor is part of this decision. The current direct UI/TurboFieldfare path
cannot mint or consume authority. When `evied` exists, the factory and commit
executor live inside its trusted process. The UI sends a typed approval event; it
does not receive or relay the opaque authority token.

## Alternatives considered

1. Rely on system prompts and model self-restraint. This is not enforceable against
   prompt injection, malformed output, or integration bugs.
2. Use one Codable tool request with a stage/approved Boolean. Untrusted JSON can
   forge the field and ordinary code can accidentally skip the stage check.
3. Serialize a signed approval token across every component. A cryptographic
   design may be required for remote/multi-host approval later, but it adds key,
   replay, rotation, and logging risks unnecessarily for one local trusted broker.
4. Give every connector its own approval rules. This duplicates security-critical
   logic and makes cross-tool behavior inconsistent.

## Consequences

- Swift type separation prevents ordinary read/proposal values from being cast or
  conveniently converted into a commit.
- Model/tool/persisted JSON cannot construct commit authority.
- Expired or revision-changed plans fail closed, and delete always returns to an
  explicit confirmation path.
- Oversized or deeply nested model/tool payloads fail before entering an approval
  or future execution path.
- The future supervisor must keep approval evidence and authority generation in
  one trusted process; an IPC schema carries proposals/events, not authority.
- Capability descriptors still require a trusted registry, scoped credentials,
  canonical path/account checks, idempotency, audit, and actual executors. These
  contracts do not make any current feature agentic on their own.
