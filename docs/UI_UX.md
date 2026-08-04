# Native interface and interaction model

Status: VS-001 visual/native shell source implemented; target interaction acceptance
pending. CLUI CC is a UX reference, not a runtime dependency.

## Product stance

Evie is not primarily a chat application. The default interface is a transient,
always-available macOS HUD for voice, quick text, status, artifacts, and approvals.
Conversation history exists, but it is opened deliberately rather than occupying a
permanent window.

## CLUI CC research

The reference project is the original
[Clui CC by Lucas Couto](https://github.com/lcoutodemos/clui-cc), licensed MIT. A
later [Clui fork/site](https://github.com/Youssef2430/clui) should not be confused
with the original when attributing design or code.

Useful interaction patterns:

- transparent, frameless, always-on-top overlay across Spaces;
- no normal Dock presence;
- `Option-Space` show/hide shortcut with a fallback;
- compact bottom input pill that expands upward;
- multiple task tabs with visible idle/running/completed/permission/error states;
- explicit permission cards with masked tool arguments;
- transparent regions that do not intercept clicks;
- attachment/screenshot/skill controls revealed progressively.

Implementation facts that limit direct reuse:

- Clui CC is Electron/React/TypeScript rather than native macOS;
- its backend launches and resumes Claude Code sessions and consumes Claude-specific
  NDJSON/hooks;
- its voice interaction is input/transcription only, without wake word, output TTS,
  or reactive waveform;
- its named glass surfaces are visually opaque CSS panels rather than native
  vibrancy materials.

Evie should reuse the visual grammar, not fork the product architecture.

## Native shell

Preferred stack:

- SwiftUI for state-driven content;
- AppKit `NSPanel` for a nonstandard floating overlay;
- `NSVisualEffectView` or supported SwiftUI materials for real macOS glass/vibrancy;
- `MenuBarExtra` or an AppKit status item for persistent settings/status;
- `AVAudioEngine` metering for live input/output visualization;
- local XPC or Unix-socket events from the supervisor.

The overlay should be capable of remaining visible on relevant Spaces, avoiding
focus theft, and allowing click-through outside its actual surfaces. Exact window
levels and activation behavior require a Phase 2 prototype.

### VS-001 implementation

The current development shell uses:

- an accessory-policy application and AppKit status item, with no ordinary chat
  window or Dock-oriented main window;
- a transparent, borderless, nonactivating floating `NSPanel` placed at the bottom
  center of the display under the pointer;
- a native `NSVisualEffectView` bridge with opaque accessibility fallback for
  Reduce Transparency;
- a compact capsule, honest status glyphs, a data-driven waveform, and expandable
  cards that stack upward;
- dynamic panel height to reduce the transparent region that can intercept input;
- Carbon global hotkeys, avoiding a broad keyboard event monitor;
- SwiftUI accessibility labels, Reduce Motion behavior, text selection, sensitive
  card previews, and keyboard-driven quick entry.

The implementation is visually original and reuses no CLUI CC Electron/React code.
It adapts only the bottom-anchored transient interaction grammar.

Target testing is still required for focus restoration, click-through behavior,
shortcut conflicts, full-screen apps, Spaces, multiple displays, VoiceOver order,
and all accessibility appearances. A successful source build is not evidence that
those behaviors are operational.

## Interaction surfaces

### Voice pill

Summoned by the wake phrase or configurable shortcut. It shows only the information
needed for the current state:

- dormant/ready mark;
- live microphone waveform and optional partial transcript;
- transcribing indicator;
- thinking/tool status in plain language;
- output waveform and optional caption while speaking;
- cancel/mute control.

### Quick text pill

A separate configurable shortcut opens a single-line or short multiline command
field. It submits without opening history. Representative defaults for prototyping:

- `Option-Space`: show or dismiss the passive overlay in VS-001; it is reserved for
  push-to-talk after the voice phase;
- `Option-Shift-Space`: quick text;
- `Escape`: cancel or dismiss;
- `Command-Enter`: approve/commit the selected action;
- a separate shortcut: full history/control center.

All shortcuts remain configurable and must be tested against Spotlight, input
methods, editors, and accessibility tools.

VS-001 currently submits quick text with `Return`, closes that entry with `Escape`,
and exposes stream cancellation in the capsule. Shortcuts are fixed in source for
the prototype; persistence and conflict preferences belong to `UI-009`.

### Artifact cards

Results expand above or near the pill as transient glass cards rather than chat
bubbles. Types include:

- short answer or researched answer;
- email draft;
- proposed calendar event;
- file/search result;
- RAG source collection;
- image observation;
- workflow preview;
- permission request;
- error/recovery explanation.

Cards support dismiss, pin, expand, open in source application, copy, and explicit
approve/deny when relevant. Multiple active tasks may appear as compact tabs or a
stack with unread and permission states.

VS-001 implements expand, dismiss, text selection, and copy for text/error cards.
Pinning, source-app opening, task tabs, sensitive integration previews, and approval
actions remain later tasks.

### Optional control center

Opened deliberately for:

- full session history;
- pinned artifacts;
- workflow catalog and run history;
- memory and indexed-collection management;
- permissions and account connections;
- model/voice/resource settings;
- logs and health state.

It is not required for ordinary voice use.

## State machine

```text
hidden
  ├─ shortcut/wake ─> listening ─> transcribing ─> thinking/tool use
  │                                         │              │
  │                                         └─ error <─────┘
  │                                                        │
  └<─ dismiss <─ result card <─ speaking/text streaming <──┘
```

Additional states include awaiting permission, cancelled, worker loading, offline
integration, and system memory-pressure fallback. The UI must never display
"listening" after microphone capture stops or "done" before a commit action is
confirmed by its target.

## Visual language

- restrained native glass, not maximum blur everywhere;
- readable contrast in light/dark mode and Reduce Transparency;
- a distinctive Evie color/shape for listening and a different one for speaking;
- motion that communicates state, with Reduce Motion support;
- microphone and outbound-action indicators that cannot be hidden by decorative
  animation;
- no simulated certainty: uncertainty and partial failure remain visible.

## Accessibility and privacy

- complete keyboard navigation;
- VoiceOver labels and ordered focus;
- captions available for every spoken response;
- visible microphone state and immediate hard stop;
- optional sound cue before and after capture;
- wake-word disable/mute available from the menu bar;
- no raw audio retention by default;
- cards avoid displaying private content on a shared screen until expanded.

## Prototype sequence

1. Static overlay with real materials and card layout. **Source implemented.**
2. Global quick-text shortcut and no-focus-steal behavior. **Source implemented;
   target behavior pending `QA-001`.**
3. Backend-neutral state machine and real local text stream. **Implemented through
   the temporary TurboFieldfare adapter; target inference pending.**
4. Local microphone metering and push-to-talk. **Not started.**
5. Real supervisor IPC.
6. Partial transcript, cancellation, and TTS output metering.
7. Optional wake word.
8. Optional control center/history.
