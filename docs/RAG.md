# Local RAG design

Status: **retrieval over authorised folders is implemented and in use, matching on
meaning as well as on words.** The full pipeline design further down — staged
extraction, a reranker model, QMD — is still *not* built, and the reasons are
worth reading before anyone builds it.

## What was built

Three signals over the passages of the authorised folders, fused with Reciprocal
Rank Fusion because their scores are not on a common scale and never will be: the
note's **title** (weighted double, because the person named the note themselves),
the **words** (BM25), and the **meaning** (cosine over `NLContextualEmbedding`,
the model macOS already ships). `EvieVaultIndex` embeds each passage once and
caches it, re-embedding only what changed.

Every choice came from a measurement taken before anything was designed. A
paraphrase pair — "quanto eu cobro pela consultoria" against "o valor da minha
hora" — scored 0.796, against 0.933 for a sentence that was actually unrelated, so
the signal is real. And the contextual model took **8 ms** per passage against
**30 ms** for the static sentence embedding: better and four times faster, which
settled it. 6,112 passages at 8 ms is 136 s — far too slow per question, fine
once, which is what makes the cache the architecture rather than an optimisation.
A question then costs about 700 ms.

Passages carry where they came from, so an answer can cite "Cluemed › Captação ›
Eurofarma" rather than "nas suas anotações", and a paragraph that only says "eles"
is still findable.

### What this replaced, and why the old reasoning was wrong

Retrieval used to be a substring scan through `search_content`. It found "Cluemed"
because that is a rare exact token, and would find nothing for "quanto eu cobro"
against a note saying "valor da minha hora". This document previously argued
against an index on the grounds that scanning is always current and cannot answer
from a stale copy. That is true and was not the point: the scan could not answer
the question at all.

Query terms are extracted with `NLTagger` rather than a stopword list. The first
attempt used one, and was *worse* than what it replaced — "o que eu tenho sobre a
Cluemed" returned a chemistry lesson, because "tenho" survived the list and, being
rare in a vault of technical notes, earned a high inverse-document-frequency
weight. Stopword lists assume the meaningless words can be enumerated; IDF assumes
rare means informative. Both are wrong here. Part of speech decides instead, and
lemmatising came with it, which matters more in Portuguese than in English.

Three bugs were found by running it rather than by reasoning about it: the vault
indexed as empty because `.skipsHiddenFiles` discards everything beneath a hidden
ancestor and `~/Library` carries the hidden flag (701 entries without the option,
0 with it); the credential denylist was applied to the absolute path, so that same
component refused the vault outright; and the fallback for "the tagger recognised
nothing" also fired when it recognised everything and filtered it all, putting
every function word back.

An earlier end-to-end verification, 5 August 2026, against the user's own Obsidian
vault — 197 notes across `EU/`, `Cluemed/`, `Keymatic/`, `PUC-SP/` — asked *"o que
eu tenho anotado sobre a Cluemed?"* and got the company, the user's role, the site
and Instagram handle, the files involved, and a specific note about an Eurofarma
funding conversation, in 42 seconds. Reproduce with:

```bash
evie-shell --ask-folder "<vault>" "O que eu tenho anotado sobre a Cluemed?"
```

### `/buscar` — the same retrieval, without the model

Typing `/buscar` runs **exactly the retrieval an ordinary question runs** and
shows what it found — note, section, text — and stops there. Nothing about the
retrieval changes; the command is a way to look at it directly.

No model call is made at any point, **including when nothing is found**. The user
asked to search, and an answer written from memory shown where a search result
belongs is a lie about where it came from. It leaves no trace in the conversation
either, because quoting the user's notes back as something Evie said would strip
the fence that keeps note text data rather than instruction.

`/web` is its opposite and is documented with the loop rather than here: it skips
the notes and forces a lookup. Both are anchored at the start of the message and
require a boundary after the name, and the test that matters is the one listing
prose that must not trigger them — "/webhook do Stripe parou" and "/buscarei um
jeito" are things somebody wrote.

### Still not built: an inverted index

Retrieval is about 700 ms of a roughly 60 s turn. The model is the cost. Building
an inverted index would be effort spent where nothing is measurable, and it stays
unbuilt until a measurement says otherwise.

### Bounds, and why they are visible

`EvieFileToolbox` scans at most 600 text files, four directories deep, and returns
at most twelve matching lines with at most three per file. A search that stops
early says so, because a truncated search that reports nothing is indistinguishable
from a search that found nothing.

The credential denylist applies to retrieval exactly as it does to reading: a
`.env` inside the vault is never opened, so its contents cannot surface as a
match. `~/Library` is refused wherever it appears, so authorising a home folder
does not turn Mail and Messages into a retrieval corpus.

### Memory is a different thing, and is also not an index

Retrieval answers "what did I write". Memory answers "what did I tell her". They
are kept apart deliberately: the vault is the user's own writing and Evie only
reads it, while memory is what was said out loud in a conversation and exists
nowhere else.

The user chose propose-and-confirm over both "only when I say so" and "she
decides". `EvieMemoryTool` is a tool that stores nothing: it raises a card, and a
click stores. That preserves the project's invariant — no tool the model can call
changes anything — and it is the answer to the failure mode every self-writing
memory has, where one misunderstanding becomes a permanent fact and later answers
are wrong in a way whose origin cannot be traced.

Bounded at sixty entries and two thousand recalled characters, because every
memory is paid for on every turn.

### Read-only, structurally

There is no tool that writes. The vault is a source and never a destination, and
that is a property of the vocabulary rather than a rule the model is asked to
follow.

---

The rest of this document is the **unbuilt** index design, kept for the day the
scanning approach stops being adequate.

## Purpose

RAG gives Evie access to explicitly approved personal knowledge without expanding
every prompt or treating model memory as a document store.

## Source boundary

Each collection has:

- an explicit source root or connector;
- an owner and purpose;
- allowed file/content types;
- read and refresh permissions;
- sensitivity and retention classification;
- an independent delete/rebuild operation.

Original sources are immutable to the indexing pipeline. Extraction writes into a
separate staging/cache area.

## Ingestion pipeline

```text
approved source
  -> enumerate and fingerprint
  -> extract text safely
  -> normalize while preserving provenance
  -> chunk by document structure
  -> keyword index + embeddings
  -> optional reranker metadata
  -> atomic index revision
```

Candidate sources include Markdown/text, PDFs, office documents, email exports,
meeting transcripts, Drive documents, and user-selected folders. Every result must
retain source identity, modification time, and a way to open the original.

## Retrieval pipeline

1. classify the target collections;
2. run keyword and semantic retrieval;
3. merge and deduplicate;
4. optionally rerank the small candidate set;
5. enforce collection permissions;
6. inject only the top bounded excerpts;
7. require source attribution in the answer.

Retrieval text is untrusted. A document that says "ignore your instructions" does
not gain authority over the system or tool permissions.

## Engine options

### QMD baseline

Advantages: ready local hybrid retrieval, MCP integration, embedding/query expansion
and reranking, and an existing Hermes skill.

Tradeoff: its documented warm daemon is around 2 GB and cold model initialization
can be noticeable. It can run on demand first.

The current candidate pin is QMD `v2.5.3`, dereferenced commit
`53232770867ccb16538c2c6034e7d891dffc9ce3`. Evie should wrap its library behind an
`evie-rag` worker with an explicit database path and close it after roughly 60–120
seconds idle. Do not expose raw QMD MCP or its configuration `update` command to the
agent: the wrapper must enforce collection isolation and no arbitrary shell/config
surface.

Start with normalized immutable Markdown staging and keyword/BM25 citations. Then
add hybrid retrieval with query expansion plus embeddings and no reranker. The
first embedding baseline is multilingual EmbeddingGemma 300M Q8; compare it with
Qwen3-Embedding-0.6B only if the extra memory improves PT-BR retrieval. Add QMD's
larger reranker only after measured precision/recall/MRR and citation gains justify
its cold latency and resident memory.

### Lightweight custom option

SQLite FTS/BM25 plus a compact embedding model may use less resident memory and
provide tighter ingestion/security control. It requires more engineering for
chunking, format extraction, reranking, citations, incremental updates, and MCP/tool
integration.

Phase 4 should compare both on the same Portuguese/personal-document evaluation
set before deciding.

## Context budget

Normal retrieval should inject roughly 3–8 concise excerpts, not entire documents.
The exact token budget is adaptive to the active conversation and must leave room
for tools and response. Large sources are paged or summarized with provenance.

## Index scheduling

- small updates may run after a filesystem/event debounce;
- expensive embedding batches prefer idle AC power;
- indexing pauses on memory pressure or active foreground workloads;
- the index revision swaps atomically after successful completion;
- failed extraction does not remove the last valid representation.

## Privacy

Indexes, extracted content, caches, and collection manifests with private paths stay
outside Git. Deleting a collection deletes its derived local content and verifies
that no active index references remain.
