# Capy integration instructions

Integrate this kit into the existing imrse macOS workspace rather than rebuilding the settings UI from scratch.

## Preserve exactly

- one Settings window for both settings and About
- primary sidebar: General, Models, Presets, Shortcuts, Advanced
- About pinned at the bottom of the sidebar after a subtle divider
- no standalone About window
- no Diagnostics sidebar row; Advanced opens the Diagnostics sheet
- no back button in Edit Preset
- Edit Preset actions: Delete / Cancel / Save
- provider editors as sheets
- minimal monochrome visual system
- wider right content pane
- no product slogan/tagline in Settings or About

## Wire to existing services

Replace preview data/callbacks with the existing imrse services for:

- global shortcut recorder
- launch-at-login preference
- menu-bar visibility
- model/provider store
- Keychain credential storage
- preset store
- config directory
- logs directory
- diagnostics snapshot
- pasteboard
- external URLs

Do not move secrets into `ImrseSettingsState`. `onStoreCredential` is the bridge to the app's Keychain service.

## First Mac verification

1. Open Settings and verify the window is 900 × 570 with the sidebar visually close to the approved reference.
2. Switch through every sidebar item.
3. Verify About changes only the right pane and remains selected in the bottom sidebar row.
4. Add/edit/delete a provider; confirm sheets size correctly and keyboard focus works.
5. Create/edit/delete a preset; verify there is no back arrow.
6. Verify Global Invocation and preset shortcut callbacks open the real shortcut recorder.
7. Open Diagnostics from Advanced and verify the report excludes selected/generated text and secrets.
8. Check light and dark appearances.
9. Verify the Settings window uses native traffic lights and does not draw fake titlebar chrome.
