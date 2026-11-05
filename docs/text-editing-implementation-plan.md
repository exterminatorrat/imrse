# Reliable original-field editing: implementation plan

## Approval, ownership and delivery boundary

Harry approved implementation on 2026-11-05: implement the architecture, evidence-supported contenteditable support and a distinct caret-insertion contract, using a bounded goal loop through tests and declared-capability acceptance. HEH-1 remains the parent delivery issue; HEH-15 owns foundations, HEH-16 owns identity/discovery/contenteditable, and HEH-17 owns explicit caret insertion. IMRS-16 coordinates integration and owns source, PRs, runtime provenance and acceptance.

Preserve direct Apply: generate a completed result and replace in the original field. Do not introduce Preview/Replace/Discard, deferred UI PR18/19, a plugin framework or an app-name exception registry. WeChat live work remains paused. Copy capture, browser/editor bridges, helpers/extensions and new access require a concrete evidence-backed choice and their own privacy/access consent before activation. Never inspect a personal clipboard. No merge authority is included.

All live work is synthetic-only on the authorized Mini test copy, with the canonical app identifier, verified stable signer, protected original and retained exact rollback. Fresh finite actual native-lock intervals and actual closure are required for every native phase. Source work and pure fixtures proceed independently of packaging waits.

## Starting source and evidence

The dependency is open/unmerged PR22 at b5d4aa49709d85b7d85ad921c4e8142d02a0f1dc. Its composed compatibility build dc4d46bf02375ff7424184e8f3e87d63453d4441 passed hosted verification and bounded Mini rich/plain replacement, product Undo, later-edit preservation, Cancel and changed-field refusal. The later foundation's source-specific browser/native evidence is recorded below; keep those source identities separate from earlier guarded-paste observations and from the new, unaccepted contenteditable layer.

Source seams:
- Capture and initial evidence: Sources/ImrseMac/MacSelectionAccess.swift:104–191.
- Exact focused-target validation and selection reread: the same file:584–629.
- Focus notification identity confirmation: :504–524.
- SelectedText/valueRange/clipboard routing and confirmation: :742–992.
- Structural clipboard refusal: Sources/ImrseMac/MacSelectionValidation.swift:301–337.
- Clipboard ownership/recovery: Sources/ImrseMac/ClipboardPasteboardTransaction.swift.
- Public snapshot/receipt/adapter contract: Sources/ImrseCore/Contracts.swift:95–125.
- Generation, preparation, cancellation and commit boundary: Sources/ImrseCore/TransformationEngine.swift:196–254; empty-selection rejection:356–367.

The proved problems are distinct: a focus callback falsely invalidated the tested rich target (bounded repair now accepted); capturable Vivaldi contenteditable fails a conservative tree gate; native-only browser setters can return contradictory/no-op evidence; an inaccessible editor lacks usable capture. None establishes WeChat's cause or universal API coverage.

## Caller contract and state ownership

### Current implementation evidence

M1 / HEH-15 is complete at PR23 `5815f0a7`, tested as exact compatibility composition `b9d561a4`. Hosted verification and independently validated, existing-identity Mini test-copy installation passed. Plain/rich selected replacement, product Undo, later-edit refusal, Cancel, changed-field refusal and fallback-enabled Vivaldi input/textarea replacement/Undo were observed on that source. Browser transport was not separately recorded. PR22/23 remain unmerged.

The next source layer implements a narrower M2/M3 profile, not a general host search. The observed contenteditable is already the focused `AXTextArea`; the adapter must keep that exact binding through validation, commit and Undo. A separate helper recognizes only one direct, childless `AXStaticText`, leaving legacy tree admission unchanged. Candidate admission additionally requires an enabled root and both `AXEditableAncestor` and `AXHighestEditableAncestor` resolving by identity to that same root in the same PID. Advertised names alone do not establish those relationships.

The new clipboard profile requires a frozen, bounded whole-value attributed proof before staging the clipboard. The full value is limited to 65,536 UTF-16 units with one uniform run and only `AXFont`, `AXForegroundColor` and optional `AXBackgroundColor`; font and foreground are required. Supported style values are bounded strings, immutable colors and bounded flat font dictionaries, not arbitrary recursive object graphs. Missing, mixed, unknown or oversized evidence refuses. The selected span must match exactly at scalar-safe UTF-16 boundaries. Expected result text and attributes are independently confirmed before a receipt is returned, and private Undo evidence requires the exact expected full state before the inverse and exact original state afterward. Public Core receipts and `SelectionAccess` remain unchanged.

Clipboard consumption and edit acceptance are separate proofs. Existing exact textual consumption evidence can settle ownership-safe clipboard restoration even if subsequent style confirmation fails. That failure still invalidates the uncertain edit, returns no success/Undo receipt and permits no other transport; it must not trap a consumed clipboard transaction indefinitely merely because formatting is unconfirmed.

The retained authority is a closed value snapshot, not a retained `NSAttributedString`: Foundation can cache and reuse equal attribute dictionaries that still reference caller-owned mutable values. Text, style strings and raw font keys use owned UTF-16 units; bounded flat font entries retain value snapshots, and colors retain validated immutable values. Numeric snapshots must round-trip without loss. Confirmation and inverse construction consume this frozen authority directly; computed attributed strings are compatibility views only and never establish commit or Undo authority.

This profile is not yet live-accepted. A trusted, exact-owned-URL read-only observation established a direct-static root, valid range/text/value, parameterized span match and available uniform attributed selection; it did not establish editable-ancestor identity, full-value style admission, model persistence or an inverse. A later short Safari follow-up missed its explicit closure deadline, so its observations are not promoted as a completed bounded acceptance phase. Future native batches require fresh coordination, admission-time reserves and off-state/actual closure in the same executing program. Arbitrary rich HTML/markup, mixed styles, opaque editors and caret insertion remain unsupported or unfinished; WeChat remains paused.

The application invokes the engine with an explicit editing intent. The engine captures once, owns generation/cancellation and asks the adapter to commit the completed result. It does not select AX versus paste, rediscover fields, infer intent from a failed capture, or reconstruct targets from diagnostics.

M1 keeps the public SelectionAccess protocol stable. M3/M4 may add a source-compatible explicit intent entry point: SelectionEditIntent.replaceSelection and .insertAtCaret; invoke(intent:) defaults to selected replacement, and capture(intent:) binds the same intent into the snapshot/lease. Existing callers and test doubles migrate deliberately; no default may interpret empty selection as insertion. The exact public shape is introduced only with its consumers, not as dormant fields in M1.

ImrseMac remains the sole owner of AX handles, target leases, strategy evidence, pending recovery and inverse validation. ImrseCore contains only portable value contracts, operation state and the latest verified receipt. ImrseApp maps an explicit invocation to the engine and renders existing states. Platform objects do not escape into Core or Sendable payloads.

### Concrete M1 internal seam

Add Sources/ImrseMac/SelectionTransaction.swift with:
- SelectionWriteCapabilities(selectedTextSettable: Bool, permitsWholeValueWrite: Bool, clipboardFallbackEnabled: Bool).
- canConsider(_ strategy: ReplacementStrategy) returning candidate eligibility only. True is never a target, editability, result or inverse proof; later checks still run.
- SelectionMutationOutcome<Applied>: confirmedApplied(Applied), provedNotApplied, indeterminate(SelectionFailureReason).
- allowsFallback true only for provedNotApplied.

Use these in the real adapter path. A skipped unsupported strategy has issued no mutation. A selectedText attempt returns confirmed-applied only after existing readback; a proved no-op requires unchanged target selection and validated whole-value baseline; a rejected write, missing readback or contradictory result is indeterminate unless additional evidence positively proves no mutation. No alternative transport follows indeterminate. Preserve existing diagnostics and conservative invalidation; do not convert an AX status code or pasteboard change count into commit proof.

The typed outcome must replace an actual routing ambiguity, not decorate a Boolean with unused cases. Keep the original provider/operation/Cancel boundary. Retain current successful selectedText, valueRange and opted-in clipboard behavior, including the existing rule that a verified selectedText no-op goes to guarded paste rather than introducing an unproved new whole-value write.

### Invariants across every milestone

1. A capture belongs to one operation, process, focused anchor, editable host and intent. Similar text/role/position cannot rebind it.
2. Selected replacement requires a valid nonempty UTF-16 range and matching selected text. Caret insertion requires an explicitly requested valid collapsed range and its own context/inverse proof.
3. Secure input and protected ancestors fail closed before capture or mutation. Known readonly is not equivalent to unsettable selectedText.
4. Every write revalidates process/foreground/focus/host relationship, intent, range, original content and backend-specific document evidence immediately before the action.
5. A verified receipt is minted only after independent result confirmation. Setter success, event delivery and clipboard ownership are insufficient.
6. Only proved-not-applied can advance to another transport. Unknown writes stop; no blind retry, blind rollback or blind Command-Z.
7. Cancel before the commit boundary invalidates operation identity, so delayed provider output cannot apply. Once a write is issued, settling/recovery outranks pretending cancellation erased it.
8. Undo validates the exact receipt, target, inserted/replacement range and expected post-write evidence. A conflicting later edit invalidates the inverse rather than being overwritten.
9. One adapter owns unresolved recovery. New mutations cannot bypass it; failure/discard must not accidentally erase the state needed to protect clipboard ownership or settle an edit.
10. Diagnostics contain closed stages/reasons and bounded metadata only, never text, clipboard data, raw AX error payloads, private window titles or document paths.

## Capture, focused anchor and editable host

Current capture resolves one focused element and later insists it is still focused. Text-read fallbacks are not discovery. First preserve this behavior while classifying missing focus, missing/empty range, missing text, AX read/type error, changed focused identity and unavailable confirmation separately.

If a synthetic case demonstrates a focused leaf distinct from the real editable host, introduce a private TargetBinding containing the focused anchor, resolved host and a validated relationship, alongside existing process/application/snapshot identity. Use one bounded resolver for capture, validation, observer relevance, mutation and Undo. Search only the invocation's focused subtree/explicit ancestor relationship within fixed node/depth/time limits. Ambiguous editors, cycles, unsupported relationships, recreated hosts and out-of-budget reads refuse. Never scan unrelated application text or select by string similarity.

Capabilities are evidence captured at a stage, not permanent facts inferred from an app name. Recheck mutable evidence at commit. The adapter may learn selection-read, candidate-write, result-read and inverse capabilities independently; observer support is best effort and never replaces the final checks. Do not relax CFEqual identity merely to survive browser rerenders.

A backend with no document version has a weaker race bound than a cooperating versioned editor. VerifiedAction makes our verify/action calls adjacent, not atomic with another process. Retain and document that limit; do not invent an atomicity guarantee.

## Mutation, recovery, receipts and Undo

Keep current selective text restoration where its proof holds. ReplacementReceipt currently carries snapshot, completed replacement and strategy; private UndoTarget adds handle, replacement range and focused post-write selection. M1 preserves this shape.

For new host/insertion paths, bind intent and inverse evidence to the lease/receipt without persisting host documents. The inverse for insertion is deletion of the specifically confirmed inserted span, never deletion of whatever is currently selected. Revalidate surrounding/context evidence and later edits before deletion. Rich-format restoration needs attributed-slice evidence or a cooperating transaction receipt; string equality alone does not prove arbitrary rich structure. Declare unsupported inverses rather than silently flattening formatting.

Keep existing ClipboardPasteboardTransaction ownership marker, change-count checks, guarded restoration and pending consumption/recovery. External ownership changes must not be overwritten. Existing backup budgets cap retained items/representations/bytes, not one materialization's transient allocation. No new promised/lazy representation reads or capture tier is hidden inside this change.

An indeterminate native mutation does not create a success/Undo receipt. Invalidate the active target and retain only the minimum recovery evidence needed by that backend. Where AX cannot settle whether the edit happened, stop and report the uncertainty; never apply another transport to “finish” it. Clipboard pending recovery continues to block mutation until its existing conservative settlement succeeds.

## Dependency-ordered milestones and file ownership

| Milestone | Implementation | Tests and exit evidence | Delivery |
| --- | --- | --- | --- |
| M0: executable plan | This document; reconcile baseline and approval; link HEH-15/16/17 | Every proposed type has an owner, consumer and test; active source and live statuses are separate | First foundation layer includes plan; Captain Drive gets identical handoff |
| M1: capability/outcome foundation (HEH-15) | New SelectionTransaction.swift; narrow MacSelectionAccess.swift routing integration; public Core API unchanged | New SelectionTransactionTests.swift plus existing MacSelectionAccessSelectionTests, native/core suites; no fallback on indeterminate and no behavior widening; exact-source plain/rich/browser regression | Focused stack layer above PR22 |
| M2: discovery/identity (HEH-16) | MacSelectionAccess.swift and MacSelectionValidation.swift; private binding/resolver only where fixture/live evidence requires it; content-free existing reason taxonomy | Focused root/leaf, ambiguous hosts, cycles, stale IDs, destroyed/recreated target, budget exhaustion; same binding through commit/Undo | Next dependent layer; no tree broadening bundled without proof |
| M3: accessible contenteditable (HEH-16) | Proof-based admission and confirmation at existing clipboard/AX seam; preserve full-value/range checks and formatting limits | Owned direct-static-child, grouped, nested/rich, multiline, controlled rerender and identical-adjacent cases; actual replacement, editor-model persistence, Undo/later-edit, Cancel/drift | Coherent supported-host layer; unsupported cases recorded |
| M4: explicit caret insertion (HEH-17) | Core intent/snapshot/engine contracts and test doubles; native capture/read/replace/receipt/Undo intent handling; minimal App bridge wiring after activation decision | Empty/start/middle/end, emoji/combining/CJK, invalid offsets, active IME, no selection context, cancellation, drift and later-edit-safe inverse | Separate dependent layer; no implicit empty-selection insertion |
| M5: delivery matrix (HEH-1) | Documentation/status corrections and cause-supported repairs only | Exact source/artifact/signer/runtime rows, safety matrix, usable packaged candidate, explicit unsupported/paused rows | Keep all PRs unmerged pending explicit merge authorization |

Parallel ownership: M1 production files and its new pure fixture file had different owners in one worktree; the coordinator alone handled Git. The current M2/M3 layer likewise separates production and new-fixture ownership, followed by one integration review of mutation, recovery and inverse boundaries. Insertion integration remains dependent. Do not have multiple agents edit MacSelectionAccess.swift at once or duplicate whole-repository reviews.

File-level follow-through:
- Sources/ImrseCore/Contracts.swift: intent/snapshot/receipt additions only in M4 with real consumers and explicit migration defaults.
- Sources/ImrseCore/TransformationEngine.swift: propagate explicit intent and validate insertion requests without weakening replacement checks; preserve operation identity/late-completion guards.
- Sources/ImrseMac/MacSelectionAccess.swift: native binding, capability construction, outcome routing, result and inverse proof.
- Sources/ImrseMac/MacSelectionValidation.swift: bounded pure policy helpers only when shared by production and tests.
- Sources/ImrseMac/ClipboardPasteboardTransaction.swift: no speculative rewrite; touch only for demonstrated recovery defect.
- Sources/ImrseApp/App/AppPillBridge.swift and AppModel.swift: explicit intent pass-through if/when an approved invocation route exists, with existing direct Apply presentation.
- Tests/ImrseCoreTests/TransformationEngineTests.swift: explicit intent, no-context generation, output validation, stale completion and Cancel/commit boundary.
- Tests/ImrseMacTests/: new pure fixtures and focused adapter/identity/Undo regressions; never weaken existing tests.
- docs/text-editing-implementation-plan.md and ACCEPTANCE_TESTS.md: intended contract and honest per-source support matrix; no claim from synthetic routing alone.

## Bounded goal loop for each milestone

Define the exact failing case or contract and expected observable output/refusal. Implement the smallest owned delta. Run the nearest pure/core/native checks appropriate to the changed code; then inspect the exact diff for privacy, source continuity and preserved invariants. Publish source progress even while packaging is pending.

For pure deterministic policy, prove permutations and negative boundaries. For native integration, hosted macOS Swift6 warnings-as-errors/native suites are the compile/test gate; parse-only success is not type/concurrency proof. Existing workflow uses swift test --jobs 1 -Xswiftc -warnings-as-errors on macOS and portable jobs separately. Do not run a shared local full package build just because a filtered test appears small. If a separately reviewed isolated test route is used, its graph/resource/coordination gates must be established first.

After hosted verification, validate the exact composed artifact source, inventory, architecture, existing stable signature and authorized destination before installation. Acquire a fresh finite native lock after coordinator handoff. Confirm actual foreground and visible synthetic selection; use the actual product invocation and current controls; do not read an app handle during generation except for an intentional drift test. Inspect original-field content and the product's redacted result, then exercise product Undo, later edit and Cancel.

If a leaf's first useful retry fails the same premise, stop repeating it. Coordinator diagnoses the failing assumption using content-free stage evidence, then changes the contract or implementation only when causally supported. A tool observation timeout is not a product timeout. A stale fixture/foreground or wrong source invalidates that row, not the product.

Close every native interval explicitly, verify holder exit and independent acquisition of the exact lock, restore fallback off, confirm no generation/pill remains and reverify protected original/rollback. Send actual closure to co-owners. Never substitute nominal expiry for release.

## Regression and live acceptance matrix

| Dimension | Required cases | Pass means |
| --- | --- | --- |
| Routing | unsupported strategy, confirmed applied, proved no-op, rejected write, missing/contradictory readback | only proved no-op advances; applied yields one receipt; indeterminate issues no second write |
| Identity | same focus notification, different field/window/app, same-text adjacent editor, destroyed/recreated host, tab/document change | same proven binding remains eligible; all changed/ambiguous bindings refuse without rebind |
| Intent/range | partial/whole selection; explicit collapsed insertion; invalid/missing/overflow UTF-16 ranges; emoji/combining/CJK | correct requested span only; replacement never inferred from empty selection; invalid ranges refuse |
| Native fields | TextEdit plain and rich partial selection, secure and readonly fixtures | exact original-field result; no flattening outside declared capability; safe refusal otherwise |
| Browsers | Vivaldi input/textarea/contenteditable; Safari representative textarea/readonly; controlled editor rerender | current-source supported rows visibly edit original field and persist in editor model; unsupported remains unchanged |
| Undo | immediate exact inverse; later edit in/near span; focus/selection/content/document drift | verified inverse restores only own change, otherwise preserves all later content by refusing |
| Cancel | ready, streaming, delayed provider completion and boundary crossing | precommit Cancel leaves target unchanged on later read; issued write settles honestly, never “cancelled” success ambiguity |
| Clipboard | opt-in off/on, no-op, foreign owner, delayed consumption, pending recovery, unavailable backup | no unauthorized capture or overwrite; existing ownership/recovery contract honored and preference restored off |
| Capability loss | permission/focus/readback/observer loss and pending recovery | failure stage remains specific, no fallback after indeterminate mutation and no receipt from uncertainty |
| Paused/opaque | WeChat; inaccessible editor without sufficient AX evidence; proposed bridges | explicitly paused/unsupported/untested, not marked passed or secretly activated |

Each live row records source and tree, artifact receipt, signer/runtime executable, fixture, intent, before/after evidence, actual transport, receipt/inverse result and safety outcome. Keep supported, safely refused, unsupported, paused and untested separate. An app name is not a capability and green CI is not native acceptance. Foundation source `b9d561a4` has the bounded Vivaldi evidence described above. The new attributed-proof contenteditable layer still needs hosted and exact-source native acceptance; no broad browser or formatting support follows from its source alone.

## Explicit insertion activation decision

The contract and pure/native mechanics can be implemented without a new screen. Existing selected-text invocation must remain selected replacement. A distinct invocation route is necessary to request insertion deliberately; silently treating “no selection” as insertion violates the approved intent contract. Before app activation, present a specific minimal choice using existing surfaces (for example one explicit operational action versus a configured shortcut), or demonstrate an already-authorized explicit route. Do not invent a new mode selector or alter deferred pill UI. This decision does not block M1–M3 source work or M4 contract tests.

Insertion requires an explicit instruction when no selected context exists; it must not send an empty “improve selected text” request. Active IME/composition or insufficient caret/document proof safely refuses until a supported backend can establish a stable insertion point.

## Migration, stacking and rollback

Keep PR22 unchanged/unmerged as the verified repair dependency. Start the foundation from its exact head, not a stale local branch ref; confirm the new layer's merge-base and diff after stack creation. Use native gh-stack for dependent layers where available; titles/bodies state actual verification. The compatibility composition used for packaged testing must exclude deferred UI and bind every parent source exactly. Do not package a main-only or stale local graph by accident.

M1 is behavior-conserving and requires no persisted settings migration. Later intent defaults preserve selected replacement for existing callers; no persistent clipboard/capture switch is introduced. Add new public enum cases/receipt fields only with updated engine, fakes and real native consumers in the same layer. Older candidate rollback requires no configuration rewrite.

Before every authorized test-copy update, validate exact artifact and full inventory, confirm stable identity and absence of active operation/draft, and retain the previous exact signed app for rollback. Never alter the protected original. On failed acceptance, stop new mutations, settle pending recovery before any process transition, preserve evidence and use only the already-authorized guarded copy rollback when it is actually needed. Do not roll source or app backward blindly while an edit might still be consuming.

## Risks and consent-gated alternatives

The principal risks are host/anchor confusion, asynchronous editor rerenders, loss of rich formatting, ambiguous mutation outcomes, IME, and racing clipboard ownership. AX verification/action is not cross-process atomic. Minimize and document races; a cooperating versioned API is the only route to a stronger transaction guarantee, not a longer delay or broader permission grant.

Copy capture could obtain selected text where AX cannot, but does not independently bind target/range or provide safe Undo. A separately approved design needs secure-target checks, explicit capture consent, one correlated Copy attempt, bounded materialization and restoration that never overwrites a new owner. Clipboard managers may observe transient text; do not promise perfect confidentiality. No activation is part of M1–M4.

A browser adapter could bind tab/frame/document/editable-host/version and return model-level edit receipts, respecting frame/permission boundaries and controlled-editor semantics. DOM assignment alone is insufficient. An editor plugin is analogous. Choose one only after the acceptance matrix demonstrates which current proof is unavailable, and obtain named access/privacy consent before extension/helper installation or live use.

WeChat's implementation technology and current API capability remain unknown. Missing range/text, a focused-child/host mismatch, lifecycle drift and write/readback failure are competing hypotheses. When the pause is explicitly lifted, discriminate them using one clean synthetic unsent composer and content-free stage metadata before any write; do not inspect history/contacts/private messages or make a permission/clipboard diagnosis from an app name.

## Completion rule

Declare the milestone complete only when implemented behavior, nearest tests and its exact-source live acceptance (where applicable) meet the stated contract, or when a real capability limit is demonstrated and recorded as unsupported. Record blocked consent choices without stalling independent authorized work. HEH-1 finishes only with a usable packaged build and an honest declared-capability matrix, not a universal-app promise. No PR merges or activation of gated alternatives follow automatically.
