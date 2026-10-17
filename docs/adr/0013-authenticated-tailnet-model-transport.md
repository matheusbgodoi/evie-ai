# ADR 0013: authenticated tailnet model transport

Status: Accepted for Evie v2 (slice S1a implemented); superseded in part by
[ADR 0017](0017-per-launch-key-for-the-local-brain.md) (the Mac brain's
per-launch key is the one key sent over `http`, to 127.0.0.1 on its own port)

Date: 2026-10-16

Supersedes in part: [ADR 0006](0006-direct-turbo-vertical-slice.md) — the
loopback-only and no-credential clauses. The backend-neutral core it established
(`AgentClient`, Sendable event types, one adapter composed at the root) stands.

Amends in part: [ADR 0002](0002-primary-model-and-context.md) — the primary model
is chosen per profile, and `qwen-daily` on the owner's PC is the default. The
Gemma/TurboFieldfare measurements remain the record for the Mac-local path.

## Context

Evie's model ran on this Mac, on loopback, with no key: ADR 0006 made "rejects
non-loopback endpoints" and "carries no credential" part of the adapter's
contract. Evie v2 moves the default brain to the owner's RTX 3090, served by a
gateway at `https://models.example.invalid` on the owner's tailnet.

Measured 2026-10-16 from this Mac (M5, macOS 27.2), read-only requests: `GET
/health` answers 200 with no auth in 49 ms; `GET /v1/models` answers 401 without
a key and 200 with `Authorization: Bearer`; neither redirects; plain `http` to
the same name does not connect. Every turn therefore needs a key, over TLS, to
one host that is not loopback.

What a turn carries — the person's files, mail, screen and history — is the
reason the loopback rule existed, so replacing it has to keep what it protected:
nothing leaves the Mac except to a machine the owner named, and nothing that
could be read by someone else carries the key.

## Decision

`ModelTransportPolicy` decides, before any request, whether an endpoint may be
used:

- `http` and `https` only, and never a URL with a user or password in it;
- plain `http` only to loopback (`127.0.0.1`, `localhost`, `::1`);
- every other host needs `https` and an **exact** match in an allowlist whose
  default is `["models.example.invalid"]`; one wildcard form,
  `*.<tailnet>.ts.net`, admits a single label inside that one tailnet;
- a remote host needs a credential **bound to that same host**.

`OpenAICompatibleClient` (renamed from `TurboFieldfareClient`, with no typealias)
enforces it and adds:

- the bearer token is attached only over `https` and only when the credential's
  `boundHost` equals the request host — never over `http`, loopback included;
- a key that applies but cannot be read stops the turn before anything is sent;
- every HTTP redirect is refused (a task delegate answers
  `willPerformHTTPRedirection` with `nil`), so the header cannot follow one; the
  3xx becomes the response and is reported as an HTTP error;
- the class stays checked `Sendable`: only `let` properties, no `@unchecked`.

Configuration holds a `CredentialReference` (keychain service, account, bound
host), never a token. `KeychainCredentialProvider` reads generic passwords from
the **legacy login keychain** and caches hits in memory; the data-protection
keychain needs an application-identifier entitlement a self-signed build without
a team cannot have. `ModelClientFactory` is the only way to build a client
outside EvieCore (the initialiser is internal), so the app, the settings reload,
scheduled runs and every diagnostic share one policy and one keychain cache.

## Alternatives considered

1. **Keep loopback-only and tunnel the PC to a local port** (SSH or `tailscale
   serve` to `127.0.0.1`). The client stays unchanged, but the tunnel becomes an
   always-on process with its own lifecycle, and a loopback port is reachable by
   every local process — the very thing that makes sending a key there unsafe.
2. **Trust by network range or suffix**: any `*.ts.net` host, or 100.64.0.0/10.
   Funnel publishes strangers' machines under `ts.net`, and the CGNAT range is not
   the owner's alone, so either rule trusts people the owner never named.
   `EvieWebClient.validate` is not reused for the same reason in reverse: it
   refuses 100.64/10 to keep web fetches off private space.
3. **Store the key in the configuration file.** Simple, but the file is written
   by Settings, read by diagnostics and easy to paste into a report; a key there
   is a key in every copy of it.
4. **Data-protection keychain.** Better isolation, but unavailable to this build
   without an application identifier.

## Consequences

- The PC gateway is reachable once a profile carries its endpoint and credential
  reference. S1a adds the mechanism; the configuration schema that names the PC
  by default, and the Settings key import, arrive in S2a and S2d. Until then the
  shipped default is still the loopback endpoint, which behaves as before.
- A key saved for one host is useless against any other host, so editing an
  endpoint cannot exfiltrate it.
- A gateway that moves behind a redirect stops working rather than silently
  following; the error names the 3xx.
- Expected, not yet measured: reading another program's keychain item shows the
  macOS access prompt, while Evie's own item (created in S2d) does not.
- Tests cover the policy rules and, with a URLProtocol stub that claims every
  host, the header rules and the redirect refusal. No unit test touches the
  network.
