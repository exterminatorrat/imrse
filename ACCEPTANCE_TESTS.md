# v0.1 acceptance tests

Passing portable tests is necessary, not proof of host-app compatibility. The manual release gate is `UNVERIFIED_MACOS.md`; an unchecked native result remains unverified.

## Automated behavior

Run `swift test -Xswiftc -warnings-as-errors`. On Linux the package graph contains only Core, Services and their tests. On macOS it also compiles the native app/adapters. `VERIFICATION.md` records measured Debug/Release, cross-platform, source-identity and rendering results without converting them into host-compatibility claims.

| Contract | Required evidence |
| --- | --- |
| Capture precedes focus | A fake capture records the selection before the ready-state callback fires. |
| Single owner | Repeated Return/invocation cannot produce concurrent replacement calls. |
| Cancellation | Immediate cancellation, mid-stream cancellation, and completion races cannot produce a late write. |
| Commit discipline | Only a valid complete output causes one replacement; empty, whitespace, malformed, oversized and interrupted output cause none. |
| Content integrity | Emoji, combining marks, CJK, RTL, Markdown, code, JSON and multiline selections retain Unicode and formatting in requests. |
| Target safety | Changed app/selection, invalid target and adapter failures never report success. |
| Undo | Latest verified receipt restores once; absent/stale receipts fail conservatively. |
| Provider behavior | OpenAI-compatible requests, authentication, 429/5xx, cancellation, malformed payload, timeout and partial SSE events are tested without keys. |
| Privacy routing | Loopback-only local presets cannot reach a cloud endpoint, including redirects and fallback. |
| Files | Bootstrap preserves user files; missing/blank default, malformed settings/presets and duplicate shortcuts are handled explicitly. |
| Diagnostics | Content/credential sentinel strings never appear in reports; only metadata and error categories do. |
| Shortcuts | Double-Control ignores chords, intervening keys, repeats and slow taps. Explicit bindings reject modifier-only/invalid key codes and duplicate imrse assignments; reassignment and clearing preserve unrelated settings. |
| Shortcut recording | Only the focused recorder captures key-down events; repeats are ignored, plain Escape cancels and modified Escape is bindable. Cancel, focus loss and unmount end the session. Recording blocks activation and stale monitor callbacks; preview/test initialization never starts monitoring. Preset drafts preserve unrelated overrides. |
| Managed models | Pinned artifacts/revisions, exact sizes/hashes, safe staging/redirects, atomic receipt installation, cancellation cleanup, corrupt-install repair, offline loading, active-model removal exclusion and bounded native generation are tested. Length/cancel/missing completion cannot commit. |
| Account connection | PKCE/state/nonce, signed identity claims/scopes, isolated OAuth keys, refresh/write/disconnect races, attempt/run-scoped cancellation, form encoding, account catalog and completed final-answer-only Responses output are tested with synthetic credentials. |
| Billing boundary | A ChatGPT primary cannot switch to remote API-key fallback; unavailable account recommendations do not become entitled choices. Existing providers/defaults/preset overrides are preserved. |

## Visual harness

Run the supplied React preview's typecheck, unit/source tests, browser tests and build from `pill-kit/web`. Review hidden, input, long instruction, processing, applying, success and error in light/dark and diverse contrast environments. Confirm 52-point height and the phase widths (360/240/220/180/300), the original 24-point SpiralLoader retains its identity while labels change every 2.5 seconds without processing-width jitter, keyboard focus is visible, and Reduced Motion uses the original static artwork. Preview completion is simulated and must never count as host replacement evidence.

Settings must render actual editable fields and useful no-provider states, not decorative controls. Review General, Models, Presets, Shortcuts, Advanced and About against the supplied settings handoff in light and dark appearances. The native outer window is 900 × 570; sidebar labels and General controls must fit without truncation or duplicate menu arrows. About must remain in the same window. The web harness is not evidence of native rendering.

Native Shortcuts and the scrollable preset editor must expose their shortcut record/change/clear controls without clipping. Verify physical capture, cancellation, keyboard-layout labels and global activation separately from DEBUG screenshots; side-effecting preview controls are intentionally disabled. macOS and other-app shortcut delivery/collisions require manual verification. Preset editor cancellation must discard the draft rather than save it.

Models must list actual configured providers by their existing IDs and open native add/edit sheets for Local, ChatGPT account, OpenAI API, OpenRouter and Custom advanced. Preview fixtures must disable persistence, Keychain queries, browser authorization, downloads and inference. Capture actual native views; a web illustration does not prove native layout. Separately verify one real non-sensitive offline local transformation and a relocated bundle's MLX shader/resource loading. A browser login/API key requires explicit human consent, never a synthetic-success claim.

## Native release gates

1. Build an `.app` with `scripts/build-app.sh`; verify its Info.plist and signature. A local ad-hoc signature is not notarization.
2. Launch with no configuration. Click the supplied menu-bar logo to open Settings directly; repeated opens, About navigation and close/reopen must not create another Settings/About window. Test right/Control-click operational menus, ⌘W/⌘, and Dock recovery after hiding the status item. Settings must let a user configure a compatible model, save a key securely, locate their files and understand missing permissions.
3. Grant Accessibility manually and verify monitoring in diagnostics. Do not change permissions through an automated test.
4. Follow the host-app matrix in `UNVERIFIED_MACOS.md` using non-sensitive fixtures. Record strategy, outcome, undo and clipboard result for each app/version.
5. Use a real local model and then a deliberately invalid model/key. Correct output replaces once; provider failures preserve original text.
6. Switch apps, fields or selections during generation. Nothing may be written into an unintended target.
7. Verify native VoiceOver labels, keyboard navigation, Reduced Motion, light/dark contrast, multi-display positioning and Spaces behavior.
8. Quit during generation and relaunch. No pending transform, text history or plaintext key may persist.

## Shipping claim

A source implementation may be ready for first physical compatibility validation while still failing the distribution gate. Do not advertise the compatibility matrix as supported until those physical tests have passed. Do not call a source/ad-hoc build a signed production release.
