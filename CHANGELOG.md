# Changelog

All notable changes to Evie are documented here. Dates use `YYYY-MM-DD`.

## [Unreleased]

### Added

- Initial feasibility, architecture, security, UI, voice, RAG, automation, model,
  resource, roadmap, handoff, and evaluation documentation.
- Repository-wide agent continuity and documentation contract.
- Sanitized configuration examples and defensive ignore rules.
- Initial ADRs for a documentation-first phase, the primary model strategy, and
  specialist workers.
- Swift 6 package with the backend-neutral `EvieCore` interaction model and state
  reducer.
- Loopback-only TurboFieldfare Chat Completions client with SSE text/usage
  streaming, typed failures, bounded HTTP error reads, and cancellation.
- Native macOS menu-bar shell, floating `NSPanel`, global summon/quick-text
  shortcuts, and one cancellable quick-text-to-Gemma interaction.
- Original native-glass capsule, data-driven waveform component, status states,
  expandable artifact/error cards, and accessibility fallbacks inspired by CLUI
  CC's interaction grammar.
- Complete implementation task ledger, VS-001 build/run/acceptance guide, and ADR
  0006 for the temporary direct inference seam.

### Changed

- Project status advances from planning-only to source-implemented VS-001 while
  keeping all target-hardware, inference, latency, memory, and energy claims
  explicitly unvalidated.

## [0.0.1] - 2026-08-04

### Added

- Private planning repository bootstrap for Evie AI.
