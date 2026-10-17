# ADR 0019: saving a new document when asked, and opening files without a card

Status: Accepted (implemented on branch `v2-files`, 2026-10-16)

Date: 2026-10-16

Amends: [ADR 0009](0009-nominal-capability-authority.md), narrowly. Every
other change still needs explicit approval evidence; the standing-policy
rejection for destructive operations is untouched.

## Context

The owner, a university student who does not program, asked for Evie to work
like a command-line agent for everyday computer tasks: "se eu falar pra salvar
algo na minha mesa, desktop, analisar uma pasta… escrever documentos, ler,
acessar meu PC". Three things in that request meet ADR 0009's rule that a
commit needs approval evidence:

1. **Writing a document.** `propose_document` produces a proposal and a card
   with Salvar and Salvar e abrir. That stays the default. But a person who
   typed "salva isso na minha mesa" has already said the thing the button would
   say, and a second confirmation for the same sentence is the friction that
   makes an assistant feel like a form.
2. **Opening a file or revealing it in the Finder.** Neither changes a file.
   A card for "abre o PDF" would be a click to confirm a click.
3. **Granting a well-known folder.** Until now a folder became reachable only
   through `NSOpenPanel`. Asked about "minha mesa", Evie could only say she had
   no access.

## Decision

**A new document may be saved without its card under one policy, opt-in and
off by default:** "Salvar direto quando eu pedir explicitamente"
(`EviePreferences.savesDocumentsWhenAsked`). All of these must hold:

- the switch is on, read when the question is asked;
- the person's **own** message — the typed or spoken prompt, nothing else —
  asks to save (`EvieDocumentIntent`: "salva", "salve", "salvar", "grava",
  "cria um arquivo", …; "não salva" does not count);
- no picture rides in the request (`EvieTurnPlan.savesDocumentsDirectly`), so
  text on the screen never counts as asking;
- the destination is a folder granted **before** the turn; a document that
  needed a folder permitted first always waits for Salvar;
- the file is **new**: `EvieDocumentCreator` opens it `O_CREAT | O_EXCL`
  beneath the root descriptor and moves to "nome (2).ext" on a clash.

Never covered, whatever the switch says: overwriting a file, moving or renaming
one, sending one to the Trash, and anything a document, a web page, a mail
message or the screen asked for. Text from those sources reaches the model as
fenced data and is never the prompt `EvieDocumentIntent` reads. Every direct
save is reported on screen ("Salvei resumo.docx sem te perguntar", where, and
how to switch it off) exactly as loudly as an approved one.

**Opening and revealing are low-risk actions the model may take without a card**
(`open_file`, `reveal_in_finder`), under three limits enforced in code:

- inside a granted folder, resolved through the contained reader;
- `open_file` opens only documents, from an allowlist — known document
  extensions, or a PDF, image, audio/video or plain-text type that is none of
  executable, bundle, package, application, script, source code or web content.
  Apps, scripts, `.command`, `.sh`, `.pkg`, `.dmg`, `.terminal`, workflows,
  HTML, SVG and web archives are refused; folders, bundles and packages are
  reveal-only;
- each action is a status line while it happens and a line in the transcript.

**A well-known folder may be granted by a one-click card.** Mesa, Documentos,
Downloads and the iCloud Obsidian vault are fixed in `EvieSuggestedRoot`; the
model can name one by its alias, and the most that does is draw "Permitir que a
Evie leia sua Mesa". Nothing is granted until the button is pressed, and macOS
then asks its own question once for the folder. `NSOpenPanel` stays the only
way to grant any other folder.

## Alternatives considered

1. **Keep a card for every save.** Safest, and the default. Rejected as the only
   mode because the owner asked for the agent experience in so many words, and
   the request already contains the approval.
2. **Reuse "Fazer sem me perguntar" (`autoApproveChanges`).** Rejected: that
   switch covers moves and the Trash. Saving a new file is strictly less
   dangerous and deserves its own, narrower switch, so turning one on never
   turns on the other.
3. **Trust the model's judgement of whether he asked.** Rejected: a model
   cannot tell where a sentence in its context came from. The person's prompt
   can be read directly.
4. **Allow overwriting when he says "substitui".** Rejected: overwriting is the
   one write here that loses data, and it stays outside any standing policy.
5. **A card for opening a file.** Rejected: it confirms an action that changes
   nothing, after code has already refused everything that runs.
6. **Grant the well-known folders at first launch.** Rejected: silent grants are
   what the folder model exists to prevent, and macOS would ask anyway.

## Consequences

- "No tool the model can call changes anything" now has two exact exceptions:
  `open_file` / `reveal_in_finder` act on the screen (never on a file), and,
  only under the switch above, a new document is written after the turn by the
  shell — not by the tool, which still records a proposal and returns.
- The intent match is matching, not proof. A person who repeats a document's
  words ("salva…") has asked. The exposure is bounded by what it unlocks: one
  new file in a folder he granted, reported on screen.
- There is a check-to-use gap in `open_file`: the path is verified through a
  descriptor and then handed to `NSWorkspace` by URL. For an action that changes
  nothing and refuses what runs, that race is accepted.
- `SECURITY.md` and `FILESYSTEM.md` describe the boundary; the Settings switch
  lives in `DocumentSettingsSection`, beside the folders.
