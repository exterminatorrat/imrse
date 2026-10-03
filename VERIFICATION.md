# Verification summary

This is a public-safe summary of measured checks. Private machine-specific
diagnostics, account metadata, local installation records and screenshots are
not part of the source repository.

## Local packaged baseline — 0.1.2 build 11

- Strict Debug: 274 cases, one opt-in model-download/inference skip, zero failures.
- Strict Release: 227 cases, the same opt-in skip, zero failures.
- Both use `swift test --jobs 1 -Xswiftc -warnings-as-errors`, with `-c release`
  for the Release suite.
- The universal arm64/x86_64 app passed Info.plist validation, strict local
  ad-hoc signature verification, menu-template/MLX/Qwen/icon resource checks,
  Release preview/test-symbol exclusion and an exact 40-file ZIP roundtrip.
- Supplied loader/artwork identity passed
  `python3 pill-kit/scripts/verify-assets.py`.

The local bundle is not Developer ID signed or notarized. Compilation,
signatures and ZIP integrity do not establish distribution readiness.

## CI compatibility follow-up

The first hosted run exposed a Linux Foundation integer-precision difference
and a Swift 6.2 generic Sendable requirement. Token parsing now preserves signed
and unsigned integer representations without passing them through a rounded
Decimal bridge; floating and Decimal counts still require exact nonnegative
in-range integers. Existing maximum-count assertions remain unchanged, with
additional precision, overflow and fractional tests.

The current portable suite passed on a local Swift 6.2.4 Linux verifier, along
with all 16 native-kit Core tests. The 24 focused macOS numeric/account tests
also passed. A fresh hosted macOS run is needed to confirm Swift 6.2 compatibility;
the local packaged baseline used a newer compiler.

## Native behavior measured

Disposable production-adapter probes passed selected-text replacement and exact
inverse Undo in TextEdit plain text and in Safari, Chrome and Vivaldi input and
textarea controls. Browser probes explicitly enabled clipboard fallback,
required an initially empty clipboard and verified it empty afterward. Known
multi-segment span-contenteditable fixtures refused before clipboard preparation
with their entire original value unchanged. These are bounded fixture results,
not universal host or rich-editor compatibility claims.

Chrome's delayed range/text readbacks are covered by bounded Undo confirmation.
Native confirmation does not require optional whole-value metadata. Clipboard
fallback proceeds only after an exact no-op proof and repeated bounded target
structure checks. No whitespace normalization or host Cmd-Z rollback is used.

The unchanged hosted regression verifies rendered applying/failure text and panel
dimensions. Lifecycle publication occurs after storing the new phase. Native
input previews accepted typing without a click, Return processing and Escape
dismissal; physical keyboards, IME, Spaces and multi-display behavior remain
separate checks.

## Settings and account boundaries

Native inert previews inspected the Settings destinations, provider sheets,
presets and Diagnostics in light and dark appearance. Enabled in-memory control
fixtures verified padded hit regions, popup options/checkmarks and keyboard
selection. The interval field committed exact whole milliseconds and rejected
invalid values without saving. Native window controls, retained-window behavior,
the full-size titlebar correction and the centered login switch were inspected.

The account catalog exposes validated reported IDs rather than only intersecting
two hard-coded recommendations. A saved model absent from the list stays
configured and is labeled separately. Read-only catalog/provider probes
established that an omitted configured route could still complete a disposable
transformation. This does not establish every listed ID's Responses capability,
model aliases or API-key billing fallback; account failures never enable that
fallback.

Native ServiceManagement registration was observed enabled and persisted through
an app update. An owned diagnostic entry was registered and immediately removed.
The implementation retains native approval/signature errors and does not use a
LaunchAgent workaround. A fresh user login was not performed.

Response details default off and are session-only. Model, token counts and USD
cost use reported metadata; absent values are individually Unavailable. No
configured-model substitution, inferred token total or pricing estimate is used.

See [UNVERIFIED_MACOS.md](UNVERIFIED_MACOS.md) for the remaining release gates.
