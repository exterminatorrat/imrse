# Design

The supplied `pill-kit` source remains the pill authority. See [pill-kit/DESIGN.md](pill-kit/DESIGN.md) and [CAPY-INTEGRATION.md](pill-kit/CAPY-INTEGRATION.md). The approved guided native minimalism direction applies to Settings, explicitly excluding the pill. The original [settings handoff](settings-kit/CAPY-INTEGRATION.md) and [General reference](settings-kit/reference/approved-general-settings.png) remain provenance for navigation and native behavior, not a requirement to retain their flat presentation.

## Approved Settings direction — guided native minimalism

All six Settings destinations, provider sheets, inline preset editors and diagnostics use the same visual vocabulary. Keep the single native 900 × 570 window and bottom-pinned About. Retain native traffic lights, native controls, the exact supplied branding and every real service/action. Do not touch the pill, loader, transformation lifecycle, account routing or activation implementation.

Use one system-font family, a compact icon-led heading with one concrete explanatory sentence, and functional setting groups with fine borders and no shadows. Use neutral light/dark surfaces; semantic green/amber is reserved for actual status, never decoration. A 176-point sidebar gives icons and labels breathing room. Content uses 28-point horizontal padding, 36-point top padding, roughly 20-point section gaps and 10-point group corners. Avoid nested cards, decorative gradients, illustrations, slogans and giant empty hero regions.

Education is contextual and short. General explains activation and behavior; Models distinguishes on-device inference, ChatGPT-plan use and separately billed APIs; Shortcuts uses visual keycaps, an explicit recording state and two understandable permission rows with actual status/actions. Presets leads with name/instruction and exposes optional routing details progressively. Advanced keeps diagnostic/configuration actions discoverable and tucks power-user editing behind clear details. About uses visual link rows without adding marketing copy. Critical billing/privacy information, real errors and destructive-action warnings remain visible near their controls.

Progressive disclosure changes presentation, not persistence or available options. Preserve preset identity, all draft fields and Cancel semantics. Keep provider identity/default selection, removal restrictions, actual connection/download/repair operations and preview guards. Empty states explain the next real action instead of simulating configured providers or granted permissions. Keyboard focus, accessible labels, light/dark contrast and Reduced Motion remain native.

The common view vocabulary lives in `SettingsPrimitives.swift`: `SettingsPage`, `SettingsSection`, `SettingsHint`, `SettingsStatusBadge`, `SettingsIcon` and `SettingsKeycap`. Each has multiple current consumers; no new service abstraction or dependency is needed. Final acceptance requires actual native light/dark captures of every destination and provider type, safe editor/sheet navigation, strict native tests and resource-complete local packaging. Physical MacBook activation remains a separate gate.

## Fixed, monochrome, transient

The user's 2026-09-30 clarification means narrower left-to-right, not reduced height. Every visible state keeps the original 52-point height and capsule radius 26. Widths are 360 for input, 240 for processing, 220 for applying, 180 for success and 300 for error. Horizontal padding remains 20, system text 13 regular, actions 11 regular, and the original loader stays 24 points. Nothing is visible before invocation; no resting launcher, orb, persistent bump or hidden empty panel occupies the screen.

Use the supplied SwiftUI view inside the existing AppKit panel. The React implementation is a standalone visual preview, never a WKWebView inside the app. Do not redesign either from a screenshot. Preserve the return glyph as a functional submit control and avoid decorative leading icons or sparkles.

## Original motion assets

Use the original 24 × 24 SpiralLoader canvas, its original JSON and 24% artwork opacity, four fast loops then two slow loops, and 75 ms phase crossfade. The native wrapper tints only the stroke black/white for appearance. Do not substitute an SF Symbol, rotating CSS circle or generated spinner.

Activity words change every 2.5 seconds with one set of animated dots. Words are activity copy, not claims about internal model reasoning. Changing a word must not reset the loader, alter the fixed processing width, or move the trailing action. The existing native panel resizes only when the phase changes, staying centered on the captured source screen without reactivation or recapture. Reduced Motion uses a static frame of the same artwork and static text/dots.

## Host behavior

Capture the original application, target, selection and source screen before showing input. Blank submission resolves the user's default.md. Command-number mappings fill real configured presets only inside the active input. Enter is composition-safe; Escape dismisses input, cancels matching generation, or dismisses an error.

The host engine owns generation, revalidation, cancellation, replacement and Undo. It sends `generated(id)` at the commit boundary and `applied(id)` only after verified replacement. Stale IDs and late callbacks cannot report success. UI dismissal does not roll back a commit already in progress. Guarded Undo remains available in the normal app menu after the brief confirmation disappears.

## Settings and verification

Settings preserve the supplied [settings-kit integration contract](settings-kit/CAPY-INTEGRATION.md) for ownership and navigation: a single native 900 × 570 window, a primary sidebar for General, Models, Presets, Shortcuts and Advanced, and About pinned at the bottom after a subtle divider. About changes the same window's content, never opens a standalone panel. The approved guided-minimal direction above supersedes the reference's row presentation. No fake titlebar chrome, decorative cards, gradients or product slogan belongs in Settings or About.

The supplied source is retained as provenance in `settings-kit`; the app adapts its presentation to the existing configuration, provider, shortcut and lifecycle services rather than installing its preview state as production state. Native compilation and rendering must be checked, not inferred from the handoff's parser-only checks. The Logo 04 dot-and-line mark is used without changing its supplied geometry; the template menu-bar icon opens Settings on a single click.

Preset editing stays in the Presets pane with Delete, Cancel and Save and no back arrow. Cancel must not persist a draft or shortcut change. Provider editors are sheets. Diagnostics is a sheet opened from Advanced, not a sidebar destination. General's menu-bar visibility and appearance settings persist without changing routing; existing configurations default to visible menu-bar access and system appearance. Launch-at-login state comes from the native service, not a mock toggle.

### Curated Models pane

Models uses the handoff's provider list and Add Provider row, with editing and connection details in sheets. Preserve Local, ChatGPT account, OpenAI API, OpenRouter and advanced compatible endpoints inside that presentation. Use flat native rows and quiet separators rather than an oversized dashboard. Model names lead, followed by one short task-oriented description and the relevant availability, memory/download or connection state. Do not label unmeasured models as best.

Match the pill's restrained monochrome taste through system typography, approximately 13-point primary labels and 11-point supporting copy/actions, clear alignment and deliberate whitespace. Native focus rings, accessible status text and determinate download progress communicate state without ornamental animation. Keep progress and errors near their initiating control. Cloud connections explicitly distinguish ChatGPT-plan usage from API-key billing; local models say that inference stays on this Mac. Advanced endpoint fields should not dominate first setup.

Download, cancel, remove, connect and disconnect are actual runtime actions, never simulated production controls. Downloads are opt-in; selection cannot silently fetch a model. Preview controls remain disabled and all preview state remains side-effect-free. The detailed feature scope and acceptance boundaries are in [MODEL_PROVIDERS_PLAN.md](MODEL_PROVIDERS_PLAN.md).

Keep upstream source, asset manifests and licenses intact. Run the supplied identity tests, portable tests, web dependency-aware typecheck/build and real browser checks. Native compilation, native presentation, permissions and host replacement are separate claims; record each honestly in `UNVERIFIED_MACOS.md` and the integration verification ledger.
