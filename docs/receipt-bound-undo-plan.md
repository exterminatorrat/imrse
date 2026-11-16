# Receipt-bound inverse transport

## Problem and evidence

The 70ab5da Release passed real edits and receipt Undo in Safari, Vivaldi,
Capy, and TextEdit. Turning clipboard editing off before Undo now refuses
without a text write and retains the receipt; re-enabling restores via normal
validation. This is verified behavior, not a universal guarantee.

A separate code-level gap remains: Undo selected a helper from current field
shape, and generic Undo asked the forward chooser to choose again. Thus a
clipboard receipt could reach a native setter if an AXTextField satisfied the
plain-value heuristic, or if WebArea qualification was unavailable on the
inverse. This is structurally possible in current host variants/capability drift;
it was not reproduced in the tested fixtures. It is not merely a future host
allowlist issue.

## Design

- A successful forward edit binds the inverse transport to its receipt strategy.
  UndoWritePlan is the production dispatcher, with one terminal route.
- Clipboard receipts invoke clipboard inverse only. Structured content keeps
  its inverse style proof. Plain fields use the existing complete paste
  transaction, not a new simplified event path.
- Original/applied whole values are retained privately in UndoTarget for
  clipboard and value-range edits. Undo requires exact UTF-16 applied-value
  equality, including text outside the edited selection. Values are not logged
  or serialized into diagnostics. Receipt disposal releases this proof.
- Native selected-text inverses remain selected-text; a collapsed caret may be
  reselected only after confirming the exact inserted range. Native value-range
  inverses remain value-range and require original/applied whole-value proof.
- Current capability checks may refuse a pinned route, never choose another.
  Accepted-but-unconfirmed text writes are terminal; no native-to-paste retry.
- Opt-out still refuses before receipt consumption or adapter side effects.
  Reenable permits an ordinary validated attempt, not guaranteed Undo.

## Verification plan

1. Production dispatcher tests: each receipt calls only its route; preflight
   rejection and ambiguous mutation never invoke another; cancellation invokes
   none. Proof tests reject changed surrounding text and Unicode normalization.
2. Existing Core/Mac suites, full app suite (report known Vision OCR test
   separately), packaging checks, independent safety review.
3. New isolated candidate, never alter in-use/installed app. Repeat clipboard
   edits and Undo in Safari/Vivaldi/Capy, native TextEdit selection/collapsed
   caret/insertion inverses; opt-out/re-enable, changed focus, cancel, stale value.
4. Adversarial capability-drift coverage must use injected adapter capabilities
   or dedicated fixtures. Route helper tests alone do not prove OS behavior.

## Limits

macOS accessibility and event delivery are not atomic; the existing final checks
and ownership recovery narrow but cannot eliminate OS races. A missing pinned
capability should reduce availability, not authorize a speculative alternative.
Broader support still requires host/field qualification and measured regression
coverage. No claim of a secure guaranteed universal mutation mechanism is made.

## Review corrections

Independent review required cancellation after asynchronous range selection and
retention of full-value proof even when native field capabilities change. Final
native text setters now check cancellation; generic inverses carry the original
applied-value requirement and refuse if the required capability disappears.
Clipboard opt-in is rechecked on transaction entry, before staging, and at final
verification. No suspension occurs between the final check and event posting.
Range selection may occur before a subsequent refusal, but refusal does not
authorize a text write. Independent re-review found no remaining blocking source
finding; native candidate validation remains a separate qualification step.
