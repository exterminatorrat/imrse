# imrse Settings Kit

Native macOS SwiftUI/AppKit settings surfaces matching the approved minimal imrse direction.

## Included screens

- General
- Models
- Add Provider sheet
- Edit Provider sheet
- Presets
- New/Edit Preset
- Shortcuts
- Advanced
- Diagnostics sheet (opened from Advanced; it is intentionally not a sidebar destination)
- About (pinned to the bottom of the same sidebar and rendered in the same window)

## Approved navigation

Primary sidebar:

1. General
2. Models
3. Presets
4. Shortcuts
5. Advanced

Bottom-pinned:

- About

The About page is not a separate window. `Edit Preset` is not a push-navigation screen and has no back arrow; it uses Delete / Cancel / Save.

## Integration

`ImrseSettingsView` is the public root:

```swift
@State private var settings = ImrseSettingsState.preview

ImrseSettingsView(
    state: $settings,
    diagnostics: diagnosticsSnapshot,
    version: "0.1.0",
    actions: ImrseSettingsActions(
        onChangeGlobalShortcut: { /* open shortcut recorder */ },
        onChangePresetShortcut: { presetID in /* record shortcut */ },
        onStoreCredential: { providerID, secret in /* Keychain */ },
        onOpenConfigLocation: { /* Finder */ },
        onOpenLogs: { /* Finder / Console */ },
        onCopyDiagnostics: { report in /* pasteboard */ },
        onOpenURL: { url in NSWorkspace.shared.open(url) }
    )
)
```

The host app owns persistence and macOS service integration. The kit owns presentation and local edit flow.

## Visual rules

- black / white / neutral gray only
- no gradients or AI sparkles
- no cards around every setting row
- sidebar is deliberately narrow
- content area is deliberately wider than the earlier concepts
- system typography and SF Symbols
- About is visually quiet and has no tagline
- real macOS traffic lights are retained through `ImrseSettingsWindowConfigurator`

The approved General reference is in `reference/approved-general-settings.png`.

## Linux validation

The platform-independent state/navigation code is testable on Linux. Native SwiftUI rendering and AppKit window behavior require macOS/Xcode and are not claimed as runtime-verified here.
