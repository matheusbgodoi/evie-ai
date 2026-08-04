# ADR 0003: Native macOS overlay inspired by CLUI CC

- Status: Accepted for planning; Phase 2 prototype required
- Date: 2026-08-04

## Context

CLUI CC demonstrates a desirable transparent global overlay, compact command pill,
task states, and permission cards. Its Electron runtime and backend are tightly
coupled to Claude Code and do not provide the desired wake-word/TTS interaction.

## Decision

Adopt the interaction grammar but implement Evie's shell in SwiftUI/AppKit using an
`NSPanel`, native material/vibrancy, menu-bar status, AVAudioEngine metering, and a
backend-neutral event protocol.

## Consequences

- Better standby, permissions, audio ownership, and macOS integration.
- Requires original UI engineering rather than a quick CLUI fork.
- CLUI MIT code may inform implementation only with correct attribution if copied.
