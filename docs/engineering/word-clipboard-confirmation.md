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


## Focus refusal evidence follow-up

544cf15 representative regression passed TextEdit/Chrome/Safari/Vivaldi but refused two Word attempts before writing (focusedElementChanged) and one Capy input-stage focus loss (AX noValue). The fresh hands-off Word control and Capy sequence excluded host observation during generation/input as a sufficient explanation. No automatic retry or delivery-as-pass follows.

Diagnostic-only follow-up records the refusal site (observer, target anchor, editable-host resolution), existing focused-element read classification, and own panel key/app-active/activation-requested booleans. Panel ownership is sampled at refusal, not inferred from foreground app. The callback reads only own AppKit properties: no new AX reads, target text, IDs, URLs, selection values, focus changes, or mutation permissions. Earlier refusal evidence is retained instead of replaced by a later refusal; next capture resets it. ActivationRequested describes this presentation's request, not its success. All observer invalidation, exact-anchor validation, error mapping and handoff behavior remain unchanged. These fields diagnose a possible presentation-ownership conflict; they do not authorize ignoring a missing/different target or accepting it later.

An editableHost refusal with no focus outcome means resolution was unavailable, not that a different identity was observed. Only an actually resolved unequal host is labeled differentAnchor; the original refusal/error and read count are unchanged.

The report's separate `lastCaptureFocusObservation` is historical evidence from the actual observer invalidation event, independent of the current error/generation state. It allows capture-only diagnostics without a model request, and may remain visible after cancel. It resets at the next capture attempt, never represents current target validity, and is stored separately from first-refusal evidence. It excludes Undo/capture-read fields. Actual refusal attachment now carries the new closed fields only when its current error and failure reason match the recorded validation site.


## Preset-only non-key presentation

The activation-removal experiment is NOT included: a CUA-free control routed synthetic q/a into the disposable host instead of the instruction field. CUA observation had activated Imrse in the earlier apparent success. Original explicit activation is retained for manual input.

A separate concrete defect exists in direct preset invocation: it presented an unused key input panel before immediately submitting the preset. The bounded fix captures exactly as before, initializes/submits the explicit preset synchronously, then presents only its visible processing/failure phase. Unknown or vanished preset refuses; manual instruction input is unchanged. No observer or target proof is bypassed. New tests first reproduced input-key presentation, then cover one provider/write dispatch, reused success/failure presentation, route failure, cancel before provider starts, and pre-write target/security refusal. Native direct-preset qualification remains required; custom-input focus loss is unresolved.
