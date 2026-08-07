# ADR 0010: refuse a recipient the conversation never contained

Status: Accepted for `propose_mail`

Date: 2026-08-07

## Context

`propose_mail` (`6dade94`) lets Evie compose a message that a person then sends
with a button. Everything else she can do is reversible on this Mac: a file goes
to the Trash, an event is deleted in two clicks. A sent message is neither
reversible nor local — it arrives at somebody else.

The failure this feature has to survive is not a typo in the body. It is the
wrong recipient, and the way the wrong recipient arrives is that the model does
not have an address and writes one anyway. Asked to write to somebody it has no
address for, a model does not stop; it produces `pedro.silva@gmail.com`, which is
shaped exactly like a real address and may well belong to a stranger who now has
the message.

The obvious design is to compose anyway and mark the invented address on the
card — a badge, a colour, a "não conferido" next to it. That design was
considered and rejected here.

## Decision

Every recipient must appear, in full, in a non-assistant turn of the
conversation. An address outside that set is a refusal
(`EvieMailProposal.RejectionReason.unknownAddress`) and no card is drawn.

- The evidence set is built by `EvieAgentLoop.knownAddresses(in:)` from the
  user's own turns, the system message that carries what he let her remember, and
  the tool results the apps handed back — so an address `read_mail` showed
  qualifies, and so does one he typed a minute ago.
- **Assistant turns are excluded.** A model that wrote an address two steps ago
  must not be able to cite itself as evidence that the address exists.
- Matching is on whole tokens, lowercased, not on substrings
  (`EvieMailProposal.addresses(in:)`). `contains("pedro@empresa.com")` is true of
  a conversation that only ever said `pedro@empresa.com.br`, and honouring that
  would send the message to a different domain from the one anybody wrote down.

This catches a hallucinated address. It does **not** catch an address that
arrived inside a message somebody else sent — that address is in the
conversation and passes, deliberately, because replying to what was read is the
ordinary case. What is left to catch a hostile address is the card, which is why
the card lists every recipient in full, one per line, and never a count or a
truncated list. Of the two halves, the card is the more important one.

## Alternatives considered

1. **Compose, and badge the unverified addresses on the card.** Rejected. It
   relies on the reader noticing which of three plausible addresses is the
   invented one, which is precisely the thing people do not notice — and it asks
   them to notice it while under time pressure, on a card whose primary button
   sends. The badge is worth exactly as much as the attention it does not get.
2. **Ask the model to confirm the address before composing.** Rejected: the
   check would be performed by the same component that invented the address.
3. **Keep an address book Evie may consult.** Rejected for now. It is a second
   store of personal data, it goes stale, and it moves the problem rather than
   solving it — a name resolving to the wrong stored address fails silently in
   the same way.
4. **Substring matching, as a gentler version of the same rule.** Rejected on
   the `pedro@empresa.com.br` / `pedro@empresa.com` case: a check that passes an
   address nobody wrote is not a check.

## Consequences

- The cost of the rule is one round trip: she says she does not have the
  address, he types it, and from that moment it is in the conversation and
  passes. The cost is paid on the first message to a person and never again in
  that conversation.
- Replying to somebody who wrote to him works without any special path, because
  `read_mail` put the address in the conversation.
- The rule is a property of the composer rather than an instruction in the
  persona, so a message telling her to write to somebody else cannot argue with
  it — the address in that message still has to be an address.
- It does not defend against a hostile address planted in a message that was
  read. That defence is the recipient list on the card, and it is the reason
  nothing on that card is ever summarised.
- An address he wrote with a typo is evidence for itself. The check answers
  "did anybody but the model write this", not "is this the right person".
