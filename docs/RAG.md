# Local RAG design

Status: **agentic retrieval over authorised folders is implemented and in use.**
The embedding-index design below is *not* built, and the reason is worth reading
before anyone builds it.

## What was built instead of an index

Evie retrieves by searching, as a step she chooses, using the same read-only tools
that reach any authorised folder: `search_content` looks inside the text,
`search_files` looks at names, `read_file` opens what looks relevant. She decides
whether to search at all, what to search for, and whether to follow a result by
opening the file.

Verified 5 August 2026 against the user's own Obsidian vault — 197 notes across
`EU/`, `Cluemed/`, `Keymatic/`, `PUC-SP/`. Asked *"o que eu tenho anotado sobre a
Cluemed?"*, she called `list_roots` then `search_content`, and answered in 42
seconds with the company being a healthtech, the user's role, the site and
Instagram handle, the files involved, and a specific note about an Eurofarma
funding conversation including the CEO's objection to corporate VC on the cap
table. Reproduce with:

```bash
evie-shell --ask-folder "<vault>" "O que eu tenho anotado sobre a Cluemed?"
```

### Why not embeddings

An index would answer faster and would match on meaning rather than on the word
that happens to be typed. It would also need building, rebuilding on every edit,
and storing a second copy of everything the user has written. For a vault of a few
hundred notes on the machine that owns them, scanning is fast enough, is always
current, needs no storage, and cannot answer from a stale copy of a note that
changed this morning. The failure mode of a stale index — a confident answer from
text the user already deleted — is worse than the failure mode of scanning, which
is being slower.

The point at which this stops being true is measurable, not a matter of taste:
when a search takes long enough to be felt, or when the vault outgrows
`maximumFilesSearched`. The pipeline below is the design for that day.

### Bounds, and why they are visible

`EvieFileToolbox` scans at most 600 text files, four directories deep, and returns
at most twelve matching lines with at most three per file. A search that stops
early says so, because a truncated search that reports nothing is indistinguishable
from a search that found nothing.

The credential denylist applies to retrieval exactly as it does to reading: a
`.env` inside the vault is never opened, so its contents cannot surface as a
match. `~/Library` is refused wherever it appears, so authorising a home folder
does not turn Mail and Messages into a retrieval corpus.

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
