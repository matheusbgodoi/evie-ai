# ADR 0011: a draft button beside the send button

Status: Accepted for `propose_mail`

Date: 2026-08-07

## Context

Every confirmation card in Evie until now had two answers: do it, or do not. A
file change is either applied or declined; an event is either created or it is
not. Both are reversible, so two answers are enough.

The mail card is the first one whose primary action reaches somebody else and
cannot be taken back. It is also the first one where the common reaction is
neither yes nor no. A composed message is usually *nearly* right — the recipient
is correct, the subject is correct, and one sentence needs changing. With two
buttons that reaction has only one home, "Não", after which the work is gone and
the request has to be made again.

Mail already solves the remaining half of that problem. It is where editing and
sending a message belong on this Mac, and Evie has no editor and should not
grow one.

## Decision

The card offers three answers: **Enviar**, **Salvar rascunho**, **Não**.

- `EvieMailSending` carries two functions rather than one — `sendMail` and
  `saveMailDraft` — and `EvieAppleScripts.saveMailDraft` is the sending script
  with the last verb removed. The suite asserts that the sending one contains
  `send msg` and the drafting one does not.
- A draft reaches nobody. It is filed in Rascunhos, where Mail's own editing and
  sending are, so "almost right" becomes a message he finishes himself.
- **"Não" writes nothing anywhere** — no draft, no file, no message — but the
  composed text stays on screen as a collapsed card with a copy button.
  Discarding a card used to take the composition with it.

Both writing buttons are held to the same conditions: no auto-approve path,
including when file auto-approval is on, and the Mail and agenda switch is
re-read at the moment of the press rather than trusted from when the card was
drawn.

## Alternatives considered

1. **Two buttons only, send or nothing.** Rejected. It makes the destructive
   answer the only way to express "not quite", which trains a person to press
   the irreversible button rather than lose the work.
2. **An editable body on the card.** Rejected. It is a text editor inside a
   confirmation surface, it invites editing under time pressure next to a button
   that sends, and it duplicates an application the Mac already has.
3. **Always save a draft, and let sending be a second step in Mail.** Rejected
   as the only mode: it removes the feature the owner actually asked for. Kept as
   the *offered* mode, which is what this decision is.
4. **A "remember this choice" checkbox on the card.** Rejected outright. It is
   an auto-approve path for sending mail wearing a different name.

## Consequences

- The safer of the two writing actions is available at no extra cost and at no
  extra risk: a draft that reaches nobody is strictly less dangerous than the
  message the card was drawn for.
- `EvieMailSending` has two members, so anything implementing it must implement
  both. The protocol is held by the shell only; `EvieAgentLoop` does not hold it
  and cannot be given it, so neither button is reachable from a tool call.
- Three buttons is one more than every other card in the application, which is a
  small inconsistency accepted deliberately for the one card whose primary action
  cannot be undone.
- Editing a message is not Evie's job and is not on the roadmap because of this
  decision: the answer to "change one word" is a draft in Mail.
