# Guided Settings Implementation Plan

**Goal:** Apply the approved guided native minimalism to every Settings destination and editor, excluding the pill.

**Architecture:** SwiftUI presentation changes consume the existing AppModel and services unchanged. Four local workers own disjoint view files; Captain owns integration, native builds/captures and packaging. Shared component signatures below are fixed before parallel work. No commits or external publication are authorized.

**Tech stack:** Existing SwiftUI/AppKit, SF Symbols and system fonts; macOS 14+, existing SwiftPM/SwiftBuild resources.

## Constraints

- Preserve 900 × 570 outer window, six destinations and one retained Settings/About window.
- Use 176-point sidebar, 28-point content horizontal padding, 36-point top padding, neutral light/dark surfaces and roughly 20-point section gaps.
- Do not edit AppModel, Core/Services, native adapters, AppCoordinator, pill-kit or branding geometry/assets.
- Keep real provider/preset IDs, routing/privacy/billing safeguards, actual actions, native focus and all preview side-effect guards.
- No credentials, host writes, permission grants, real provider calls, commits or cloud machines during verification.

## Shared interfaces

The shell worker implements these in `Sources/ImrseApp/Views/SettingsPrimitives.swift`, retaining existing component APIs:

```swift
SettingsPage(title: String, subtitle: String? = nil, symbol: String? = nil) { content }
SettingsSection(title: String, symbol: String? = nil, detail: String? = nil) { content }
SettingsHint(title: String, detail: String, symbol: String = "lightbulb")
SettingsStatusBadge(title: String, symbol: String, tone: SettingsStatusTone = .neutral)
SettingsIcon(symbol: String, size: CGFloat = 32)
SettingsKeycap(value: String)
```

`SettingsStatusTone` has `.neutral`, `.positive`, `.warning`. Status must come from actual state; preview is neutral. Groups are functional, never nested decorative cards. Optional parameters remain optional so unchanged consumers compile.

## Local worker ownership

- [x] Shell: `SettingsPrimitives.swift`, `SettingsView.swift`, `GeneralSettingsPane.swift`, `AboutSettingsPane.swift`. Implement shared components, compact icon-led headers/sidebar, grouped General controls and visual About links. Preserve all bindings and service calls.
- [x] Presets/Advanced: `PresetsSettingsPane.swift`, `AdvancedSettingsPane.swift` including its DiagnosticsSheet. Lead with essentials, reveal optional routing/power-user details, preserve all fields and Save/Cancel/removal guards, and replace paragraph-heavy help with concise contextual hints.
- [x] Shortcuts: `ShortcutsSettingsPane.swift`, `ShortcutRecorder.swift` presentation only. Use keycaps, actual-status badges and two understandable permission/action rows. Keep recorder focus/key/session logic and activation retry code unchanged.
- [x] Models/providers: `ModelsSettingsPane.swift`, `ModelProviderListView.swift`, `ProviderEditorSheet.swift`, `LocalModelSettingsPane.swift`, `ChatGPTAccountSettingsPane.swift`, `APIKeyProviderSettingsPane.swift`, `CustomProviderSettingsPane.swift`, `CuratedModelChoicesView.swift`, display metadata only in `ModelProviderSection.swift`. Use consistent rows, status, short billing/privacy hints and compact grouped fields. Preserve real provider IDs, model/default selection, removal/account safety and all async operations.

Workers use `swiftc -parse` only until Captain releases the one shared SwiftPM cache. They report changed files, checks and risks; they do not commit or run concurrent desktop automation.

## Integration and verification

- [x] Run strict native Debug using `swift test --scratch-path "$HOME/.capy/work/imrse-verification/full-build" --jobs 1 -Xswiftc -warnings-as-errors`; require zero failures and retain the opt-in download skip.
- [x] Refresh the signed, side-effect-free preview executable and capture all six pages light/dark plus all five provider sheets. Inspect alignment, truncation, critical warning visibility, contrast and nested-group noise at the actual 900 × 570 window.
- [x] Exercise safe sidebar/About, preset details/Cancel and diagnostics navigation using owned preview windows only. Record actual observations separately from physical MacBook claims.
- [x] Run strict Release with the same scratch path and `-c release`; build via resource-complete `scripts/build-app.sh` with the dedicated SwiftBuild cache.
- [x] Verify Info.plist, universal slices, strict ad-hoc signature, supplied logo bytes, Metal/license resources and Release preview exclusion. ZIP with `ditto`, extract and reverify signature/resources. Delivery uses the verified test ZIP and final native captures.
