# ADR 0014: model profiles, per-turn resolution and per-conversation failover

Status: Accepted for Evie v2 (slice S2c implemented; S2a's profiles and S2b's
readiness probe are its inputs); superseded in part by
[ADR 0015](0015-on-demand-local-vlm-brain.md) (the paragraph "Waking goes
through a protocol")

Date: 2026-10-16

Builds on: [ADR 0013](0013-authenticated-tailnet-model-transport.md), which made
the primary model a per-profile choice.

## Context

Evie v2 has two brains with very different shapes:

- `pc-3090`: `qwen-daily` on the owner's RTX 3090 behind the tailnet gateway, a
  135,168-token client cap, vision and tool calls, a key in the keychain.
  Measured 2026-10-16 from this Mac (thinking off): a text answer in 2.13 s, a
  structured tool call in 1.22 s, one 1280 px screenshot in 57.56 s, because the
  vision projector runs on the PC's CPU.
- `mac-local`: LensVLM-9B on this Mac under `mlx_vlm.server` 0.7.8. Measured
  2026-10-16 (M5, 24 GB, macOS 27.2): 8,164 MB resident (10 GB at peak), a first
  text answer 6.69 s after the request, a 1280 px screenshot described in
  14.11 s. It reads images, but tool calls come back as malformed text in the
  answer, so it is offered no tools. Its context is capped at 32,768 tokens on
  both sides for memory.

The PC is preferred, but it can be off, asleep, gaming, or missing its key. Before
this decision one client was built at launch from one profile, and three things
that depend on the brain were fixed before any request: the history's character
budget, the persona (including "where you run") and the declared tools. A switch
inside `stream()` would come too late, and `AgentClient.stream` does not know
which conversation it serves.

## Decision

**Resolve per turn, before the turn is built.** `EvieBrainResolver.resolve(conversation:)`
returns a `ResolvedBrain` — the profile, a client for it, the readiness rung,
and a notice when the preferred profile was passed over. The turn then builds
everything from the profile (`EvieTurnPlan`): the budget (about two characters
per token of `contextTokens − maxCompletionTokens`: 237,568 on the PC, 61,440 on
the Mac), the persona's location sentence, tools only when
`capabilities.tools`, pictures only when `capabilities.vision`, and
`TurnOptions` carrying the rung so the readiness deadlines apply.

**How a new conversation is resolved.** The preferred profile (the loader's:
`EVIE_MODEL_PROFILE` or the preference order) unless it cannot answer. What
cannot answer is first known without the network — `EvieProfileSelector`'s
`offlineRung`: the transport policy refuses it, or its key is missing — and
otherwise from the readiness cache: unreachable, key rejected, model unknown.
Then the preference order is walked for the first profile with no offline rung
whose cached rung is `ready` or `modelCold`.

**Pin per conversation.** The conversation keeps the profile its first turn ran
on, in memory, for the app session. It never switches mid-thread, even when the
PC comes back.

**Failover only before the first delta.** When a turn fails with `unreachable`
(502 included), `headersTimedOut`, `unauthorized` or `credentialUnavailable` and
the model produced nothing yet — watched on the client, so it holds across every
step of the agent loop — `failover(conversation:after:)` refreshes the failed
profile's readiness, walks to the next profile, re-pins, and the caller rebuilds
the whole turn for it and retries once (`EvieBrainTurn.run`). There is no
failover after a delta, for a slow load (`firstTokenTimedOut`), or to another
alias on the PC, which would evict `qwen-daily`.

**`macFallback` governs every move.** `.off` never moves; `.automatic` moves;
`.ask` asks before *waking* a brain on this Mac — "O PC está fora. Acordar o
cérebro do Mac? (~10 s, ~8 GB de memória)", with the reason adjusted for a
missing or refused key — and a yes counts for the rest of the app session. A Mac
brain that already answers is used without asking. A profile the environment
chose is never moved.

**Waking goes through a protocol.** For a `.localOnDemand` profile that is not
answering, the resolver calls `LocalBrainStarting.ensureRunning()`. The concrete
launcher is v2 S3's; until then `EvieLocalBrainNotInstalled` throws "O cérebro do
Mac ainda não está instalado nesta versão da Evie.", and that turn fails with the
reason instead of timing out against a closed port. A brain that cannot start is
not pinned.

**The tool-less path.** A profile without tools still searches the folders and
the web before the request (the agent loop's grounding step) and then asks once
with no `tools` key; the persona describes that evidence as arriving with the
question and names no function. Mail and Calendar, which only tools reach, are
announced as unavailable on such a brain.

## Alternatives considered

1. **Switch inside the client** (a failover `AgentClient`). Transparent to the
   callers, but it would resend a prompt built for the PC — 135K budget, tools,
   pictures, "você roda no PC" — to a 32K brain without tools, and it cannot pin
   per conversation because the client does not know the conversation.
2. **Choose once at launch** (the 2026-10-16 interim, `EvieProfileSelector.choose`).
   Cheap, but it cannot react to the PC going away during the session, and it
   moved every conversation, not the one that needed it.
3. **Fail over mid-answer.** The text already shown would be continued by a
   different model with a different history budget; duplicated or contradictory
   text is worse than a clear error.
4. **Always ask, or never ask, before using the Mac.** Always asking would
   interrupt every turn of a conversation already on the Mac; never asking would
   take 8 GB from someone who did not expect it. The question is asked only when
   it costs something, and once per session.

## Consequences

- Settings edits the profile the loader resolves (the preferred one, or the one
  `EVIE_MODEL_PROFILE` names), not the profile a given conversation is pinned
  to; the per-profile pane is S2d's.
- With the PC unreachable, a new conversation pays at most the probe's 3 s
  `/health` deadline before moving (`ModelReadinessProbe.Deadlines.standard`).
- `/plano` resolves and pins like any turn, but its several requests catch their
  own errors, so it does not fail over.
- The schedule runner and the diagnostics still build clients from the preferred
  profile directly: a scheduled run declares tools, which the Mac profile cannot
  take.
- Tests (`EvieBrainResolverTests`, `EvieBrainTurnTests`) use a readiness cache
  whose check is a table, a key store the test controls, recording clients and a
  launcher double; no unit test touches the network or the keychain.
