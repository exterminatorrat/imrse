# Capy handoff — integrate, do not redesign

## Task

Integrate this implemented pill kit into the EXISTING imrse workspace. Inspect the
workspace and its local instructions first. The public repo was empty when this
kit was prepared; do not assume that Capy's current checkout is also empty.
Do not overwrite unrelated work. Do not rebuild the whole application around the
preview. Do not alter provider, capture, replacement or privacy behavior merely to
fit this UI.

The source files are implementation, not pseudocode. Preserve the corrected visual
direction in DESIGN.md and reference/imrse-corrected-reference.png. Ignore older
boards with a circular/bullseye spinner or sparkle icon.

## Choose the correct integration path

**Native macOS app:** add `native/` as a local Swift package. Link ImrsePillUI.
Use ImrsePillView in the existing panel; only use PillPanelController if the app
has no panel owner. The native code renders the original JSON with native Lottie.
Do NOT put a WKWebView into the app merely to execute the JSX.

**React visual harness:** copy/reuse `web/`, or integrate its components into the
existing Next.js harness. Keep the published `SpiralLoader` source and data intact.
This component requires next/dynamic and next-themes. A ThemeProvider must be above
it. Include pill.css; it supplies scoped upstream utility classes when Tailwind is
not present. Set `@/*` to the src directory. No font download is necessary.

## Native event mapping

1. Existing global shortcut fires.
2. Existing capture service validates/captures the source app, focused element,
   selected text/range and screen BEFORE showing any imrse input.
3. Call `panel.present(afterCapturingTargetOn: sourceScreen)` (or model.present()
   with an existing panel). Do not show anything at app launch.
4. `model.onSubmit` receives a PillSubmission with a unique ID and instruction.
   nil instruction means use the existing default.md resolver. Retain the ID.
5. Run the existing cancellable generation request. Never stream tokens into
   the external app. On completed generation call `model.generated(id)`.
6. Revalidate the captured target and content using the existing replacement
   safeguards. If the target is stale, fail safely and offer the result elsewhere.
   No broad whole-field replacement or silent clipboard fallback should be added.
7. Only after confirmed replacement call `model.applied(id, undoAvailable: true)`.
8. A failure calls `model.failed(id, message: shortUserSafeMessage)`.
9. Wire `onCancel(id)` to the matching request's cancellation, not all requests.
   Once a host's atomic write has begun, the host must serialize it correctly;
   cancellation of UI is NOT a guarantee that an irreversible write was undone.
10. Wire onUndo to the existing guarded Undo operation. Keep Undo available from
    the app's normal menu/shortcut after the transient confirmation disappears.

Example model construction (supply existing services at these callback boundaries):

```swift
let model = PillModel(
    onSubmit: handleSubmission,
    onCancel: cancelRequest,
    onUndo: undoLastReplacement
)
model.presets = [
    PillPreset(id: "expand", name: "Expand",
               instruction: "Expand this while preserving my intent.")
]
let panel = PillPanelController(model: model)
// After capture, never at application startup:
panel.present(afterCapturingTargetOn: capturedScreen)
```

Those three handler names refer to the app's existing operations; they are not
replacement-engine implementations supplied by this UI package.

## React event mapping

Use ImrsePill as a controlled component. Use the portable transition reducer or
adapt its contract to the app's existing state store. Keep input text local to the
active interaction. Pass callbacks for submit/dismiss/undo/copy as appropriate.
Use unique request IDs; never report success merely because generation completed.
The demo page intentionally simulates host callbacks—do not ship that simulation
as the real transformation implementation.

## Preserve these details

- Hidden before invocation. No resting UI of any kind.
- 420 × 52 outer pill, 24 × 24 original loader; no width jitter between words.
- No decorative leading input icon and no sparkle anywhere in product UI.
- Actual upstream four-fast/two-slow Lottie sequence, not an imitation.
- Original 24% artwork opacity; do not boost it without an explicit design change.
- TextDots is a local implementation of the supplied API. Do not describe it as
  fetched upstream code. There is only one set of dots.
- 2.5-second word changes; label changes must not remount the loader.
- Cmd-1…9 fill mapped presets inside the active input only, not global defaults.
- IME-safe Enter; Escape works during input, processing and error.
- No content/credential logging, new model access, clipboard monitoring or tracking.
- Bundle resources and retain THIRD_PARTY_NOTICES.md / upstream/LICENSE.

## Verification to run in Capy

From web: npm install; npm run typecheck; npm test; npm run test:browser;
npm run build. Install Playwright Chromium if needed. Generate a real lockfile.
Do not weaken a failing test or edit the upstream loader to make a snapshot pass.

From native: swift test on Linux for Core only; on a Mac run swift build and
swift test. Native build was not executed in the producing environment.

On a real Mac validate panel focus, double-Control through the existing global
shortcut service, composition input, text-target preservation, all screen/Space
positions, Lottie tint/scaling, fast/slow rhythm and stop-on-dismiss behavior.
Use a supported text field first; third-party-app compatibility is the host's
integration responsibility and is not asserted by this kit.

Report exactly which validations ran. Do not mark unexecuted UI checks as passing.
Finish integration without redesigning the component or unrelated app surfaces.
