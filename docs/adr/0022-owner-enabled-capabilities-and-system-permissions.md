# ADR 0022: Owner-enabled capabilities and real system permissions

Status: Accepted, 2026-10-16. Amends ADRs 0018 and 0019 defaults.

The owner explicitly requested that existing capabilities be enabled by default.
New preferences therefore enable web, Mail/Calendar, agent mode, file changes,
file auto-approval, requested document saving, wake listening, push-to-talk and
speech output, including typed answers and call mode. Existing explicitly saved
false values remain false. The installation migration enables these capabilities
at the owner's request after a local backup.

Enabling a capability does not invent a macOS permission or an agent session.
TCC grants use system requests and report the actual result. Agent consent and
raw-audio retention remain false until their own explicit decisions. Research
requires expiring consent. Disabling agent mode revokes an active normal session
and a research control session. Outbound Mail/calendar/destructive approvals are
retained. Wake listening never authorizes computer control.

Keeping every capability off contradicted the user's chosen product behavior.
Changing the TCC database or bypassing approvals was rejected: those actions do
not grant legitimate authority and would misreport what the OS allows.

Missing-key preference migrations share EviePreferences defaults; regression
tests cover old documents, explicit false values and persisted brain selection.
No always-running model worker is introduced. Resource evidence measures wake
listening separately rather than claiming that on-device speech costs no energy.
