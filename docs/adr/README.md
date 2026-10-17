# Architecture decision records

ADRs capture durable decisions and their tradeoffs. Accepted records are historical;
supersede rather than silently rewrite them when the decision changes.

| ADR | Title | Status |
|---|---|---|
| [0001](0001-documentation-first.md) | Documentation-first, gate-based delivery | Accepted |
| [0002](0002-primary-model-and-context.md) | Gemma/TurboFieldfare primary candidate at 64K FP16 KV | Accepted for planning; superseded in part by 0013 (the primary model is chosen per profile, `qwen-daily` on the PC by default) |
| [0003](0003-native-overlay.md) | Native macOS overlay inspired by CLUI CC | Accepted for planning |
| [0004](0004-specialist-workers.md) | On-demand specialist workers | Accepted for planning |
| [0005](0005-node-red-workflow-plane.md) | Node-RED as visual deterministic workflow plane | Accepted for planning |
| [0006](0006-direct-turbo-vertical-slice.md) | Backend-neutral core with direct TurboFieldfare prototype adapter | Accepted for VS-001; superseded in part by 0013 |
| [0007](0007-local-development-runtime.md) | Pinned local development runtime outside Git | Accepted for first-test development |
| [0008](0008-local-conversation-history.md) | Local visible conversation history before Hermes | Accepted for native-shell prototype |
| [0009](0009-nominal-capability-authority.md) | Nominal read/propose/commit with process-local authority | Accepted for policy-broker foundation; amended by 0016 and 0019 |
| [0010](0010-refuse-unseen-mail-recipients.md) | Refuse a recipient the conversation never contained | Accepted for `propose_mail` |
| [0011](0011-draft-beside-send.md) | A draft button beside the send button | Accepted for `propose_mail` |
| [0012](0012-fused-local-retrieval.md) | Retrieval by three fused signals over a cached local embedding | Accepted for the shipped retrieval path |
| [0013](0013-authenticated-tailnet-model-transport.md) | Authenticated tailnet model transport | Accepted for Evie v2 (S1a); supersedes 0006 in part, amends 0002 in part; superseded in part by 0017 |
| [0014](0014-model-profiles-per-turn-resolution-failover.md) | Model profiles, per-turn resolution and per-conversation failover | Accepted for Evie v2 (S2a–S2d); superseded in part by 0015 |
| [0015](0015-on-demand-local-vlm-brain.md) | On-demand local VLM brain | Accepted for Evie v2 (S3); supersedes 0014 in part; superseded in part by 0017 |
| [0016](0016-in-process-computer-use-executor-under-agent-mode-grant.md) | An in-process computer-use executor under an agent-mode grant | Accepted for Evie v2 (S5a–S5d implemented; manual QA open); amends 0009 |
| [0017](0017-per-launch-key-for-the-local-brain.md) | A per-launch key for the local brain | Accepted for Evie v2; supersedes 0013 and 0015 in part |
| [0018](0018-agent-mode-switch-on-by-default.md) | Agent mode behind a Settings switch, on by default | Accepted for Evie v2 (S5c); amends the design's S5c flag |
| [0019](0019-saving-a-new-document-when-asked.md) | Saving a new document when asked, and opening files without a card | Accepted (branch `v2-files`); amends 0009 narrowly |
| [0020](0020-expiring-research-shortcut-sessions.md) | Expiring research sessions with two configurable shortcuts | Accepted; amends 0016 narrowly |

| [0021](0021-explicit-brain-choice-for-current-conversation.md) | Explicit model choice in the current conversation | Accepted; amends 0014 |
| [0022](0022-owner-enabled-capabilities-and-system-permissions.md) | Enabled capabilities and real system permissions | Accepted; amends 0018/0019 defaults |
| [0023](0023-public-app-intents-with-generated-bundle-metadata.md) | Public AppIntents and generated bundle metadata | Superseded for local builds by 0029 |
| [0024](0024-local-provider-configuration-and-private-release-history.md) | Local provider configuration and private release history | Accepted; amends 0013 |
| [0025](0025-native-voice-and-explicit-wake-calibration.md) | Native voice and five-phrase wake calibration | Accepted |
| [0026](0026-adaptive-conversation-context-and-compaction.md) | Adaptive context and automatic compaction | Accepted; amends 0014/0015/0021 |
| [0027](0027-pinned-public-web-transport.md) | Pinned public web transport | Accepted |
| [0028](0028-runtime-qualified-core-ci.md) | Runtime-qualified complete Core tests and shell compilation | Accepted |

| [0029](0029-native-shortcuts-with-stable-local-signing.md) | Native Shortcuts through public URLs with stable local signing | Accepted; supersedes 0023 for local builds |
| [0030](0030-isolated-deadline-test-resources.md) | Isolated timing-test resources without changed deadlines | Accepted |
