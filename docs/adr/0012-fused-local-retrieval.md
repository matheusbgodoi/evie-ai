# ADR 0012: retrieval by three fused signals over a cached local embedding

Status: Accepted for the shipped retrieval path

Date: 2026-08-07 (recording the decision made in `a0e360f`)

## Context

Retrieval over the authorised folders used to be a substring scan through
`search_content`. It found "Cluemed", because that is a rare exact token, and it
found nothing at all for "quanto eu cobro" against a note that says "valor da
minha hora". `docs/RAG.md` had argued against an index on the grounds that a scan
is always current and cannot answer from a stale copy. That was true and beside
the point: the scan could not answer the question.

The constraints are the project's, not retrieval's. Nothing may leave the Mac, so
a hosted embedding API is out. Nothing may be resident, so a vector database as a
running service is out. And retrieval sits inside a turn that already costs about
sixty seconds against the local model, so its budget is what is left over rather
than what it would like.

This decision is named by `REL-001` as one of the things the first release needs
written down.

## Decision

Rank passages by three signals and fuse them with Reciprocal Rank Fusion, because
their scores are not on a common scale and never will be:

- the note's **title**, weighted double, because the person named the note
  themselves;
- the **words**, by BM25;
- the **meaning**, by cosine over `NLContextualEmbedding` — the model macOS
  already ships, so there is nothing to download, pin or verify.

`EvieVaultIndex` embeds each passage once and caches it, re-embedding only what
changed. Query terms come from `NLTagger` — part of speech and lemma — rather
than from a stopword list. Passages carry their origin, so an answer cites
"Cluemed › Captação › Eurofarma" rather than "nas suas anotações".

Every part of this came from a measurement taken before anything was designed
(`docs/RAG.md`):

| Measured | Result |
|---|---|
| Paraphrase pair, "quanto eu cobro pela consultoria" vs "o valor da minha hora" | 0.796, against 0.933 for a sentence that was actually unrelated |
| `NLContextualEmbedding` per passage | 8 ms |
| Static sentence embedding per passage | 30 ms |
| 6,112 passages, embedded once | 136 s |
| Retrieval per question, from the cache | about 700 ms |

The last two rows are the decision: 136 s is far too slow to pay per question and
perfectly acceptable to pay once, which is what makes the cache the architecture
rather than an optimisation.

## Alternatives considered

1. **Keep the substring scan.** Rejected by the failure that started this: it
   cannot answer a question phrased in different words from the note, which is
   most questions.
2. **A hosted embedding API.** Rejected on the project's first principle. Every
   note the user owns would leave the Mac to be indexed.
3. **A vector database as a local service.** Rejected under the "nothing
   resident" constraint that also governs `docs/AUTOMATIONS.md`. A cache file
   read at question time costs nothing between questions.
4. **The static sentence embedding.** Rejected on measurement: worse on the
   paraphrase pair and four times slower per passage.
5. **A stopword list for query terms.** Tried, and it was *worse* than what it
   replaced — "o que eu tenho sobre a Cluemed" returned a chemistry lesson,
   because "tenho" survived the list and, being rare in a vault of technical
   notes, earned a high IDF weight. Stopword lists assume the meaningless words
   can be enumerated; IDF assumes rare means informative. Both are wrong here.
6. **An inverted index, and the staged extraction/reranker/QMD pipeline in the
   rest of `docs/RAG.md`.** Not rejected — deferred, and deliberately. Retrieval
   is about 700 ms of a roughly 60 s turn; the model is the cost. That design
   stays in the document for the day a measurement says otherwise.

## Consequences

- First indexing of a large vault is a visible one-off cost, and re-indexing is
  incremental — only what changed is embedded again.
- Retrieval quality depends on a system model. macOS upgrades can move it, and
  nothing in this project pins it.
- `/buscar` runs exactly this retrieval and shows what it found, with no model
  call at any point, so the ranking is inspectable by a person rather than only
  by a test.
- The cache is derived state under Application Support and can be deleted at any
  time; the cost of deleting it is one re-index, not lost data.
- The unbuilt pipeline in `docs/RAG.md` is now explicitly a deferral with a
  trigger — a measurement — rather than a plan somebody is behind on.
