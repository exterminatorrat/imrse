# Narrow Chrome candidate

The signed b13489b candidate reproduced a native acknowledged no-op in Chrome
with compatibility editing enabled: com.google.Chrome / AXTextField,
selectedText accepted, readback original, replacement unconfirmed with
replacementEvidenceMismatch. The field remained unchanged; no paste retry ran.

Read-only fixture ancestry was AXTextField -> AXGroup -> AXWebArea ->
AXScrollArea -> AXGroups -> AXWindow -> AXApplication under Chrome. Textarea
and contenteditable fixtures exposed AXTextArea. This supports testing the same
bounded opt-in route used in Safari/Vivaldi/Capy, not all Chromium apps or all
web fields.

This candidate adds exactly com.google.Chrome to the existing qualifier. All
other requirements remain: opt-in enabled, selected replacement intent,
AXTextField/AXTextArea, bounded same-process/window WebArea ancestry, full
clipboard eligibility, foreground/selection/value/style proof, permission and
ownership checks, confirmed readback, and receipt-pinned inverse. Beta/Canary,
Chromium and other bundles remain unqualified; browser chrome outside WebArea
and secure fields remain excluded. No focus safety relaxation or second write.

Release qualification is pending. Required checks: deterministic input,
textarea, contenteditable edits plus exact receipt Undo, Unicode/partial ranges,
opt-out no-op control, cancellation/focus drift/stale edit safety, clipboard
restoration; repeat existing hosts to check no regression. Do not interpret
candidate membership alone as verified host reliability.
