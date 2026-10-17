# Evie: native glass and original identity

Implemented 2026-10-16 on Apple M5, macOS 27.2 (26B5086k), Xcode 27.1
(27A9275). The minimum app target remains macOS 26. This is an original Evie
interface built with public APIs; no Siri code, shaders, icons or image assets
are included.

## Design and implementation

`GlassSurface` now uses SwiftUI `glassEffect(.regular.tint(…))` on the floating
HUD controls, including quick entry, voice and command suggestions. The system
owns refraction and material adaptation. Answer cards retain a thicker native
popover material with a quiet background wash so desktop content does not
compete with paragraphs. This follows Apple's distinction between floating
controls and reading content. There is one effect per surface, no stacked
glass or animated blur.

Reduce Transparency **or** Increase Contrast selects a fully opaque system
background with a defined primary-color border. No translucent gradient is
placed over that fallback. Light and dark appearances resolve system colors.
The existing accessibility labels and text layout remain in their components.

Evie's existing two-sparkle identity gains a crystal-lit badge, a static sheen,
and the same adaptive violet used by voice output and screen presence. The
badge no longer breathes in ready, completed, error or approval states; it
animates only during actual work. Breathing still uses a compositor transform,
not a SwiftUI frame timer. Hover observes Reduce Motion. No new worker, timer,
shader, model, background service or runtime asset decoding loop was added.
This is a structural performance improvement, not a battery-life measurement.

The compact brain button and its anchored popover are documented separately in
the brain-control implementation. Agent and web availability do not by themselves
start screen capture, computer control or LLM inference. Wake listening is a
separate enabled-by-default capability at the owner's request: while armed it
uses the microphone and local recognition, with the macOS indicator and energy
cost. A static idle badge must not be interpreted as a closed microphone. See
[native voice](NATIVE_VOICE.md) for the actual listener and permission contract.

## Read-only Siri study

The question was whether native Siri UI technology could guide Evie's design.
The following bounded inspection was performed with REA and Ghidra 12.1.3;
original files were untouched and copies were analyzed under
`/tmp/evie-siri-visual-study/`.

| Artifact | SHA-256 | Observation |
| --- | --- | --- |
| `/System/Applications/Siri.app/Contents/MacOS/Siri` | `a75b9bd9f293bf1964e5ebc6135a051fab5b97cc2b8bdad32612953aa3c23259` | Universal arm64e/arm64e.x1 launcher. Ghidra found `/System/Library/CoreServices/Siri.app` at `0x1000007f8`. |
| `/System/Library/CoreServices/Siri.app/Contents/MacOS/Siri` | `f9298ccc6a42d526f01f4bcf6c32864d1d7947ff37d0ac02dc038068082aabdf` | Universal arm64e/arm64e.x1 application. Mach-O inspection reports 57 dependencies, including private SiriUI, SiriUIFoundation and ViewBridge. |

Evidence IDs: launcher strings
`ev_936c2f79c4d0f550b2baa2c1ee04c88bdde0e72b80073978b8edb0068b25279f`;
real-app Mach-O summary
`ev_136ebeb8f02a3306248add34106ffab622a0c8909d3f63c37a609ed65e043533`;
real-app strings
`ev_f85e13d5fa88a466b2b9fb2e64d25a73050399e42bf9a8e298963b3489d6277f`.
The latter includes `AFUISiriViewController`, remote view-service transfer
messages and Siri controller lifecycle selectors. This establishes private UI
and service boundaries; it does not expose a supported general-purpose Siri
search API or establish the exact rendering of every macOS 27 Siri surface.
No decompiled implementation was copied, no private framework was linked, no
Siri service was called, and no microphone was activated for the study. The REA
session was closed after exporting local evidence. Binary inventories are not
runtime measurements and symbol searches do not prove absence of all APIs.

The design decisions above use Apple's public Liquid Glass guidance and the
local SDK's public API rather than reconstructing private Siri machinery.

Sources checked 2026-10-16:

- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
- [NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)
- [Apple's macOS 27 and Siri AI announcement](https://www.apple.com/newsroom/2026/06/apple-unveils-next-generation-of-apple-intelligence-siri-ai-and-more/)

The local AppKit header marks `NSGlassEffectView` available in macOS 26 and
its additional interactive behavior in macOS 27. Evie uses SwiftUI's macOS-26
material, preserving compatibility rather than introducing a macOS-27-only
requirement.

## Icon source and reproducibility

- Master: `Resources/Evie-Icon-Source.png`, 1254 × 1254 RGBA, original artwork
  generated with the built-in ImageGen tool on 2026-10-16.
- Master SHA-256: `e8b3a01583c9122ba90f54aaf2333f688b54027d73a1a96c61248d1cf084b48a`.
- Installed asset: `Resources/Evie.icns`, ten native entries from 16 through
  1024 pixels. Transparent margins and alpha are preserved.
- Rebuild: `Scripts/evie-icon`; requires only macOS `sips` and `iconutil`, no
  network or image model. `Scripts/evie-app build` copies this `.icns` into the
  bundle. Rebuilt twice with the same SHA-256:
  `7a1de43b848581ae09bd144686e91949651603032ba7110ffcf86ebc801fda53`.
- Generation itself is stochastic. The checked-in master, not regeneration
  from the prompt, makes packaging reproducible.

Final generation prompt (built-in ImageGen, transparent background enabled):

> Use case: logo-brand. Asset type: macOS application icon for an original personal assistant named Evie. Create a single production-ready icon in a square 1024x1024 canvas with truly transparent pixels outside a centered rounded-square tile occupying 824x824 pixels. Original identity: two four-point curved sparkles, one large centered lower-left and one small companion upper-right, sculpted from luminous translucent lavender crystal. Background tile is frosted deep violet glass with a subtle cool cyan reflection on the left and a faint rose reflection on the right. Restrained macOS Liquid Glass inspired material, thin bright upper edge, soft depth, polished but exceptionally legible at small Dock sizes. Straight-on orthographic, symmetric square tile, clear margins, no scene or perspective. Mark is original and independent, do not imitate Siri orb, Apple logo, or existing brand assets. No letters, no text, no watermark, no border beyond tile. Beautiful contrast, simple silhouette, gentle shadow confined within transparent margins.

The tool returned 1254 pixels rather than the requested 1024; the packager
normalizes each target size. The generated tile is artwork, not a dynamic
Icon Composer document. No claim of exclusive copyright in model-generated
art is implied by its inclusion or by the repository license.

## Verification

Executed:

- `swiftc -typecheck Sources/EvieShell/Views/GlassSurface.swift` — passed.
- `swiftc -typecheck Sources/EvieShell/Views/EvieBadgeLayerView.swift` — passed.
- `Scripts/evie-icon` twice — passed, identical output digest.
- `iconutil --convert iconset … Resources/Evie.icns` — decoded all ten entries.
- `sips -g pixelWidth -g pixelHeight -g hasAlpha` on master — 1254 square, alpha.
- Native AppKit window probe with this surface implementation, screenshot via
  `screencapture -l <windowID>` — four captures succeeded, reviewed visually.
  Light/dark use real SwiftUI/AppKit materials. For the solid/contrast probes,
  a temporary source copy injects environment values into the exact fallback
  branch because SwiftUI exposes these environment keys as read-only; this
  does not claim that macOS accessibility preferences were changed or tested
  end-to-end. Production reads the actual environment keys.
- `zsh -n Scripts/evie-icon` — passed.
- `swift format lint --strict` on the three modified Swift views — passed.
- `git diff --check` — passed at the visual-work handoff.

Probe captures, using synthetic content only:
[Light](images/apple-visual/glass-light.png),
[Dark](images/apple-visual/glass-dark.png),
[Opaque fallback](images/apple-visual/glass-solid.png),
[Increased contrast fallback](images/apple-visual/glass-contrast.png).
These are component probes, not screenshots of the final integrated app. Full
package tests, installed-app checks and profiling are recorded by the integration
run in the work log. No new tests merely mirror visual token declarations.

## Integrated snapshot correction

The first integration run's `/tmp/evie-integrated-ui/overlay-chip-light.png`
contained only its gradient: the old `cacheDisplay` diagnostic omitted
compositor-owned HUD content. That image is **invalid visual QA evidence**.
The four component-probe captures above used real displayed windows and are
unaffected. The integration diagnostic now displays only synthetic fixtures
and captures the exact owned window ID/PID through ScreenCaptureKit, with an
owned opaque backdrop so behind-window vibrancy cannot sample personal apps.
It preflights the app's existing screen-capture grant and refuses instead of
prompting or falling back to a misleading offscreen PNG. Integrated capture
results are recorded after the rebuilt app executes this corrected path.

The corrected diagnostic ran from `/tmp/evie-ui-native/Evie.app`, a copy of
the release bundle containing the built debug executable, signed and verified
with the same pinned application identity; no installation was replaced.
All 18 PNGs were written successfully to `/tmp/evie-ui-native/snapshots/`.
Historically reviewed: the six brain statuses, agent outline, idle voice capsule, expanded
brain controls, answer card, research consent window, and minimum-size Settings.
Both appearances contain actual native controls and text with no overlap in
the input area. The diagnostic windows were displayed without activation, so
platform inactive-control styling is expected. Permission rows are synthetic
fixture values, not a statement of this Mac's actual grants. Representative
captures from that compositor correction:

- [Input controls, light](images/apple-visual/integrated-overlay-light.png)
- [Input controls, dark](images/apple-visual/integrated-overlay-dark.png)
- [Legacy expanded brain controls, light](images/apple-visual/legacy-brain-controls-light.png)
- [Legacy expanded brain controls, dark](images/apple-visual/legacy-brain-controls-dark.png)

The final installed-UI review on 2026-10-17 found a separate layout defect in
the then-installed popover and an older `/tmp/evie-integrated-ui/` preview:
the unconstrained stack exceeded the 330-point scroll viewport and clipped
its side insets. The archived legacy images linked above predate the context
section and have intact insets; they record an older layout, rather than
evidence of that clipping or of the current popover.
The source now bounds content to 294 points inside the 18-point insets, uses
the small native segmented picker and wraps explanatory text. A standalone
Swift 6 build passed warnings-as-errors; its visible owned-window
[corrected layout capture](images/apple-visual/brain-controls-context-fixed.png)
shows complete text in normal and compacting states. Inactive gray styling in
that synthetic capture does not validate active-control colors.

The installed candidate was then checked separately on 2026-10-17. Its
[actual popover capture](images/apple-visual/installed-brain-controls.png)
shows complete insets and wrapped captions, a gold brain button and blue
enabled agent/web switches. Stable semantic AX identifiers resolved the brain
and all three model options; the public AX API returned their spoken labels.
Automatic → Mac → PC selections each persisted, with reasoning off and
agent/web enabled restored at the end. No chat/model request was submitted.
The installed `--ui-snapshots` process also exited successfully after producing
18 owned-window fixtures. The regenerated expanded controls were reviewed in
[light](images/apple-visual/integrated-brain-controls-light.png) and
[dark](images/apple-visual/integrated-brain-controls-dark.png); neither clips
the content. Other fixture images from that run were produced, but this final
review concerns the two brain-control captures. The normal app stayed running;
the temporary diagnostic process exited and its windows closed.

A final privacy review inspected the six brain-control PNGs linked here,
including both archived previews. Local CPU Vision OCR returned 21–55 text
lines per image and found no endpoint URL, tailnet name, private address,
credential or email pattern. Visual inspection likewise found only Evie's
controls and synthetic fixture text. PNG metadata contains pixel dimensions,
resolution/color data and, for the two window screenshots, the generic comment
“Screenshot”; no username, host, location or credential was found. This review
is scoped to those six files, not every image in the repository.

A diagnostic `sandbox_extension_issue_file_to_process` log was emitted in the
earlier temporary-bundle run, but its process exited successfully and every
expected selected-window capture was produced. That run verifies rendering, not physical
click dispatch or model selection persistence; the later installed-candidate
semantic actions and persistence checks are recorded separately above.
