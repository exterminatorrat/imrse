# macOS integration

The native boundary is `ImrseMac`; business logic must not import AppKit. The `.app` is a menu-bar/accessory application targeting macOS 14+. It needs Accessibility to inspect/write host selections and may need separate permission for event monitoring. It is not sandboxed: cross-application AX and the user-owned configuration directory are central to the product.

## Capture and target lifetime

`MacSelectionAccess` adapts `SelectionAccess`. Capture identifies `NSWorkspace.shared.frontmostApplication`, obtains the focused AX element for that PID, checks secure input, and reads only selection metadata needed by the transformation. Capture happens synchronously before panel presentation. The returned Core snapshot contains text, bundle ID, PID, role, UTF-16 range and an opaque UUID; AX handles and platform verification data remain in the adapter registry.

Target validation is a precondition, not a convenience. Check application identity/liveness, element identity, protected input state, selected range and text. If the user changes apps or targets during generation, refuse to write. The fact that a panel temporarily owns focus is not permission to activate any app the user later left for another one.

AX calls can block; their native timeout should remain bounded. Some hosts expose neither selected text nor a reliable range. No reliable capture means no transformation. Clipboard copying of a selection is not a fallback capture strategy.

## Replacement

Try only strategies whose prerequisites can be verified:

1. Set the captured selected-text attribute when writable, then verify the completed mutation.
2. If a direct write was known not to mutate, replace a verified UTF-16 range in a readable/settable value. Avoid rich-text/structured targets where full-value assignment risks destroying formatting.
3. If enabled by the user, preserve the pasteboard's available data types, restore only captured-target focus under strict ownership guards, post a bounded paste, verify readback, and restore the old clipboard only if the temporary pasteboard is still owned by imrse.

A successful AX return code or posted Cmd+V is not proof of replacement. Once a write may have happened, an unverified result is a failure; blindly trying another strategy could insert the transformation twice. A changed target, selection or secure-input state blocks the operation. Never stream into any host field.

Undo uses the same captured target and a receipt for the latest verified mutation. Verify that the replacement is still present at the expected location before restoring the original. Do not use a global Cmd+Z, which could undo an unrelated user action.

## Invocation

`ShortcutMonitor` adapts native keyboard events to the portable shortcut recognizer. Double-Control requires isolated modifier taps inside the configured window; chords, repeats, intervening keys and Secure Input invalidate recognition. Explicit bindings have no preset defaults and must be checked for duplicates. A monitor that fails to install or is disabled must be reported as inactive, not silently treated as working.

System/application shortcut conflicts cannot always be detected by a passive event monitor. Choose bindings that do not conflict with the host and validate them physically. Never substitute a default Cmd+number shortcut just because registration is inconvenient.

The Settings recorder captures only its own first-responder key events and intercepts Command-key equivalents only during an explicit recording session. It uses the same binding validator as persistence and recognition, and translates printable physical key codes through the current keyboard layout. Recording stops the global monitor; session-bound cleanup and activation epochs prevent stale callbacks from invoking. Restart is restricted to normal runtime initialization, never DEBUG preview or test-engine mode. No global key history is collected.

## Panel and settings

Global activation uses a listen-only CoreGraphics event tap and checks Input Monitoring separately from Accessibility. An inactive monitor can be retried explicitly from Shortcuts or when the app becomes active after a permission change. Recovery uses the existing pending-runtime path, defers during recording/generation/replacement/Undo, and cannot restart after termination. Permission links are user-click actions, not automatic prompts; preview disables them and never queries or starts monitoring.

AppKit owns the existing transient panel, key-window/responder behavior and screen placement. The supplied `ImrsePillView` keeps its original 52-point height with user-requested narrower widths by phase; native Lottie renders the original 24-point loader. The same panel derives dimensions from the shared phase-sizing policy and resizes without reactivation or target capture. Snapshot `MacSelectionAccess.capturedScreen` before presentation and keep the captured screen and bottom/center anchor for subsequent phase changes. Reserve the supplied shadow padding without changing the visible pill dimensions.

The supplied Logo 04 template is the actual `NSStatusItem` image. A primary click opens the single retained Settings window without an intermediate menu; right-click and Control-click retain the invocation/preset/Undo menu. The six-destination settings sidebar includes About in that same window. Native sheets hold provider editing and redacted diagnostics. Disabling menu-bar visibility changes activation policy to regular, preserving Dock/reopen and ⌘, access. Closing Settings does not terminate the menu-bar utility.

SwiftPM's generated resource accessor assumes an executable-style bundle layout, which macOS app signing rejects at the `.app` root. The packaging script puts generated resource bundles in `Contents/Resources`. The native loader explicitly resolves its animation bundle there for an installed app; only standalone SwiftPM executables/tests use `Bundle.module`. A missing installed resource never falls back to a development `.build` path. Third-party notices and the upstream/Lottie licenses travel in `Contents/Resources` as well. Packaging signs and verifies a fresh staging bundle before replacing the previous build.

The menu-bar template uses the same installed-bundle rule: resolve `imrse_ImrseApp.bundle/Brand` under `Contents/Resources`, never a developer fallback for an `.app`. Packaging fails if the supplied PDF is absent. The ten supplied iconset exports remain byte-identical and generate the packaged AppIcon; template geometry is not redrawn.

Keyboard submission must respect text composition: Return used to commit an IME candidate must not also submit the transformation. Escape cancels generation before commitment. Focus must not be transferred to a replacement host after the user chooses another app.

## Credentials and launch

`KeychainCredentialStore` uses provider-ID scoped generic-password entries with a stable service name. Read/update/delete failures are normalized; plaintext storage is never a fallback. Test keychain access with the final bundle identity because ad-hoc development signatures can change TCC/Keychain behavior.

Launch-at-login uses macOS ServiceManagement where offered. Show actual service registration and required approval, not a Boolean that claims success after a failed registration. A stable installed app path is necessary for meaningful login tests.

## Diagnostics

Expose permissions and monitoring separately, captured app/AX role/selection length/target validity, provider/model, lifecycle status, actual replacement strategy and normalized error. Copying a report never reads the user's clipboard or serializes selection snapshots. Use categories instead of raw native/server error strings when those strings might carry payloads.

## Runtime proof

See `UNVERIFIED_MACOS.md` for exact assumptions, fallback policies and manual validation. Native compilation proves API/type compatibility for the installed SDK only. It does not prove AX behavior, TCC, event tap delivery, panel focus, paste timing, Keychain prompts or individual application support.
