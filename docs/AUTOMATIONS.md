# Visual automation design

Status: proposed.

## Role of Node-RED

Node-RED is the deterministic event and workflow layer, not Evie's personality or
general reasoning engine. It can run natively through Node.js and expose its visual
editor only on localhost.

Suitable triggers include:

- scheduled times, intervals, and cron-like events;
- inbound HTTP webhooks;
- email or calendar events through supported adapters/polling;
- WhatsApp events delivered by the Hermes gateway/bridge;
- filesystem events inside approved roots;
- MQTT/Home Assistant events;
- network, power, or Mac state events;
- trusted location events from a phone shortcut, companion, or Home Assistant.

Suitable actions include:

- retrieve and transform data;
- invoke a bounded Evie semantic operation;
- produce a draft or notification;
- write to an approved staging location;
- request user approval;
- call an explicitly configured external connector.

## AI-generated workflows

Evie may generate workflows, but cannot silently activate them.

```text
natural-language request
  -> clarify trigger, inputs, actions, failures, and approval points
  -> generate canonical flow JSON
  -> static validation and forbidden-node checks
  -> create/import disabled
  -> render/open visual preview and human-readable explanation
  -> user approval
  -> activate exact reviewed revision
  -> audit and monitor
```

Any material revision returns to disabled/draft state unless a narrow, versioned
policy explicitly permits the change.

## Narrow adapter

Do not hand the model a generic Node-RED admin token or unrestricted HTTP tool.
Implement a local broker exposing operations such as:

- `workflow_list`
- `workflow_get`
- `workflow_validate_draft`
- `workflow_create_disabled`
- `workflow_diff`
- `workflow_request_enable`
- `workflow_disable`
- `workflow_run_approved`
- `workflow_get_run_status`

The broker enforces allowed node types, secret references, network destinations,
filesystem roots, revision matching, and approval records.

## Workflow metadata

Every versioned flow includes or is accompanied by:

- stable identifier and display name;
- owner and purpose;
- trigger and timezone;
- inputs, outputs, and data sensitivity;
- external destinations;
- required credentials by symbolic reference only;
- LLM/model operations and expected cost/resource use;
- approval points;
- retry, timeout, and duplicate/idempotency behavior;
- rollback/disable instructions;
- last tested and last reviewed date.

## Initial high-return workflows

1. **Morning briefing:** schedule -> read-only calendar/email -> summarize -> show
   card, optionally speak or send to the dedicated WhatsApp chat.
2. **Meeting preparation:** upcoming-event trigger -> retrieve related messages and
   documents -> prepare sourced brief.
3. **Voice capture:** shortcut/voice -> classify as note/task/event -> show proposed
   destination -> confirm.
4. **Downloads staging:** file event -> classify and propose names/folders -> show
   move manifest -> confirm into approved roots.
5. **Weekly review:** schedule -> summarize completed tasks, unread priorities,
   calendar, and pinned artifacts.

These are selected because they are frequent, measurable, and can begin read-only
or proposal-only.

## Location triggers

Location is an external signal. Candidate sources:

- Home Assistant Companion and MQTT/webhook;
- iPhone Shortcut posting a signed local/remote event;
- a future companion app;
- an explicitly authorized existing location provider.

Location data should be reduced to the coarsest useful state such as `home`,
`office`, `away`, or `commuting`, retained briefly, and never committed.

## Reliability rules

- Use idempotency keys for outbound or repeatable actions.
- Persist a run state before and after external side effects.
- Reconcile timeouts instead of assuming failure.
- Rate-limit message and email triggers.
- Detect loops between WhatsApp/email/automation responses.
- Fail closed when approval or credential state is unavailable.
- Provide a one-click disable/kill switch for every flow.
