# ADR 0021: Explicit brain changes apply to the current conversation

Status: Accepted, 2026-10-16. Amends ADR 0014.

An explicit model choice previously changed only new conversations, so the menu
could show PC selected while the next reply still came from the Mac. The compact
brain popover now saves the preference first and releases only the active
conversation's pin. Its next reply resolves the chosen PC, Mac or automatic order.
Existing answer labels and other conversations' pins retain their original model.
Busy turns reject switching. Failed preference writes retain the previous choice.
Connection probes cannot replace active response status. Reasoning is saved per
profile through the existing read/merge configuration store.

Preserving immutable pins was rejected because it contradicted the visible user
choice. Migrating all conversations was rejected because it would change unrelated
threads. Runtime failover continues to obey ADR 0014.

Validation: resolver regression initially failed two assertions; after correction,
20 focused brain tests passed. Persistence/partial older preference files and
custom display-name round trips have behavioral tests. Final delivery evidence is
in the delivery ledger and WORKLOG.
