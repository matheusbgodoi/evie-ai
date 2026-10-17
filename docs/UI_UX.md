# Native interface and interaction model

Current review: 2026-10-17. Evie v2 has a native overlay, configurable shortcuts,
voice, history, a settings sidebar, screen capture and agent sessions. The brain
control is a 30-point button with an anchored popover. New floating surfaces use
native Liquid Glass; reading surfaces retain a thicker material and an opaque
accessibility fallback. CLUI CC and Siri are design references, without runtime
dependencies on either implementation. See [Apple visual identity](APPLE_VISUAL_IDENTITY.md)
and [research validation](RESEARCH_VALIDATION.md) for measured checks and limits.

## Product stance

Evie is not primarily a chat application. The default interface is a transient,
always-available macOS HUD for voice, quick text, status, artifacts, and approvals.
Conversation history exists, but it is opened deliberately rather than occupying a
permanent window.

## Current voice and permission state

Wake listening is enabled by default at the owner's explicit request (ADR 0022).
While armed, it captures microphone input for local recognition and retains the
system indicator; a quiet HUD does not mean the microphone is closed. Its
control, push-to-talk, spoken replies and call mode remain separate settings.
Emergency stop and research isolation disarm the listener. Five-call owner
calibration remains a user recording step; a synthetic speech diagnostic cannot
complete it.

The installed-candidate voice check now selects public **Luciana Aprimorada**:
10 usable Brazilian voices, one enhanced, verified with actual synthesis and
recognition. That improves the available voice catalog without claiming access
to Siri's private voices. Permission indicators remain based on real OS state:
the inspected Automation page already allowed Calendar, while Mail still needed
its own request. These are checkpoint observations; final release and grant
results belong in [PROJECT_STATUS](PROJECT_STATUS.md), with detailed voice
[evidence](NATIVE_VOICE.md).

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
field. It submits without opening history. Current defaults, configurable in
Configurações → Atalhos:

- `Option-Space`: show or dismiss the overlay, ready to type;
- `Option-Shift-Space`: quick text;
- `Option-V`: push-to-talk while held;
- `Option-Shift-H`: history;
- `Option-Shift-O`: attach a screen capture to the next question;
- `Control-Option-Shift-P`: open research consent, or stop an armed session;
- `Control-Option-Shift-K`: run one task inside an armed research session;
- `Option-Shift-Escape`: stop all work. Sensitive confirmations require a real
  hand click and are never approved by a keyboard shortcut.

All shortcuts remain configurable and must be tested against Spotlight, input
methods, editors, and accessibility tools.

The original VS-002 prototype opened the field at shell launch, used `Option-Space` as its primary
open/hide shortcut, submits with `Return`, closes with `Escape`, and exposes stream
cancellation in the capsule. After completion, the answer card stays visible and a
new focused field returns for a follow-up. `Option-Shift-Space` remains a temporary
secondary text shortcut until the voice phase. Shortcuts are fixed in source for
that historical prototype. The current shortcut settings persist overrides,
show conflicts, allow disabling individual bindings and retain menu access.

### The brain chip (2026-10-16)

The input bar and voice capsule carry a fixed-width circular brain button, left
of the paperclip, preserving the writing area. Its small state dot is
filled green ready, a yellow ring cold (the PC's model unloaded, or the Mac
brain asleep), a breathing yellow dot while the Mac brain wakes, red with a
cross unreachable (no key, refused, out), a gray ring not yet probed. The
tooltip and VoiceOver say the model and state in words (`EvieBrainChip`). While
agent mode is enabled, the button gains an amber outline; no model name or
"Agente" text occupies the input field.

Clicking opens an anchored popover with the model name, connection state and
connection-test button, Automático / Sempre o PC / Sempre o Mac, inline reasoning
level, agent-mode and web-search toggles. It also shows the selected profile's
context and output limits, last-send token usage with its source, and automatic
compaction state. Estimates are identified as estimates. Model and reasoning
controls are disabled while a task or compaction is running. Changing model explicitly clears this
conversation's old pin, so the next answer follows the choice; history is
preserved. The app-session choice goes through `EvieBrainResolver.choose(_:)`.
Enabling agent mode permits requested sessions; it does not continuously act.

The icon-only brain button has the spoken label “Cérebro e controles da Evie”
and stable identifier `evie-brain-controls`. Each model option supplies its full
spoken title, selection trait and `evie-brain-choice-<choice>` identifier. The
installed UI check must resolve these controls semantically rather than by
their position; an older candidate exposed only the SF Symbol identifier and
unnamed model buttons. This accessibility correction requires the rebuilt
candidate's AX check before it is reported as verified.

The popover keeps a 330-point viewport with 18-point readable insets. Its
content width is constrained separately from the scroll view: the native
reasoning picker uses the small control size, and explanatory text wraps
vertically. An installed-candidate capture exposed clipped left/right content
with the earlier unconstrained stack; that capture is failure evidence, not
an approved layout. The corrected layout must be checked in a visible owned
window because offscreen bitmap caching does not capture these native controls
reliably.

On 2026-10-17 a standalone Swift 6 build using the real `BrainControlsView`
and synthetic model data passed warnings-as-errors. Its visible owned-window
[layout capture](images/apple-visual/brain-controls-context-fixed.png) shows
normal and compacting controls with complete insets, wrapped captions and
unclipped token limits. This checks layout; the installed popover and AX labels
are checked separately after packaging.

Every answer card names its model and place beside "RESPOSTA", quietly
("Qwen 3.8 · no seu PC"); a card restored from history does not know it and
shows nothing.

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

**Settings since 2026-10-16** is a window in the style of System Settings: a
`NavigationSplitView` whose sidebar lists `EvieSettingsSection` in this order,
each on a coloured tile — Geral (what is in use, with a way to each, and
updates), Cérebro, Tela e modo agente (the "Deixar a Evie controlar o Mac"
switch first and large, one paragraph on what it does and how to stop it, the
Screen Recording / Accessibility / input-event rows of the guide, the
screen-look shortcut), Arquivos e pastas (the folders; the document tools add a
"Documentos" segment through `FilesAndFoldersSettingsView`'s `documents`
builder), Voz, Atalhos, O que ela sabe (memory, skills, Mail and Calendar,
schedules), Aparência, Permissões (the first-run guide) and Avançado
(diagnostics). The section's name is the window title; the window is
resizable from 780 × 520 and opens at 860 × 640. Agent mode can also be turned
on and off from the brain chip's menu and from "Modo agente" in the menu bar.

To look at the chip, an answer card and Settings without launching the app,
`evie-shell --ui-snapshots <pasta>` draws them into windows that are never
shown, in light and dark, over models built from scratch in a temporary folder.
macOS 26's floating sidebar and every behind-window material are composited by
the window server, so they come out flat or missing there; the sidebar's list is
drawn alone as well for that reason.

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

The current HUD mark is a crisp sparkle symbol over an original violet glass
badge. The application icon is a separate original image packaged reproducibly
as ICNS. An ASCII key existed in an early prototype and remains historical;
it does not describe the current 30-point mark.

The mark is also the voice button. Clicking it, holding push-to-talk, and saying
the wake phrase all enter through one activation path, so the three routes cannot
drift apart.

The idle and completed mark does not animate. Active listening, speaking and
work use Core Animation and measured audio samples. Hover feedback respects
Reduce Motion. Glass surfaces do not add blur timers, shaders or nested animated
glass layers. No claim of zero energy is inferred from using Core Animation.

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
Evie's violet is also the screen presence colour while she looks at the screen,
so both come from one definition, `EviePalette.violet`.

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

### Looking at the screen (v2 S4)

- **Asking.** In words ("olha a tela", "o que tem na minha tela?", "nessa
  janela") or with ⌥⇧O, "Olhar a tela" (also in the menu bar). The shortcut
  opens the overlay, captures the screen under the pointer and says "Tela
  capturada. Pergunte o que quiser sobre ela."; the next question goes with it,
  and sending nothing asks "O que tem na minha tela?". Closing the overlay drops
  the capture.
- **While it happens.** "Olhando a tela…" while the glow comes up and the capture
  is taken (about 0.1 s, measured), then "Analisando a tela no PC… (~26 s)" or
  "Analisando a tela no Mac… (~5 s)" until the first word — the PC's image
  projector runs on its CPU. On a brain without vision, "Lendo a tela…" while the
  text is recognised instead.
- **Without the permission.** A card "A Evie precisa ver sua tela" with the path
  to Ajustes do Sistema › Privacidade e Segurança › Gravação de Tela e Áudio do
  Sistema, "reabra a Evie depois de permitir", a line saying the monthly macOS
  re-confirmation is normal, and "Abrir Ajustes". The macOS prompt itself is
  shown once.
- **Afterwards.** The question is saved with "📷 captura da tela" under it; the
  picture is not saved. A follow-up in the same conversation still sees the last
  capture.

### Controlling the Mac (v2 S5d)

- **Asking.** In his own words — "abre o Notas e escreve…", "clica em
  Salvar", "cola isso no Notas", "digita…" — typed, said with push-to-talk or
  after a click on the mark; or "Controlar o Mac…" in the menu bar, after which
  the next request is the goal ("Diga ou escreva o que fazer no Mac"). After
  the wake word or in a call Evie says she does not start a session that way.
  On the Mac brain: "Controlar o Mac precisa do PC…".
- **The session card.** Amber, "Controlar o Mac?", his goal quoted, the terms
  (15 minutes or 25 actions; Esc, ⌥⇧Esc, Parar or "para" stop; touching the
  mouse or keyboard pauses), Começar and Agora não. The first time it is the
  consent instead, and Começar reads "Entendi, começar".
- **Confirmations.** An amber card with the policy's question as its title, a
  thumbnail of the newest screen with amber corner brackets on the target, and
  Fazer / Pular. The buttons take a click only — no Tab, Space or Return
  reaches them — and the pill keeps showing what Evie is about to do.
- **Pausing and stopping.** Moving the mouse or pressing a key pauses: the
  pill turns gray with Continuar and Parar, and stops by itself after 60 s.
  Any stop leaves the overlay up with the end card.
- **The end card.** "O que eu fiz no Mac": how it ended in one line, then a
  numbered list ("1. Apertei “Nova Nota”.", "2. Você pulou: …", "3. Não fiz:
  …"). It is not saved; the conversation keeps the request and one line saying
  how the session ended.

### Screen presence rules

`ScreenPresenceMachine` in `EvieCore` enforces the indicator's promise in code and covers it with tests. Its behaviour is described in `docs/design/2026-10-16-evie-v2-design.md` § S6:

- No screenshot is taken before the indicator has been composited on screen — on the display being captured, and on every other display the phase covers. A late composite report from a replaced render, or panels rebuilt after a display change, never count.
- The seeing glow stays up for at least 700 ms.
- A click is posted only after its 250 ms dwell has run uninterrupted.
- Real input from the user pauses an agent session. Only Continuar resumes it, and a pause stops itself after 60 s. Ending a paused session any other way is a stop: the work is cancelled.
- The hold of one look never ends the next look or session.
- Stop cancels the work before any animation and does not wait out the seeing minimum.

### Screen presence visuals

Drawn by `Sources/EvieShell/ScreenPresence/` (S6-shell). Every state has its own
shape as well as its own colour:

| State | Edge | On the target | Pill |
|---|---|---|---|
| Seeing | violet glow, full strength, one 700 ms shutter sweep from top centre | — | dot · "Evie está vendo sua tela" |
| Observing | the same glow at 35%, static | violet corner brackets with a 6% fill, springing to each target | three travelling dots · "Evie está observando · passo N/25" |
| Acting | solid amber line | amber frame on the element, amber ghost cursor, a ripple on the press | dot with a ring · "Evie vai clicar em ‘Enviar’" |
| Typing | solid amber line | amber frame on the field and a "Digitando…" chip | amber dots · "Evie está digitando em Notas" |
| Paused | gray, half width | — | two bars · "Pausado — você assumiu", Continuar and Parar |

Violet is `#7149E9` / `#9577EE` (light / dark), with `#4F46E5` / `#818CF8` in the
halo. Amber is `#B45309` / `#FBBF24`, haloed in `#F59E0B`; text on an amber
button is dark in dark mode, where white on the bright amber fails contrast.
The pill sits 8 points under the menu bar on the display being worked on, and
moves to the bottom when the target comes within 24 points of it.

All motion is Core Animation, critically damped springs and the curves
`cubic-bezier(0.23, 1, 0.32, 1)` (entrances) and `cubic-bezier(0.77, 0, 0.175, 1)`
(the sweep). Every animation starts from the layer's on-screen value, so a new
target redirects the reticle or the cursor mid-flight. Exits are faster than
entrances. Reduce Motion keeps every state and replaces travel with fades: no
sweep, the reticle cross-fades, the cursor appears at the target, and the
ripple becomes one flash of the highlight. VoiceOver hears each state change.

`evie-shell --presence-demo` plays every state on the main display without an
agent; `--reduced-motion` shows the reduced variants and `--with-esc` takes the
Esc key as a real session does.

## Historical prototype sequence

This sequence records the original plan, before voice, wake word and history
were implemented. Its old phase statuses do not describe the current release;
current implementation and checks live in [PROJECT_STATUS](PROJECT_STATUS.md).

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
