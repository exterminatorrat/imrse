# Recognized proxy-editor refusal candidate

This is a conservative, incomplete negative filter, not universal editor safety.

## Evidence

On VS Code 1.138.0, a disposable two-selection document showed two selections in
its own status UI, while Accessibility exposed only one selected range. A full
AXValue for a small document therefore does not establish single-cursor scope.
The focused element exposed AXRoleDescription `editor` and AXDOMClassList
`native-edit-context`. Ordinary Chrome textarea exposed `text entry area` and an
empty class array. No multi-cursor paste was attempted.

## Bounded change

Refuse the exact observed VS Code application, and surfaces with explicit
`code editor` descriptions, exact `native-edit-context` or `monaco-editor` class
tokens, or the paired `inputarea` + `monaco-mouse-cursor-text` class tokens. Generic `editor` alone is deliberately not sufficient.
These content-controlled markers may be absent, localized, changed or imitated.
False refusals are possible; `inputarea` alone is not sufficient.
Known VS Code is refused application-wide, including otherwise simple fields.

Check the captured anchor and any resolved host, then recheck both during target
validation used by each final native setter and final paste verification. Undo
uses the same checks after asynchronous selection preparation. Refusal is terminal:
no native fallback, paste, alternate route or retry. An identified incompatible
Undo target invalidates its stored receipt. Genuine metadata failures fail closed;
unsupported optional attributes only mean no marker was identified. Metadata
reads are bounded by existing AX timeouts plus local size/count limits. They add
read overhead; compatibility and timing require live qualification.

Diagnostics contain only closed reasons (`virtualizedEditorSurface`,
`surfaceMetadataUnavailable`, or existing AX failure reasons), not descriptions, class names, document contents,
URLs or titles.

## Evidence limits and next steps

Unit tests cover negative signals, ordinary-field controls, zero dispatch through
VerifiedAction, and all pinned Undo transports. They do not execute real AX reads.
Native candidate testing must cover browser proxy-marked disposable fields with
compatibility on/off, marker drift before write/Undo, and normal native/browser
positive controls. Unmarked custom editors are not thereby certified. Reliable
virtualized-editor support requires an editor-aware, versioned document/range
transaction with explicit cursor scope, not a broader host allowlist.
