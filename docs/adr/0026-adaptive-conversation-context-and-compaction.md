# ADR 0026: Adaptive context and automatic conversation compaction

Status: Accepted, 2026-10-16. Amends ADRs 0014/0015/0021.

The owner requested the same Qwen context as OpenCode, the largest viable local
VLM context, and reliable model changes during a long conversation. The old turn
builder silently discarded the oldest turns according to a character estimate.

The PC client now uses 200,704 tokens, matching the verified OpenCode configuration
and qualified gateway runtime. The published 262,144 architectural ceiling and
optional one-million-token YaRN extension do not qualify larger server windows.
The local model's effective window is chosen from isolated hardware validation,
not from its nominal configuration alone. MODEL_TUNING records those results and
the original failure cases. Output, persona, tools, history, images and the new
question share one context; a larger configured window does not allocate blank
tokens or force longer answers.

Each chat prefix is rebuilt for the selected model. At roughly 75% of the input
budget an in-memory compactor summarizes older turns, preferentially keeping six
recent turns and always preserving the current tail verbatim. A smaller target
moves additional older turns into the summary. Summary requests have no tools,
no history retrieval, bounded output and cancellation. Source images are omitted
from summary calls but their taint follows the resulting summary, preserving the
existing restrictions on tools and auto-approval. Summaries are user-role data,
never a new system instruction or authorization. The complete stored conversation
is retained. Summaries can lose detail; their fence says to consult original
history for important details rather than pretending they are lossless.

A bounded four-entry cache fingerprints the summarized prefix, target identity
and budget. New recent turns stay raw until compaction is needed again. Model
changes use a target-specific budget; switching back may reuse a valid cached
summary. Changing conversation or stopping revokes pending results and clears the
cache. An overlarge current question is reported without silent truncation.

The compact brain popover shows the selected context/output ceilings, the last
prompt token count reported by the server (or an explicitly marked estimate),
and compaction progress. The typing field stays the same width. Long ordinary
text answers may use the configured completion cap instead of an unrelated
2,048-token chat cap; voice and computer steps retain their separate budgets.

Character estimates are not tokenizer counts. The implementation reserves reply
space and leaves input margin; real server usage remains authoritative. Synthetic
cross-model, cancellation, cache, malformed-output, picture-taint and small-budget
regressions validate the logic. Signed runtime diagnostics and effective hardware
results are recorded in WORKLOG and MODEL_TUNING before release.
