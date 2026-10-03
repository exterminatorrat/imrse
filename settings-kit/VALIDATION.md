# Validation status

## Verified in this environment

- Swift Package resolves/builds on Linux for platform-independent code.
- Core/navigation tests execute on Linux.
- Sidebar contract is covered by tests.
- About is a same-window sidebar destination.
- Diagnostics is not a standalone sidebar destination.
- Preset editor navigation/cancel behavior is covered by tests.
- Provider/preset mutations and diagnostics redaction are covered by tests.
- Swift source files pass parser-level checks.

## Not runtime-verified here

The environment is Linux, so the following still require a physical Mac/Xcode run:

- SwiftUI layout fidelity
- exact SF Symbol rendering
- AppKit titlebar / traffic-light behavior
- native sheet sizing and focus
- macOS Toggle/Menu styling
- dark-mode material appearance
- Keychain callback integration
- Finder / NSWorkspace actions

The browser preview is included as a convenience reference only. Browser capture was blocked by the execution environment's browser policy, so it is not presented as verified rendering.
