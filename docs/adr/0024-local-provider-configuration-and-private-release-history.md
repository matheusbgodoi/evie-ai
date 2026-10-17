# ADR 0024: Configurable providers without publishing a private connection

Status: Accepted, 2026-10-16. Amends ADR 0013's built-in remote host.

Public source, examples and binaries contain a reserved example endpoint rather
than the owner's private network address. The real endpoint and credential
reference remain in the user-only Application Support configuration; secret
values stay in Keychain. Live transport reads HTTPS hosts from that local saved
configuration at each request boundary, requires a credential bound to the exact
host, rejects URL credentials and never permits HTTP off loopback. Editing the
configuration cannot replay a key bound to another host. Saving a newly supplied
key explicitly binds a distinct Keychain item to the new address.

Profiles support OpenAI-compatible local or remote servers and an editable display
name independent of the served model identifier. Settings writes profiles through
the existing versioned read/merge store. A reserved .invalid host is only an
example, never an owner endpoint or a usable default service.

Unpublished v2 history previously contained private connection metadata. Preserve
that local development history; do not push it. Publish a sanitized release tree
with the existing public main as its sole parent, after scanning the full reachable
public ancestry and packaged artifact. A source-only replacement followed by an
ordinary push was rejected because Git retains the removed value in ancestors.

Tests cover runtime host changes, missing/malformed configuration, HTTPS and
credential mismatch, plus custom display names. Final public ancestry/artifact
scan evidence belongs in WORKLOG. Personal runtime configuration is never copied
into git or the application bundle.
