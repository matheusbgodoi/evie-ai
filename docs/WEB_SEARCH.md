# Local-first web research

Status: researched; no web-search provider or fetcher is installed/enabled.

Last reviewed: 2026-08-04

## Decision direction

Start with DDGS as a free, no-account, search-only prototype and implement page
fetch/extraction in an Evie-owned worker. Do not run SearXNG or Docker for the
first slice. SearXNG adds a continuously managed service yet does not remove the
need for safe page fetching, content limits, provenance, and prompt-injection
handling.

The candidate pin is DDGS `v9.9.3`, dereferenced commit
`18d386d67de9ad39a458a066804ca6b310e0f524`. DDGS depends on public search engines
and can break or rate-limit; it is best-effort personal research, not a
professional availability SLA. Queries leave the Mac even though search
orchestration and answer synthesis remain local.

Initial policy:

- 5–8 results, Brazilian Portuguese/Brazil locale, moderate SafeSearch;
- approximately one request per second, bounded retries, and a 15–60 minute cache;
- no automatic multi-engine fan-out, which would disclose each query more widely;
- visible provider/URL/date provenance and citations in every researched answer;
- no cookies, accounts, browser-profile reuse, or authenticated pages.

## Safe fetch boundary

Search snippets and pages are untrusted data. A dedicated fetcher must:

- accept only HTTP(S), reject URL credentials, and validate DNS/IP again after
  every redirect;
- block loopback, private, link-local, multicast, reserved, and cloud-metadata
  destinations;
- allow no more than three redirects, approximately 2 MB response bodies, known
  text/document MIME types, and 10–20 second timeouts;
- run without cookies, authentication, browser profile, local-file access, or
  arbitrary JavaScript for the baseline;
- sanitize and bound extracted text (initially about 15,000 characters);
- return title, canonical URL, retrieval time, content type, and trust/provenance
  metadata;
- never interpret page instructions as tool calls, approval, or new scope.

Brave Search may be an optional future provider, but it requires an account/key
and is therefore not the 100%-free/local-first default requested here.

## Primary sources

- [Hermes web-search integration](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-search/)
- [DDGS repository](https://github.com/deedy5/ddgs)
- [SearXNG documentation](https://docs.searxng.org/)
