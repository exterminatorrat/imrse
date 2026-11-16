# Replacement reliability candidate 1

## Evidence and scope

Baseline: executable 98c7f498b71ea50d3fd52722880e60c6d044daa3023485d3acf79390f939de6c, source 798566a8. Eight attributable live trials included successful native TextEdit selected replacement and receipt Undo, and unconfirmed replacement evidence mismatches in Vivaldi input/textarea/contenteditable, Capy composer, and Safari input. Capy remained unchanged after approximately 15 seconds. These are not repeatability statistics. One wrong-host trial was discarded. Clipboard fallback was off.

Candidate base: 48680121, retaining the subsequent focus diagnostic corrections. No focus safety relaxation is included: the reproduced current blocker occurs after native mutation dispatch, whereas historical focus-loss is a separate issue.

## Changes

- Report attempted write strategy, setter acknowledgment and content-free readback category even when no successful receipt exists.
- With the existing clipboard option explicitly enabled, route tested bundle IDs and selected text fields with verified same-process/same-window web-area ancestry directly into the existing guarded clipboard transaction. Preserve its full eligibility, style, selection, baseline, destination, pasteboard ownership, delayed confirmation and recovery checks.
- Unknown hosts, non-web fields, insertion and disabled clipboard option retain native route selection.
- Never issue a paste following an acknowledged native write that merely looks unchanged. That evidence cannot exclude a delayed native mutation.

## Qualification plan

1. Run Core/Mac and application tests, plus packaging checks. Record source and binary identity.
2. Use separate disposable fields with clipboard off, then on. Restore the original setting afterward. Check exact target identity and selection before every activation.
3. Record capture, generation, attempted strategy, result and exact readback separately. For critical passing flows, repeat at least 20 times before labeling reliable.
4. Test partial selection, surrounding text, multiline and Unicode, native receipt Undo and host Undo separately.
5. Test switched field/app/window, changed selection/content, cancellation, unsupported/rich/secure targets, pasteboard change and late confirmation. No duplicate writes or wrong-field mutations are acceptable.
6. Never send host AI prompts. Only disposable composer text may be edited; restore prior composer state.

## Follow-up, not claimed implemented

Bounded read-only AX confirmation may improve asynchronous hosts, but cannot solve a persistent setter no-op by itself. An owned-focus-handoff suspension must retain the immutable original target and revalidate it strictly, and needs independent focus-loss reproduction first. Neither this candidate nor any finite matrix establishes universal host support.

## Candidate 2 refinement

The Debug candidate demonstrated clipboard-enabled successful replacements in the tested Vivaldi input, textarea and contenteditable, Capy composer, and Safari input. Verified receipt Undo passed for the tested Vivaldi/Capy flows. Native TextEdit remained functional. A strict clipboard-disabled Vivaldi control remained unchanged with accepted AX setter/original readback evidence. Cancellation and a different-field transition refused without altering the disposable fields. These bounded trials are not statistical reliability claims.

Follow-up changes select one production write plan with lazy capability probes, and describe the opt-in as compatible clipboard editing rather than post-failure fallback. A newly observed setting-change edge case is handled explicitly: a clipboard receipt cannot be undone while clipboard editing is disabled. This is refused before mutation, and the engine preserves the receipt so enabling the setting permits a fresh, fully validated Undo attempt. Enabling does not override stale-target or changed-content checks.

One existing Vision OCR-backed panel test fails on this Mac with e5rt error 13. This remains a disclosed test-environment verification gap; it was not weakened or deleted to obtain a green result.
