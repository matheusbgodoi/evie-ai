# ADR 0028: qualify behavioral CI against working system runtimes

Status: Accepted

Date: 2026-10-17

## Context and measured boundary

EvieCore supports macOS 26; EvieShell also uses SDK 27 APIs. The hosted
`xcode-27` image runs macOS 27.0.1 (26A434), Xcode 27.0 and Swift 6.4.
Accurate Vision OCR failed there even with a supported CPU explicitly assigned.
The same request and assertions passed on the target M5 with macOS 27.2.
Changing API generations or silencing failures would not establish correctness.

A standalone synthetic Portuguese image compared six public routes in separate
processes: modern CPU, VN revision 3 CPU/automatic, VN revision 2 CPU, and VN
revisions 3/2 with the deprecated global CPU flag. The latter warning was kept
visible in the diagnostic; no deprecated flag entered production.
[The matrix run](https://github.com/matheusbgodoi/evie-ai/actions/runs/39003345095)
measured every route on both hosted images:

- `macos-26`: macOS 26.6.2, Xcode 26.6. All six routes recognized three lines,
  all five target strings (including accents/currency), minimum confidence 1.
  Modern CPU took 1.772 seconds.
- `xcode-27`: all six failed. Modern CPU returned
  `e5rt_e5_compiler_compile`/11; the VN routes returned a nil Objective-C error.
  Fresh processes and the global CPU flag did not change the outcome.

The diagnostic's successful job status means its reporting command completed;
its JSON contains failed OCR routes on 27.0.1. It is not an OCR pass or proof that
all macOS 27 systems are affected. This is qualification of these measured images.

## Decision

Run **every EvieCore test** on the supported, qualified `macos-26` runtime,
including all real OCR assertions with automatic and forced CPU policies. Build
the complete shell with warnings as errors on `xcode-27`. Before release, also
run the default full-package suite and signed-app diagnostics on the real target
Mac with macOS 27.2. Keep the documentation job unchanged.

`Scripts/test --core-only` generates a minimal package in the ignored build
area, containing the existing EvieCore and EvieCoreTests targets. Sources,
tests and repository-relative script/config/eval fixtures are links to the
current tree; there is no second source copy or reduced test list. `swift test`
produces and executes the actual test bundle in `.build/core-test-products`.
The normal `Scripts/test` remains the full-package path. Both paths preserve
warnings-as-errors, Swift Testing plugin/rpaths and caller arguments.

Standalone settings, research-guard and local-launcher harnesses can select
that same module/object directory using an absolute `EVIE_CORE_BUILD_DIR`.
Their default `.build/debug` behavior is unchanged. CI runs the settings and
research-guard harnesses against the newly built isolated Core.

## Validation and consequences

The first local isolated full run passed **1,550 tests in 146 suites in
26.530 seconds**, with one intentional known timeout-injection issue. Real
script fixtures resolved through the links. Settings persistence/responsive
Keychain and the research clipboard guard also passed against the isolated
module. The subsequent [hosted complete CI run](https://github.com/matheusbgodoi/evie-ai/actions/runs/39003951363)
on public candidate `1b8b70a` passed **all 1,550 tests / 146 suites in 12.009
seconds** on macOS 26, with the one intentional known timeout-injection case.
Its settings boundary and 68-chord research guard passed; the full Shell built
with warnings as errors on Xcode 27 in 40.80 seconds, and documentation passed.
The standalone OCR matrix and complete behavioral job are distinct evidence.

This keeps all behavioral assertions and system integrations. It neither marks
OCR failures as known issues nor filters tests by machine identity. The public
accurate CPU alternative remains useful on working runtimes; no legacy engine
or fast-recognition downgrade was adopted to turn CI green. Additional runtime
images can be qualified using the retained manual diagnostic workflow.

## Alternatives rejected

- Remove or relax OCR/confidence/Portuguese assertions: loses actual behavior.
- Claim CPU assignment fixes the VM: directly contradicted by six-route evidence.
- Adopt legacy/fast recognition without matching evidence: changes product
  quality without a demonstrated benefit.
- Install another giant SDK on CI or expose the owner's Mac as a public
  self-hosted runner: unnecessary for the measured compatibility contract.
