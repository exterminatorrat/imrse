# Custom input focus: evidence and remaining boundary

## Preserved result

The reviewed preset-only fix is commit `d4ca2d951863799384178317032e3c1b2fc899c9`. Six direct-preset forwards and three Imrse Undos passed across disposable Capy, Word and TextEdit fixtures. This does not qualify custom instruction entry or all application fields. Its candidate is locally signed, not a universal/daily-use release.

## What the controls established

- Capturing a Capy selection and presenting the normal instruction panel can produce an AX focus-observer `noValue` while Imrse's own panel is key and its app active. The retained event occurred during input, without generation or replacement.
- Removing only `NSApp.activate()` did not establish a solution. Initial CUA inspection activated Imrse and confounded the apparent keyboard result.
- A CUA-free control of that experiment found the instruction AX field reported focused, but real q/a keystrokes went into the disposable host selection. Escape did not dismiss the instruction panel. No model, Apply, Enter or host submission occurred; the fixture was cleaned. That experiment is excluded from the preset-fix branch.
- Current target guards fail closed. They do not treat eventual equality after an observed focus gap as proof of uninterrupted user intent.

## Supported APIs and unresolved hosting question

Apple documents nonactivating panels separately from keyboard focus, and `needsPanelToBecomeKey` for views receiving keyboard input. This makes a nonactivating input surface a legitimate platform concept, not proof that the present SwiftUI hosting implementation routes keys correctly.

The current controller makes the `NSHostingView` its first responder, while the SwiftUI field requests focus asynchronously through `FocusState`. Apple's `makeFirstResponder` contract says a successful return can still leave the window as responder if the requested view does not accept it. Therefore `isKey`, AX-focused metadata, or a successful responder request alone cannot establish actual keyboard destination. Whether this hosting/responder integration explains the failure remains untested; changing it speculatively would be unsafe after the demonstrated host keystrokes.

Primary references:
- https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel
- https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded
- https://developer.apple.com/documentation/appkit/nsview/needspaneltobecomekey
- https://developer.apple.com/documentation/appkit/nswindow/makefirstresponder(_:)
- https://developer.apple.com/documentation/swiftui/nshostingview/acceptsfirstresponder

## No hidden safety-model change

Own-window key/resign notifications prove local UI lifecycle, not a lossless history of external selection/document intent. Public AX notifications do not supply a documented versioned, atomic target lease. Do not suppress missing/different focus events, silently reacquire another anchor, accept later restored equality as continuity, use private WindowServer focus-stealing APIs, or treat Services' current-selection replacement as a pinned-target guarantee.

A custom-input fix without layout redesign would need actual supported keyboard routing into the existing instruction control while preserving the original target proof and detecting external changes. That has not been demonstrated. A new isolated native AppKit field/panel probe could distinguish the platform path from the SwiftUI hosting path, but its execution requires the owner's explicit approval under the current task guidance. The owner explicitly approved one bounded diagnostic. Its isolated artifact has been compiled, locally signed and independently verified; execution and routing outcomes must be recorded separately.

## Bounded next qualification, if authorized

Use noneditable Calculator or Finder as foreground host, with no user document or prompt, and an isolated native nonactivating panel with a native text field. No model, network, host AX mutation, clipboard operations or automatic replacement. Inspect only closed own-window/responder booleans; test actual synthetic typing and Escape, stop immediately if keys go to the host, and remove the diagnostic artifact after collecting evidence. Compare with the existing hosting path. Success would justify a separately reviewed input-bridge implementation, not target-guard relaxation. Then qualify ordinary typing, existing IME behavior, cancellation, and third-app/window/document/selection changes before replacement.

If that supported path cannot satisfy the constraints, the honest alternatives are instruction-first followed by explicit new target capture, or manual transfer/preview. Both change the interaction contract and require product/UI scope; they are not silently implemented here. Manual preview remains backend-only.

## Approved native-field diagnostic result

The single corrected native-service trial used a separately compiled/signed AppKit panel and noneditable Calculator foreground. The first sandboxed launch aborted during AppKit registration before any input; no routing conclusion follows from that launch.

The corrected trial verified the exact own panel and initially empty native field before one actual q/a key sequence and one Escape. The field did not equal `qa`; no Escape event was recorded. Internal field-editor identity and panel-key booleans remained true, but those did not establish functional keyboard routing. One own-field-change event occurred; contents were intentionally not logged, so partial input cannot be reconstructed. The panel terminated at its 30-second deadline. NSApp activity and the external application activity observation disagreed; neither is treated as authority for routing.

This fails the diagnostic's functional criteria. It does not establish a native-field fix, isolate SwiftUI as cause, or authorize any capture-guard weakening. Process cleanup succeeded independently of routing. The compiled diagnostic and temporary run directories were removed; closed reports and source remain for reproducibility. No model, user document, prompt submission, clipboard access or product mutation occurred.

Under the current no-UI-redesign requirement, retain the verified direct-preset fix, preserve strict custom-input refusal, and retain the backend-only manual-preview primitives. There is no evidence-supported transparent custom-input correction ready to ship. Explicit fresh target capture after instruction entry or manual transfer would require a separately agreed interaction change; neither is silently implemented.
