# Native interface and interaction model

Status: VS-003 identity, window control, and the animated mark are source
implemented; target interaction acceptance is `QA-006`. CLUI CC is a UX reference,
not a runtime dependency.

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
- its backend launches and resumes external coding sessions and consumes
  product-specific NDJSON/hooks;
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

VS-002 opens the field at shell launch, uses `Option-Space` as its primary
open/hide shortcut, submits with `Return`, closes with `Escape`, and exposes stream
cancellation in the capsule. After completion, the answer card stays visible and a
new focused field returns for a follow-up. `Option-Shift-Space` remains a temporary
secondary text shortcut until the voice phase. Shortcuts are fixed in source for
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

VS-002 implements the first deliberately opened subset as two native windows:

- History lists local sessions, renders only their visible messages, resumes a
  session, starts a new one, and confirms deletion;
- Settings edits non-secret Gemma sampling/response limits and honestly labels
  voice, RAG, and tools as unavailable.

Pinned artifacts, workflow/permission/resource management, health, semantic
memory, and compact active-task tabs remain future `UI-007`/`UI-012` work. The
history window does not change the transient overlay into the default chat UI.

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

## Evie's mark

The logo is a key drawn in ASCII. It is rendered into a `Canvas` with explicitly
square cells rather than stacked `Text` rows, because a monospaced glyph cell is
about 1.9 times taller than it is wide and would stretch the drawing. Three grid
densities exist and are chosen by rendered size: 5×5 below 44 points, 7×7 below
56, 9×9 above. A 9×9 grid inside a 28-point badge resolves to a 3.4-point font and
is illegible, so density follows size rather than preference.

The mark is also the voice button. Clicking it, holding push-to-talk, and saying
the wake phrase all enter through one activation path, so the three routes cannot
drift apart.

Motion is deliberately two layers:

- a `rotation3DEffect` tilt animated by Core Animation, running whenever the
  overlay is on screen, at effectively no cost because the render server
  interpolates the transform without re-running the view body;
- a shading sweep that re-chooses each cell's character from the ramp
  `" .:-=+*#%@"` every frame, which only runs while Evie is listening, speaking,
  transcribing, thinking, or using a tool.

An overlay that is hidden or occluded has no timeline in its view tree at all.
Ordering the window out is not sufficient — see `docs/MACOS_RUNTIME.md` for the
measurement.

### Voice colours

| Role | Light | Dark |
|---|---|---|
| Your voice going in | `#0D7770` | `#17CFC2` |
| Evie's voice coming out | `#7149E9` | `#9577EE` |

These replaced `.mint` and `.pink`, which were chosen by eye and failed in light
mode: `.mint` resolves to 1.82:1 against the HUD surface, below the 3:1 that WCAG
requires for a graphical object. The replacements clear 4.5:1 in both appearances
and resolve per appearance through `NSColor(name:dynamicProvider:)`.

Colour is not the only channel, because teal and violet both drift towards blue
under common colour-vision differences. Direction is encoded geometrically as
well: incoming audio grows **inward** with 44 thin bars, outgoing audio grows
**outward** with 22 thick ones.

## Window control

The overlay is dragged by a grip at its top edge, which hands the mouse to
AppKit's own `performDrag(with:)` so multi-display travel behaves like a normal
titlebar without making the panel key. Thin handles on both edges change the width
around the window's own centre. A reset control appears beside the grip only once
the placement differs from the default.

Placement is saved to `preferences.json` and re-validated at launch: a saved
position is reused only when at least 160×48 points of it land on a connected
display, so unplugging a monitor returns Evie to the anchored default rather than
opening her off screen.

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
   the temporary TurboFieldfare adapter; backend smoke passed and manual target UI
   acceptance remains pending.**
4. Local microphone metering and push-to-talk. **Not started.**
5. Real supervisor IPC.
6. Partial transcript, cancellation, and TTS output metering.
7. Optional wake word.
8. Optional control center/history.
