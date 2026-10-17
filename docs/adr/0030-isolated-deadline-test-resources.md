# ADR 0030: isolate deadline-test resources without changing their contracts

Status: Accepted

Date: 2026-10-17

## Observed failure

Hosted delivery run 39006928959 compiled the complete shell and capture driver
and passed documentation, but the 1,555-test parallel Core run failed timing
fixtures. The first-token test observed a headers timeout before its headers
callback ran. DNS expired before the test consumer issued cancellation. The
500 ms process deadline killed a Python fixture before its child/termination
receipt was observable. Many unrelated tests resumed after 8–15 seconds.
These errors describe the actual scheduling observed; they do not establish a
production timeout defect or justify increasing timeouts to obtain green.

The deliberately saturating process-deadline test shared the same run with
unrelated 300 ms stream deadlines. Its load fixture also had a concrete cleanup
bug: `finish()` called `start()` even if setup failed before load was requested,
starting three seconds of CPU work during failure cleanup. Initialization
blocked global workers and waited synchronously from a cooperative test task.
That cleanup is corrected and causally regression-tested separately.

Swift Testing runs tests in parallel by default. Serializing one suite does not
fence it from unrelated suites; the supported global `--no-parallel` option
controls the runner. See the upstream
[parallelization trait contract](https://github.com/swiftlang/swift-testing/blob/main/Sources/Testing/Traits/ParallelizationTrait.swift)
and [Swift Testing overview](https://github.com/swiftlang/swift-testing).

## Decision

The full `Scripts/test` plan, including `--core-only`, has two disjoint phases:

1. Run regular behavioral tests in parallel, reserving the three named timed OS
   source groups for phase two.
2. Run every test selected by `OmniVoiceBatchTTSAdapterTests`,
   `ModelStreamDecodingTests` and `EviePublicWebTests` with explicit
   `--no-parallel`, reusing the same build. Swift Testing also matches source-file
   IDs; nested/adjacent suites in those files are included. The measured phase
   selected 55 tests in six runtime suites.

Every test belongs to exactly one phase. Failure in either fails the command;
there is no automatic retry, removed assertion, larger deadline or omitted test.
The process stress test still creates its finite concurrent CPU load internally,
and the network tests still exercise the real client watchdogs and cancellation.
The runner controls interference between unrelated tests, not concurrency inside
production code or the behavior being tested. Existing explicit selection or
parallelism arguments are forwarded directly to SwiftPM for focused diagnosis.
A requested aggregate xUnit/coverage report uses one serial invocation, so a
second export cannot overwrite the first phase. Explicit selection or
parallelism still takes precedence over that reporting default.

The production executable is unchanged by these fixture/runner corrections.
Installed native, visual, context and resource evidence keeps its original
executable identity. New full-plan and hosted results must be recorded before
this change is described as qualified.

## Alternatives

- Increase the 300/500 ms or two-second assertions, add retries, or accept a
  different error: would weaken the contracts and hide the observed ordering.
- Serialize all unit tests: needlessly removes useful parallelism and slows the
  common deterministic coverage.
- Apply `.serialized` only to each timed suite: does not isolate peer suites.
- Change production timeout phases to accommodate fixture scheduling: no causal
  production defect has been demonstrated by this run.

## Validation

The causal negative control abandoned prepared load without calling start:
the old cleanup executed twenty workers for 3.021 seconds and failed the zero-work
assertion. The corrected fixture finished every worker with zero CPU-work starts
in 0.006 seconds. All ten TTS tests passed in 2.795 seconds with the same
500 ms timeout, 50 ms grace and less-than-two-second process-lifetime assertion.

The actual full-package plan passed 1,501 tests in phase one (6.421 seconds,
one intentional known Mail timeout fixture) and 55 in phase two (10.662 seconds):
1,556 total. Comparing every named-test start with the prior complete run found
all 1,536 previous named tests once and only the one new abandonment regression.
The count includes parameterized cases beyond those names. Discovery listed
1,537 function IDs; filtered `--list-tests` is not supported by this SwiftPM, so
no filtered-discovery ID proof is claimed. The identical complementary predicate
and actual invocation counts establish the partition at this checkpoint.

Command-boundary checks also verified both package layouts, phase-one failure
propagation, four selection/parallelism overrides and four aggregate-report
options, without running a compiler or test in those checks. The hosted gate is
recorded separately in [PROJECT_STATUS](../PROJECT_STATUS.md) and the
[delivery ledger](../implementation/EVIE_RESEARCH_DELIVERY.md). A local pass does
not replace the required fresh hosted run.
