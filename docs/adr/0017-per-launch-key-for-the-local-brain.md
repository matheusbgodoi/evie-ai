# ADR 0017: a per-launch key for the local brain

Status: Accepted for Evie v2 (implemented 2026-10-16)

Date: 2026-10-16

Supersedes in part:

- [ADR 0015](0015-on-demand-local-vlm-brain.md) — "No `--api-key` (loopback
  only)" in **Exact command**, the **Exact environment** (it now carries the
  key), and "Who answers is checked, not assumed", which gains the loopback-only
  and key checks below. Everything else in 0015 stands.
- [ADR 0013](0013-authenticated-tailnet-model-transport.md) — "the bearer token
  is attached only over `https` … never over `http`, loopback included" gains
  one narrow exception, the key below. Every other rule in 0013 stands.

(The number 0016 is reserved for the computer-use authority of slice S5, which
the design names in advance.)

## Context

ADR 0015 started `mlx_vlm.server` on 127.0.0.1:38480 with no key, on the
reasoning that nothing but this Mac reaches loopback. That is not enough for a
server that receives the conversation and the screen:

- every process of every user on this Mac can connect to 127.0.0.1;
- a web page in any browser can reach a loopback HTTP server through DNS
  rebinding, and mlx-vlm 0.7.8 answers CORS with `allow_origins=["*"]`;
- the second v2 review found that a server started by hand on mlx-vlm's default
  `0.0.0.0` was adopted, and that the client could be pointed at another
  loopback port than the one whose listener was checked (both fixed the same
  day: the last `--host` must be `127.0.0.1`, every listening socket loopback,
  and the Mac profile's endpoint is its runtime's).

Read from the installed mlx-vlm 0.7.8 source (`server/app.py`, `server/cli.py`):
the key is `MLX_VLM_SERVER_API_KEY`, read from the environment on every request
(`--api-key` only copies itself into that variable); when set, every route —
inference, `/v1/models`, `/health`, `/metrics`, the cache and unload routes —
demands `Authorization: Bearer <key>`, compared in constant time, and answers
401 otherwise.

## Decision

**One key per launch, made by whoever starts the server.** The launcher
(`LocalBrainKeyFile.makeKey`: 32 bytes from the system's cryptographic
generator, 64 lowercase hex digits) or `Scripts/evie-brain` (`/dev/urandom`
through `od`) makes it right before the start.

**Kept in one place, for this user alone.** `~/Library/Application
Support/Evie/Runtime/brain.key`, beside `brain.pid`, mode 0600 in the 0700
runtime directory, created with that mode and renamed into place. It is read
back only from a regular file (not a symlink) owned by this user with no group
or other bits, holding exactly one key. It is removed with the pid file when the
server stops, when a start fails, and when a stale pid file is cleared. It is
never in the keychain, `config.json`, an argv, a log or diagnostics.

**Handed to the server in its environment, never its argv**
(`LocalBrainPolicy.makeEnvironment(inheriting:apiKey:)`), since any process of
this user can read an argv through `ps`. The script reads the file into the
variable inside the `exec` chain (`/bin/sh -c '… $(/bin/cat "$1") …'`), so the
key is in no argv there either, and gives curl the header on stdin.

**Sent only to that server.** `OpenAICompatibleClient.localBrainToken` attaches
the key over plain `http` only when the configuration is a Mac brain's
(`EvieConfiguration.localBrainPort`, set only for a `.localOnDemand` profile)
and the request goes to exactly `127.0.0.1` on that port — not `localhost`, not
`::1`, not another port. The readiness probe sends it on the brain's `/health`
by the same rule. This is the one exception to "no Bearer over http": the
credential is ephemeral, opens one loopback server for one launch, and is
useless to anyone who could not already read this user's files.

**Used only once the server holds to it.** Before the first turn on a server
(and after any restart, by pid and start time), the launcher asks `/health`
twice: without the key it must answer 401, with the file's key 2xx
(`LocalBrainPolicy.enforcesKey`). A server started by hand without a key, or
with another, is refused with "O servidor na porta 38480 não confirmou a chave
com que a Evie o iniciou; ela não vai mandar nada para lá." This also catches an
mlx-vlm upgrade that stops reading the variable.

## Alternatives considered

1. **No key (ADR 0015 as written).** Leaves the conversation and the screen open
   to other local users and to DNS rebinding.
2. **`--api-key` on the command line.** Simpler, but the key would be in the
   server's argv for its whole life, readable by every process of this user.
3. **A key kept in the keychain.** A durable secret for an ephemeral server: one
   more item, one more prompt, and nothing gained over a 0600 file that dies with
   the server.
4. **Checking the `Host` header instead.** mlx-vlm 0.7.8 does not check it, and a
   proxy of Evie's own in front of it would be another process to start, check
   and stop.
5. **Reading the server's environment to compare the key.** macOS no longer
   exposes another process's environment through `KERN_PROCARGS2` (checked
   2026-10-16 on macOS 27.2: only the argv came back), so the check is the
   server's own behaviour instead.

## Consequences

- Measured 2026-10-16 on this Mac (M5, 24 GB, macOS 27.2, mlx-vlm 0.7.8,
  LensVLM): started by `Scripts/evie-brain start` (ready 4.3 s), `/health`,
  `/v1/models` and `/v1/chat/completions` answered 401 without the key and with
  a wrong one; `/health` 200 and a chat request 200 (1.13 s) with it; the key was
  in neither argv; `brain.key` was `-rw-------`. `evie-shell --brain-check`
  adopted that server, confirmed the key, answered "vermelho" through Evie's
  client and stopped it (0.16 s), leaving no `brain.pid`, no `brain.key` and no
  process. From cold the launcher's own start answered the same way (up in
  3.18 s). A server started by hand with `--host 127.0.0.1` and no key was
  refused before anything was sent.
- A server started by an older `Scripts/evie-brain` (no key) is no longer
  adopted; stop it with `Scripts/evie-brain stop` and start it again.
- A request with no key file (deleted by hand while the server runs) goes
  without one and gets 401; the next wake refuses the server as unverified.
- Settings' "Testar conexão" still shows the key step as not needed for the Mac:
  there is nothing for the person to paste or import.
