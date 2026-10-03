# imrse v0.1

**Your AI commands, everywhere you type.**

imrse reveals a temporary text-transform operation, not a conversation. Select text, double-tap Control, write an optional instruction, and press Return. A blank instruction uses the user's `default.md`. Presets may invoke the same lifecycle directly. No required cloud account, analytics, chat history, or document-wide content collection exists.

## Product contracts

- Capture the frontmost application, focused AX element, selection and UTF-16 range before presenting a panel. Never rediscover the target from the pill.
- Only selection context is supported in v0.1. Never capture a surrounding document or secure field. Treat an unknown or invalid target conservatively.
- One transformation may own the target at a time. Reinvocation cancels a pending generation rather than starting concurrent writes. Return is ignored while processing. Escape cancels before commitment; an already-started replacement is not interruptible halfway through.
- Generate fully, require an explicitly completed provider stream, validate output, revalidate the target, then commit once. No streaming tokens into applications. Unchanged output is a no-op, not a write.
- Replacement proceeds from selected-text AX to value/range AX. Clipboard fallback is opt-in, guarded, bounded, and verified. It must preserve the user's clipboard unless the user changes it meanwhile. Unverifiable writes are failures, never successes.
- Undo retains only the most recent successful original/replacement pair in memory. A changed target blocks undo. Quitting removes retained content.
- Local-only accepts managed on-device inference or loopback endpoints and never routes to a remote fallback. Provider redirects must not bypass this boundary. ChatGPT account failures never switch to remote API-key billing.
- Double-Control is enabled with a short timing window, rejects chords, key repeats and intervening keys. No preset shortcuts are assigned by default. Configured shortcuts require Command, Option or Control and reject duplicate imrse bindings; system/other-app conflicts cannot be detected.
- Errors remain quiet, actionable, and persistent until dismissed. Success is brief. Diagnostics contain categories and metadata, never selected/generated text, credentials, or clipboard data.

## Surface

A bottom-centered monochrome pill uses the provided `pill-kit` SwiftUI source with the user's requested narrower state widths, not a recreation from screenshots. Height stays 52 points; widths are input 360, processing 240, applying 220, success 180 and error 300. It remains completely invisible before invocation. Primary typography is 13 points; actions are 11 points. The original 24-point SpiralLoader keeps its 24% artwork opacity and four-fast/two-slow rhythm. Status words change every 2.5 seconds without resizing processing or remounting the loader; they describe activity, not model reasoning stages. Quick is default, Instant is available, Reduced Motion wins. Provider/model identity is available in Settings and diagnostics rather than additional pill chrome.

Command-1 through Command-9 fill configured presets only while the input has focus. They are not global default bindings. Repeated invocation while editing preserves the draft. Confirmed replacement shows `Updated`; generation alone or unchanged output must not produce this confirmation.

Settings retain the supplied sidebar ownership: General, Models, Presets, Shortcuts and Advanced, with About pinned at the bottom of the same window. Provider editors and Diagnostics are sheets; editing a preset uses Delete/Cancel/Save without a back arrow. The Logo 04 menu-bar icon opens Settings directly. The approved guided native minimalism refresh applies to Settings: compact icon-led sections, concise contextual guidance, real status badges, visual keycaps and progressive disclosure for optional details. No slogan, fake state or decorative chrome replaces native controls or actual app services.

Shortcuts records, changes and clears the main shortcut immediately. Presets records or clears a draft shortcut, persisted only by Save Preset. Recording is explicit and local to the focused field, pauses global activation, and ends on capture, plain Escape, cancellation or focus loss. Failed saves preserve existing settings. General selects invocation behavior and animation, native launch-at-login, menu-bar visibility and appearance.

Models offers a curated local library, official ChatGPT account connection, separate OpenAI/OpenRouter API-key connections, and an advanced compatible endpoint. Local download/run is in-app on Apple silicon, with pinned verified artifacts and explicit download/cancel/repair/remove controls. Account inference requires verified OAuth identity/consent and an available model. The provider list and editor sheets follow the supplied settings handoff and `DESIGN.md`; no new chrome enters the pill. Initial model choices are curated candidates, not an unmeasured best-model claim.

## Release boundary

macOS 14+, menu-bar app, SwiftPM build and app-bundle script; portable Core/services with conditional native account verification and Apple-silicon managed inference. Native adapters may require host-app-specific compatibility adjustments. A source build is not a signed/notarized release. All unsupported or untested platform claims must be recorded in `UNVERIFIED_MACOS.md`.
