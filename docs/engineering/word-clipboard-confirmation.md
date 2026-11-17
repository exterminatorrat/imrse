# Word clipboard confirmation investigation

On candidate 9c46676, one disposable Word grammar replacement visibly changed
25 UTF-16 units to the expected 24-unit sentence. The retained report said
`generation: failed`, `replacementOutcome: unconfirmed`, `clipboardPending`,
`selectedTextLengthMismatch`, and clipboard write attempt. A subsequent attempt
to select the menu Undo action was initially called an Undo failure, but there
was no pre-Undo successful receipt or enabled-state observation. The menu was
later verified disabled. Engine Undo does not set this forward outcome: the
observed failure is forward confirmation, not proven inverse dispatch/failure.
Later read-only Word AX value, selected text and range coherently matched the
24-unit output. No second paste/generation/Undo was attempted after uncertainty.

## Narrow change

The existing 500ms post-paste confirmation loop previously waited only for nil
(not-yet-matching) reads. A thrown range/text length inconsistency immediately
ended the window. The new helper permits only a fresh
`selectedTextLengthMismatch` paired with the two existing selection-reader error
codes to become a pending read within that same budget. Failure reason is reset
before each sample so old diagnostics cannot classify unrelated errors. No
pasteboard staging, key event, retry mutation or alternate route is added.

Every confirmation still requires the same destination process identity,
foreground, supported/nonsecure field, document/window binding, exact expected
whole value, exact replacement/collapsed-caret selection, and second coherent
selection. Other failures stop immediately. Preflight and pending recovery remain
strict. Reads taking longer than the deadline cannot publish success. Persistent
mismatch remains unconfirmed and keeps the staged clipboard until existing
consumption/termination and ownership proof permits restoration.

This addresses a source-level premature-confirmation-abort mechanism consistent
with the observation. Native candidate repeat testing is still required before
claiming the Word failure resolved. It is not proof that every delayed Word write
can be safely confirmed, nor a universal paste or Undo guarantee.

## 404d4bb native result and next diagnostic checkpoint

The first Word repeat on 404d4bb again produced correct visible text but failed
forward confirmation before any Undo, now with `axReadFailure`. A Word paste
onboarding popover was observed; causation is not established. Later read-only
AX observations were coherent (expected value, collapsed end caret, same focused
text area). The narrow snapshot fix is therefore not sufficient qualification.
No generic AX error retry or success-proof relaxation has been added.

The next diagnostic source attaches only closed confirmation phase, read
operation/attribute category, AX status classification, bounded sample count and
elapsed milliseconds to the existing write-attempt report. It records only
existing failure sites, adds no AX probes, and retains no content/URLs/window
names/PIDs. Each sample and phase clears stale read metadata; only an actual
thrown axReadFailure can publish read evidence. The confirmation context is
cleared in defer and the engine snapshots the report before target cleanup.
Bookkeeping has CPU cost but read/retry/mutation policy remains unchanged.

## Recovery-only backend API (no new UI)

`MacSelectionAccess.recoverClipboardIfSafe()` now exposes the same existing
recovery preflight without requiring a new replacement or Undo. It reports only
`notNeeded` or `restoredClipboardBackup`; uncertainty/active paste/ownership loss
still throws and retains the pending transaction. It never posts keys, captures
new text, generates output, creates an Undo receipt, or changes an editor.
For a dispatched unconfirmed paste, exact consumption or original-process
termination proof is still mandatory. Never-dispatched or already-confirmed
transactions retain the existing restoration-only policy. Pasteboard ownership
is always required. It does not force quit applications, close documents, restore
focus or overwrite a later user copy. Existing replacement/Undo calls reuse this
same method. There is no new app action/UI wiring yet; future caller must request
this action explicitly and report failures truthfully. No claim that the original
paste succeeded follows solely from restoration via termination.
A later explicit recovery request may retry restoration after an earlier
restoration failure only if the unchanged proof and ownership gates still pass.
This is not a retry of the paste or source edit. No automatic recovery loop is
introduced.
