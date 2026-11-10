# Cross-app text editing: agent continuation and completion order

## Active delivery goal — 2026-11-10

Finish Harry's reported failures: imrse must capture the actual selected text, apply the generated result in that original field, insert at an explicitly requested caret, and handle configured provider requests and failures correctly. Deliver one combined test application built from all intended source corrections so Harry can test it across applications. Source changes, static checks, compiled tests, delivered artifacts and user acceptance are separate milestones; none substitutes for the next.

Keep this finite delivery loop active until completion or a concrete access, safety or product decision blocks it:

1. Fix remaining demonstrated selection, replacement, insertion and provider defects in source, with focused regressions. Continue independent source work while an execution dependency is blocked.
2. Reconcile the relevant PRs into one exact-source candidate, run the focused tests and required CI, and fix real failures without weakening coverage or identity/content/Undo guards.
3. Build and verify the matching combined test application, preserve the persistent permission identity, and give Harry the application with its source identity and honest remaining compatibility limits.
4. Wait for Harry to test that exact application. If he reports a failure, diagnose it and return to the source fix; do not call the delivery complete or silently substitute a newer artifact.
5. After Harry confirms that testing is good, merge the relevant reviewed PRs with passing required checks and a clean merge state. Deferred preview UI PRs and unrelated work are not part of this delivery.

Runner setup, new build-controller projects, broad optimization and unrelated cleanup are out of scope. Supporting work is justified only when it directly removes a demonstrated blocker to a fix, required verification or the test build. Existing execution, privacy, permission, source-continuity and resource-safety boundaries remain in force; name an actual blocker instead of replacing this goal with more tooling.

## Goal and current boundary

Harry's goal is that imrse works across ordinary text fields, not merely that Undo is repaired. Selected replacement in the original field is primary. Explicit caret insertion is a separate intent and milestone. Preserve the existing instruction/preset → generation → direct Apply interaction.

ELV-1 owns delivery, ELV-16 owns focused-anchor/editable-host binding and contenteditable support, and ELV-17 owns explicit caret insertion. Their current issue descriptions define acceptance gates. Historical HEH/IMRS identifiers in [the implementation plan](text-editing-implementation-plan.md) are provenance, not additional completed milestones. Update the issues when evidence changes; do not infer completion from this document.

As of 2026-11-08, [PR #30](https://github.com/exterminatorrat/imrse/pull/30) is an installed acceptance candidate, **not live-ready**. Source `495cdb8b4541ff65a6b51de6ba9f2a09d12a01bd` contains the packaging-validator correction; the compiled application source remains `725bfebbd1e79d142a7f56fb55a64c3f31a1e4e8`, with separately bound validator provenance. Passing hosted checks and packaging do not close the editing gates below.

Later source binds both editing intents to the same-process window and optional exact private document identity. It also snapshots flat font-dictionary CFBoolean leaves by their own type and value, reconstructing true/false without treating numeric 0/1 as Boolean.

**Focused source qualification, 2026-11-08:** Exact source `f391c1815ddbbe41feeaf5d80a510ca76799aab4` / tree `1c16fa2ef9f5145b18795f9f74740bcd37c5bbd2` compiled in a dependency-free package containing the real ImrseCore/ImrseMac modules and two focused suites. Swift 6.4 / SDK 27 with warnings-as-errors passed 30 XCTest tests in MacSelectionAccessSelectionTests and 22 Swift Testing tests in ContenteditableTextStyleProofTests, with zero failures or skips. The latter includes two two-case Boolean parameterized tests. Independent whole-slot closure completed at 19:26:49Z with recorded processes/groups absent, exact empty lock returned and protected source/apps/rollback/OFF configuration preserved. This qualifies only those exact-source modules and helper regressions, not a full application build, installed artifact, native field editing or a new live support row. Documentation updates do not rebind that tested source identity.

The latest rich attempt stopped during baseline style representation on a nested CFBoolean, before product capture or generation. Its enclosing style key was not recorded, so it does not establish a font-trait diagnosis or a product editing failure. The source-only harness successor admits Boolean leaves only inside flat AXFont dictionaries and retains exact tagged equality; its mocked regressions pass. Rich qualification still needs a matching new-source artifact, matching harness profile and a fresh finite native grant, not another replay against the old candidate.

The textarea attempt reached the generation-attempt marker, then returned `PillTargetingFailure` at guarded Apply. Its old report lost the exact refusal reason. That marker is written before `apply_instruction`; neither model dispatch nor a native press, replacement or Undo was proved for that case. The uncertain case must not be replayed.

A distinct, separately admitted simple-contenteditable case passed on 2026-11-08: configured-local generation and direct Apply changed the captured original field and retained editor model, and one genuine product receipt Undo restored both. Trusted input counts were exactly 0 before Apply, 1 after Apply and 2 after Undo. The owned fixture closed, exact OFF configuration was restored, and whole-slot closure was independently verified at 13:49:35Z. This proves that bounded selected-replacement profile on the installed candidate, not arbitrary contenteditable, rich style, caret insertion or the lifecycle matrix. The actual transport was not separately recorded. The old textarea refusal remains unexplained; simple success rules out a universal Apply blockage but does not diagnose the textarea-specific failure.

## Execution order

### 1. Diagnose and resolve the guarded Apply blocker

Use a fresh, separately authorized one-shot synthetic case. Retain the exact typed pill stage/reason, attempted flag, sanitized state and bounded adapter counters, without recording exception text, field contents or configuration. Distinguish permit/scope/reference/readback/budget refusal in the diagnostic adapter from a dispatched action and a product refusal. Establish the first wrong state before changing product behavior.

The pure budget probe demonstrates a harness possibility, not the old live cause: a four-node pill uses 107 mocked messages; a valid 127-node prefilled tree reaches the Apply scope rebuild and exhausts the 512-call budget before mocked dispatch. An empty large tree fails earlier during instruction readback. These are simulated calls/timings, not native measurements. Do not raise budgets, relax ownership or assume this explains the textarea result.

Fix only the demonstrated mechanism, add the nearest focused regression and rerun it. If the fix changes the app, bind a new exact-source artifact before live qualification. If it changes only the harness, preserve app identity and document that distinction. Unknown mutation outcomes never permit another transport, blind rollback or retry.

**Exit:** authentic refusal evidence identifies the mechanism, the scoped fix passes its regression, and a fresh authorized case proves configured generation and direct Apply into its captured original field. This gate alone does not establish the field matrix or Undo.

### 2. Prove selected replacement and receipt Undo across the required field profiles

Qualify the exact delivered candidate in native plain and rich fields, ordinary browser input/textarea, simple contenteditable and the bounded rich contenteditable profile. For every supported row, prove original-field capture, instruction/preset, configured provider generation, direct Apply, whole-field confirmation and genuine product receipt Undo. Record the actual transport; setter success, event delivery and clipboard consumption are not edit acceptance.

Browser editors also require independent retained editor-model persistence through the declared rerender/node-recreation check, not only a changed AX value. Native and browser evidence are separate. A previous source's passing row is historical evidence, not current-candidate acceptance.

Rich qualification requires a nonempty selected range away from the collapsed origin, exact marker/leaf/display coordinate mapping and full frozen font/color/annotation preservation before/after Apply and Undo. The retained fixture has 81 displayed UTF-16 units versus 79 leaf/marker units; canonical separator boundaries are 22 and 57, while the raw second display LF is at 58. The read-only collapsed-range observation does not prove a nonempty marker bridge. Preserve the bounded tree/style profile and refuse unsupported separator crossings or multiline replacements; do not normalize away real newlines or weaken style proof.

**Exit:** each required supported profile has exact-source positive replacement, persisted result and verified inverse evidence. Keep unproved rows open rather than calling a safe refusal a working common field.

### 3. Close lifecycle, stale-target and recovery failures

Prove later-edit Undo refusal preserves external edits, including changes in or near the replacement. Test wrong-target, focus, selection, document and host drift; adjacent same-text editors and recreated hosts must not rebind a capture by resemblance. Include repeated clean sessions and relaunch/rerender behavior without replaying uncertain writes.

Exercise precommit Cancel with delayed provider completion and confirm no late write. Once a write crosses the commit boundary, report its actual settled outcome rather than pretending Cancel reversed it. Verify receipt single-use/staleness and cleanup after provider failure. Existing engine fakes and policy tests are useful regressions, not native lifecycle acceptance.

**Exit:** current-source positive and refusal cases preserve the right field, external edits and recovery state, with no late or duplicate mutation and no success receipt from uncertainty.

### 4. Implement demonstrated host/editor gaps under ELV-16

Current capture binds the focused AX node, not a general focus-anchor/editable-host pair (`MacSelectionAccess.swift`, `TargetHandle` and `capture(intent:)`). Current rich eligibility requires the focused `AXTextArea` itself to be its editable and highest-editable ancestor, with a supported direct static child. Those are real capability boundaries, not proof that every editor needs a bridge.

For a demonstrated required-field failure, first identify whether capture lacks range/text, the focused anchor differs from its editable host, the host/document changed, or the write/readback proof is unavailable. Implement a bounded, same-process, parent-linked resolver only for the evidenced relationship. Bind anchor and host independently through validation, commit and Undo; preserve secure/read-only, cycle, foreign-node and ambiguity refusals. Add pure relationship/identity regressions and then native evidence for that profile.

Do not add an app-name registry, broad document search, speculative host rebinding or a new plugin framework. If AX cannot provide the required model/version/transaction proof, record the concrete missing capability and propose the smallest cooperating browser/editor adapter. Installation, live bridge use and added access require separate consent.

**Exit:** the demonstrated common-editor gaps are implemented and qualified, or a concrete capability limit and a consent-gated alternative are recorded. A limit must not silently redefine a required workflow as complete.

### 5. Qualify explicit caret insertion under ELV-17

Keep replacement as the default intent; never infer insertion from an empty or failed selection. The separate Command-Control-Shift-I route already supplies explicit intent through the existing pill. Its current native path is limited to plain-write-eligible `AXTextField`, with same-window identity, bounded whole value, a scalar-aligned collapsed range and explicit unmarked-composition evidence. It is not universal `AXTextArea` or contenteditable insertion.

Test explicit activation/instruction, blank instruction refusal, shortcut collisions, empty/start/middle/end carets, Unicode and composition refusal. Observe the actual postwrite selection; do not substitute the helper test's constructed end-caret for native evidence. Prove persisted insertion, receipt-bound inverse and preservation of later document edits. Extend profiles only with their own identity/content/composition/inverse proof.

**Exit:** the declared insertion profiles work through the real activation route and Undo, with other profiles honestly classified. ELV-17 being in review is not runtime acceptance or parent completion.

### 6. Deliver a reliable artifact and an honest compatibility matrix

Finish provider failure/cancellation/cleanup and permission-loss cases. Qualify clipboard fallback with the preference off and scoped on, ownership loss, delayed consumption and pending recovery. It defaults off: a temporary on-test is not a daily setting change. Never inspect a personal clipboard or overwrite a foreign owner. Preserve unresolved recovery until consumption or the existing exact-destination termination rule permits settlement. The 4 MiB backup limit is not a hard pre-materialization memory bound for `NSPasteboard` representations.

Bind source/tree, dependency pins, compiler and validator identities, resources/licenses, signed artifact, test-copy inventory, rollback and CI to the delivered candidate. Preserve one stable permission-bearing identity; verify actual authorization and editing capability separately. Packaging or full-build work supports the editing fix and must not replace it as the foreground task.

For each fixture/profile, record source/artifact, intent, actual transport, before/after and model evidence, receipt/Undo, lifecycle safety and closure. Use distinct statuses: supported, safely refused, unsupported, paused and untested. Keep private text, raw AX/style dumps, document paths and configuration out of published evidence. WeChat stays paused.

**Exit:** ELV-1 has a usable packaged build and evidence-backed declared capability matrix covering its required workflows. No universal-app promise, merge, release or permission expansion follows automatically; those actions retain their own authorization gates.

## Continue useful work while native execution is reserved elsewhere

Do not make the entire project wait for a shared Mac slot. Continue issue-scoped source implementation for demonstrated defects, nearest pure/mock regressions, exact-diff review, acceptance-driver privacy/one-shot checks and documentation. Publish coherent source checkpoints to the existing focused PR under the standing development authority; label unrun checks and do not silently rebind an installed artifact to newer source.

Dependent work stays sequential: an unknown live refusal needs discriminating evidence before its product fix, and a new host profile needs evidence before broadening capability. Independent source tasks may run in parallel with disjoint file ownership. Do not invent speculative changes or extra audits merely to appear active.

Before native work, obtain a fresh finite coordinator handoff, then validate the pinned source/artifact/manifest/signer/rollback/configuration, exact owned fixture, lock and resource admission, one-shot tokens and cleanup reserve. A queued diagnostic is not an active grant. Never infer ownership from wall time or another task's closure; do not sample resources, compile, launch, mutate or clean during another owner's exclusive execution.

After an uncertain action, preserve that root and stop its case. Close only owned synthetic scope, settle recovery, restore exact configuration bytes and independently establish holder/group/candidate/model/compiler absence, lock reacquisition/release and protected identities before releasing the whole slot. Cleanup is not permission to delete retained products, source, models, signatures, rollback or evidence.

Report completions and real blockers, not every passed check. Keep ELV-1/ELV-16/ELV-17 and PR #30 aligned with concrete evidence. Do not mark a milestone done, ready or universally supported because CI is green, an app launched or an unsupported field refused safely.
