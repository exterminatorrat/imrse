# Capture-only focus evidence

A TextEdit `focusedElementUnavailable` refusal occurred after a candidate
restart. Other hosts captured successfully; a later launch captured TextEdit.
The failing and succeeding launches were different executables, and observations
were not timestamp-granular enough to establish causality. A separate automation
confound was reproduced: targeting a TextEdit window through CUA could leave
Chrome frontmost even though a TextEdit selection snapshot existed. Explicit
foreground verification is therefore required in native testing. This does not
fully explain the earlier failures.

The capture path already warms the application role/manual accessibility and
retries nil focused-element reads within a one-second budget. `elementAttribute`
previously collapsed AX attributeUnsupported and noValue to nil, while errors
threw. Increasing delays, guessing another element or relaxing focus identity
is not justified by current evidence.

This patch observes statuses from exactly those existing focused-element reads:
first/last closed classification, attempts capped at128, and retry-budget-ended.
Foreground is deliberately omitted to avoid even an additional failure-time
NSWorkspace snapshot: this instrument strictly observes existing reads only. No text, process IDs,
window titles, URLs, raw AX payloads or tokens are serialized. Evidence is only
attached to matching failed captures and resets at the next capture. A missing
record means no observed focused-element read; it is not a success claim.

No mutation route, focus behavior, AX read count, blocking delay or capture
budget is changed. Broader compatibility still needs independent host/field
qualification. The purpose is to resolve the cause of the next refusal, not to
claim the transient failure is fixed.
