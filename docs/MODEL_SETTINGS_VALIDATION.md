# Model settings persistence regression

`Scripts/model-settings-validation` compiles the production
`ModelSettingsViewModel.swift` together with a synthetic executable fixture and
links the existing debug `EvieCore` build. Run `Scripts/test` first, then this
script. The script does not invoke a second SwiftPM build and can be used after
the package build without competing for its build directory.

The fixture uses a real temporary configuration file and the production loader
and atomic store. It uses an in-memory `EvieKeychainItems` implementation and a
credential provider that suspends invalidation at a controlled `await`. It does
not read or write the login Keychain, start a model, send network traffic, or
modify the owner's configuration. This validates the view-model/persistence
boundary; it does not claim to exercise a macOS Keychain permission dialog.

The regression first failed on the old implementation because saving a key
replaced a concurrently saved model with the stale draft. The corrected flow
persists only the captured endpoint and its host-bound credential reference onto
the freshly loaded profile. Environment-managed endpoints stay out of the file.

The executable verifies that another writer's saved model, timeout, and label
survive; unsaved changes to both profiles and edits made while the key save is
awaiting survive field by field; untouched fields adopt the latest saved values;
unsaved preferred profile, fallback, and editing selection survive; and a second
key save cannot consume a newly typed key while the first is pending. An endpoint
typed during that await remains a draft: the original key is bound only to the
original captured host. No secret appears in the configuration JSON.

A second case replaces the temporary file with a newer unsupported schema while
the key save is pending. The configuration remains byte-for-byte unchanged, the
typed draft survives, the busy state clears, and the UI explicitly reports that
the key reached the Keychain boundary but its endpoint could not be saved. A
credential left after this partial failure is not adopted as a successful config
save.

`EvieProfileDraftRebaseTests` exercises the field merge separately, including
unfinished invalid input, sampling switches, reasoning, and custom labels. These
tests complement the real view-model/JSON boundary rather than replacing it.

## Keychain attributes cannot block Settings — 2026-10-17

An attributes-only Keychain lookup can wait behind another legitimate Keychain
interaction. Calling it synchronously from settings initialization or the
permission guide's row prevented the UI from rendering while that wait lasted.
The standalone regression now supplies a `contains` implementation that blocks
for 250 ms, released from a non-main queue. With the previous production view
model it failed specifically with `main actor stalled in synchronous Keychain
status during settings initialization`.

The corrected production path uses `EvieModelKeyStatusRefresh`: one serial
utility queue, one active snapshot per consumer and only the newest pending
snapshot. It does not add polling, retries, a recurring timer, an unlock bypass,
or secret reads. A first unresolved reference is shown as checking. Completed
attributes are cached; a generation and exact-reference check prevent an old
credential's result from being applied after the profile changes. Explicit
refreshes can update an existing cache, while ordinary rendering of an unchanged
reference does not schedule another OS query.

The settings model and the PC-key guide row use that same bounded worker.
Completion callbacks update their cached UI state on MainActor. The guide's
existing explicit/activation refresh requests new attributes; rendering its
cached rows does not synchronously query Security.framework. An outstanding
macOS password/authorization interaction still requires the user's own response.

Verification executed after the change:

- `Scripts/test --core-only --filter
  'EvieModelKeyStatusRefresh|EviePermissionGuideBrain|EvieModelKeys|EvieProfileDraftRebase'`:
  **38 tests / 4 suites passed in 0.046 s**, after an 11.22 s core-test build
  with warnings treated as errors. Cases cover a blocked worker, 100 coalesced
  refreshes, stale-reference rejection, explicit cache updates, asynchronous
  guide notification and zero secret reads for status.
- `Scripts/model-settings-validation`: the real production view model initializes
  and accepts 50 refresh requests within the 100 ms responsiveness bound while
  the 250 ms attributes wait is still active, permits only one active query, and
  then receives the saved status. Both existing JSON/draft persistence cases
  also pass unchanged. No personal Keychain or configuration is touched.

This demonstrates the view-model/main-actor boundary with a controlled blocking
Keychain implementation. It does not claim that the user authorized a real
Keychain prompt or substitute for rendering the installed app after rebuilding.
