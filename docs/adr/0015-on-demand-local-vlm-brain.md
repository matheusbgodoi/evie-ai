# ADR 0015: on-demand local VLM brain

Status: Accepted for Evie v2 (slice S3 implemented); superseded in part by
[ADR 0017](0017-per-launch-key-for-the-local-brain.md) (no `--api-key` and the
exact environment: the server now gets a per-launch key in its environment; who
answers is also checked for loopback-only sockets and the key)

Date: 2026-10-16

Supersedes in part: [ADR 0014](0014-model-profiles-per-turn-resolution-failover.md)
— the paragraph "Waking goes through a protocol": the stand-in
`EvieLocalBrainNotInstalled` is gone, and the protocol now also verifies a brain
the probe found answering. Everything else in 0014 stands.

## Context

`mac-local` is the brain Evie falls back to when the PC cannot answer: LensVLM-9B
(`mlx-community/LensVLM-9B-OptiQ-4bit`, Qwen3.5-9B language tower, licence
`apple-amlr`) on this Mac. It is heavy for a 24 GB machine, so it must not run
when nobody needs it, and it receives the conversation and, from S4, the screen,
so whatever answers on its port must really be it.

The design pass expected `mlx_vlm.server` to ignore the vision tower (a separate
`optiq` sidecar) and listed `optiq serve` and a wrapper of Evie's own as fallbacks.
Measured on 2026-10-16 on this Mac (M5, 24 GB, macOS 27.2, mlx-vlm 0.7.8 installed
as a uv tool, `HF_HUB_OFFLINE=1`):

- The vision tower is in the main safetensors (333 `vision_tower` keys).
  `mlx_vlm.server` described a synthetic image exactly (a red circle, a blue
  rectangle, the text "ZEBRA 4817"); a 32×32 red square came back "vermelho".
- Footprint 8,148–8,164 MB once loaded (`footprint`), 10 GB at peak; RSS reads
  only 300–450 MB because Metal buffers are not counted there.
- Started with the model on the command line, `/health` answered 5.4–6.5 s after
  launch, with the weights in the page cache. First text answer 6.69 s; a 1280 px
  screenshot described in 14.11 s; a tiny image answered in 2.1–2.6 s.
- Tool calls come back as malformed XML inside the content.

Read from the installed 0.7.8 source and checked live the same day:

- `--host` defaults to `0.0.0.0`; `--max-kv-size` sets `MAX_KV_SIZE`, and a
  request whose prompt plus `max_tokens` exceeds it is refused with a 400 — but
  only after **automatic compaction**, which, when `context_management` is absent,
  clamps `max_tokens` to what fits and, when the prompt itself does not fit, asks
  the model to summarize the older messages and answers from the summary.
  `context_management: []` turns that off (live: 400 "Request needs 40013 context
  tokens … but MAX_KV_SIZE is 32768").
- A top-level `enable_thinking` is honoured (`true` returned a
  `reasoning_content` trace; `false` none). Absent, the server's own default
  (off, unless started with `--enable-thinking`) is passed to the template, so
  the design's "thinks by default" holds for the template, not for this server.
- `/health` reports `loaded_model` and `configured_context_limit` (32768 with
  the flag); a request naming another model makes the server load it and drop
  the current one.
- `MLX_VLM_SERVER_API_KEY` in the environment would make the server demand a key.

## Decision

**Launcher: `mlx_vlm.server`, started on demand by Evie.** `LocalRuntime.launcher`
has one case, `.mlxVLM`; the alternatives are not needed. The executable is an
absolute path from the profile (`~/.local/bin/mlx_vlm.server`, expanded), never
looked up on `$PATH`.

**Exact command** (`LocalBrainPolicy.makeArguments`, EvieCore, tested): `--model
<profile model> --host 127.0.0.1 --port <port> --max-kv-size <cap> --max-num-seqs
1`. No `--api-key` (loopback only), no `--enable-thinking`. Naming the model loads
it at startup, and it equals the id requests send, so the server never swaps
models. `--max-num-seqs 1` makes the 32,768-token cap the memory cap.

**Exact environment** (`LocalBrainPolicy.makeEnvironment`): only `HOME`, `USER`,
`LOGNAME`, `TMPDIR`, `LANG`, `HF_HOME`, `HF_HUB_CACHE` are inherited, `PATH` is
`/usr/bin:/bin:/usr/sbin:/sbin`, and `HF_HUB_OFFLINE=1`, so a wrong model id
fails instead of downloading and nothing in Evie's environment reconfigures the
server.

**Requests** to a `.topLevel` server always carry `enable_thinking` and
`context_management: []`, so the server never rewrites the conversation; Evie's
own character budget keeps the prompt inside the cap.

**Who answers is checked, not assumed** (`EvieLocalBrainLauncher`, EvieShell):

- Before every turn on a brain the probe found answering, the process listening
  on the port (libproc: every process's socket descriptors) must be the
  configured server: its argv names the executable as program or as the script
  an interpreter runs, and the port; its image (`proc_pidpath`) is the
  executable or the interpreter its `#!` line names, symlinks resolved.
  Anything else is "A porta 38480 está ocupada por outro processo." and the turn
  is not sent.
- A start refuses a held port the same way, and after `/health` answers the
  listener must be the spawned process or one of its descendants
  (`proc_listchildpids`).
- A pid is signalled only after the same image and argv check, because pid files
  outlive processes and pids are reused.

**Memory** (`LocalBrainPolicy.startVerdict`): free + inactive + purgeable pages
from `host_statistics64` (`os_proc_available_memory` is unavailable on macOS),
minus 2.4 GiB when the voice engine is running (its idle pages read as
inactive), must be at least 8 GiB, the measured footprint. Otherwise the start is
refused with the numbers ("O Mac está com pouca memória livre para o cérebro
local: 6,0 GB livres, e ele precisa de ~8,0 GB. …").

**Lifecycle.** Started only by a turn that resolved to the Mac (after the
`macFallback` question when it asks), with "Acordando o cérebro do Mac…" on the
status line; `/health` is waited for up to 90 s. Each turn notes use at its start
and its end; after 10 idle minutes the launcher stops the server (SIGTERM, then
SIGKILL after 5 s). Quitting Evie stops it. At launch a stale pid file is removed,
and a live server it names (a crash's orphan, or one `Scripts/evie-brain`
started) is taken over, so it unloads like the rest.

**Manual path.** `Scripts/evie-brain start|stop|status|health` launches the same
argv and environment, writes the same `Application Support/Evie/Runtime/brain.pid`
and `brain.log`, and refuses a held port; a test holds the script to the policy.
`evie-shell --brain-check [--idle]` exercises the real launcher and client
without the overlay.

## Alternatives considered

1. **`optiq serve` or an Evie-owned wrapper around `OptiqEngine`.** Needed only if
   `mlx_vlm.server` could not see; it can. Either would be one more Python
   dependency to pin and keep.
2. **A LaunchAgent with `KeepAlive`.** Always resident: 8 GB held whether or not
   the PC is up, against ADR 0004's on-demand workers.
3. **Trust `/health`.** Any process on the port would be sent the conversation and
   the screen; a health body is easy to imitate and says nothing about who sent it.
4. **Kill whatever holds the port.** Destroys someone else's work to guess it was
   a stale Evie server.
5. **Leave compaction on.** The server would summarize a conversation with the
   model itself, silently, the moment an image cost more tokens than estimated.
6. **The spec's ~10 GB memory floor.** Measured: a start with 8.27 GiB free
   worked and moved 1.7 GB of other apps to swap; 10 GB would have refused it on a
   normal day on this Mac. Below 8 GiB the model would have to come almost wholly
   out of other apps' memory.

## Consequences

- The first turn that needs the Mac waits about 6 s for the start, plus the
  answer; the ask card's "(~10 s, ~8 GB de memória)" stands.
- A server started by hand with `mlx_vlm.server` (not the script) is used only if
  its argv matches the configured executable and port exactly; otherwise it is
  refused as a foreign process.
- An interpreter that is found on `$PATH` (`#!/usr/bin/env python3`) cannot be
  checked against the image, so such an executable's server is never trusted or
  signalled; the uv-installed one names its interpreter by absolute path.
- An oversized request to the Mac now fails with a 400 instead of being trimmed or
  summarized; `contextTokens` and the character budget are what prevent it.
- A turn on the Mac longer than ten minutes could be unloaded mid-answer; at the
  measured 7–20 tokens/s and a 2,048-token cap a turn takes under five minutes.
- The voice engine is detected by its port, not by identity; a stranger on 3900
  only makes the memory check stricter.
- `com.crias.omlx` (port 8477, a deleted venv) is unrelated; Evie never depends
  on it, and removing its LaunchAgent is the owner's call.
