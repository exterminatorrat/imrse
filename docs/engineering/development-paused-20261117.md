# Imrse development paused: archival checkpoint (2026-11-17)

**Draft only. Development and testing are paused at the owner's request. Do not merge, enable experimental copying, install, or publish this tree as a fix.** This checkpoint preserves code and evidence; it is not a daily-use release or a claim that all applications work.

## Architecture preserved

1. **Pinned source and destination.** At invocation, the existing Accessibility path captures the selected text into memory before instruction entry. A bounded session carries that exact source to the provider. A separate return ticket pins the original process incarnation, window/control, range and available whole-field baseline. Own instruction-panel defocus is distinguished from observed external drift. Return still requires exact original-target proof; it never pastes into an arbitrary currently focused field.
2. **Single-dispatch replacement and receipt-bound Undo.** Native and qualified clipboard routes keep their existing preconditions. A dispatched native write is not retried as a paste. Unconfirmed outcomes are not reported as successful edits and do not authorize replay. Clipboard ownership and recovery remain separate from content generation.
3. **Retained output and manual-preview backend.** Complete validated output can be retained with bounded session lifetime when application cannot be verified. These are backend accessors, not a user-accessible Copy Result or manual-preview interface. Provider tasks may retain a request until they settle; no hard secure-erasure guarantee is made.
4. **Explicit Cmd-C preparation: disabled groundwork.** The new asynchronous capture seam delays instruction presentation until source preparation settles. The source-copy coordinator can compare a fresh copied value against independently known expected source, distinguish optimistic restoration from authenticated ownership, and retain an unresolved original clipboard backup. The native host implementation is an **unwired draft**; `MacSelectionAccess` does not opt into it. This tree does not deliver literal Cmd-C capture to users or solve AX-unreadable/proxy editors.
5. **Independent operation lifetime.** UI cancellation revokes publication, not ownership of a still-running preparation. A cancellation-ignoring preparation blocks overlapping captures/Undo until settlement. A settled unresolved source-copy backup blocks termination without silent abandonment. Pending-recovery invocation shows the existing error and clears stale current-attempt diagnostic metadata, not the retained recovery evidence.
6. **Diagnostic-only handoff evidence.** Closed reasons distinguish missing/invalid return tickets, wrong phase, an unreleased panel, process identity and application-return failures. These changes add no read, wait, activation, retry or write authority.

## Source checkpoints and scope

- `d4ca2d951863799384178317032e3c1b2fc899c9`: direct-preset non-key presentation, not the normal custom-input solution.
- `d1ec3e6e52b9b112a44bb4f1c2680eb393b76049`: pinned custom-input session, retained output and initial copy primitives.
- `7ca9a638334dd410c6e31a800d1bd1cd429ddea4`: diagnostic-only handoff guard classification, built and tested separately.
- This archive also preserves the previously uncommitted asynchronous capture, expected-source copy/recovery coordinator, native-host draft and tests. Their production opt-in remains disabled.

The draft includes earlier unmerged capture/replacement foundations in its ancestry. It does not supersede their review or merge unrelated Settings branches. Separate editor-native VS Code/helper experiments remain on `dot/editor-local-helper-20261117` (including checkpoint `90d6701`); they are not installed or integrated here. Obsidian's editor-native work is likewise separate. Known proxy/editor surfaces remain refused by the generic automatic path.

## Evidence actually obtained before the pause

### Latest normal custom-input tests

Using the exact diagnostic candidate `7ca9a63`, local Qwen3-1.7B-4bit, disposable source fields, normal double-Control/custom instruction/Apply:

- TextEdit: confirmed forward edit and exact Imrse Undo. A later bounded matrix repeated a successful cycle.
- Word: one confirmed normal-input forward edit and exact Imrse Undo in that matrix.
- Vivaldi: one confirmed normal-input forward edit and exact Imrse Undo in a **local inert textarea**, not ChatGPT.com.

All tested fixtures/settings were restored and the tester reported no pending clipboard transaction. These are representative cycles, not broad catalog or sustained reliability proof. Capy and the actual Vivaldi ChatGPT context were blocked by existing user drafts; ChatGPT desktop inspection/testing was tool-restricted. No host AI prompt was submitted. Do not label those applications tested or passing.

### Failures and limits retained

- An earlier `d1ec3e6` normal TextEdit trial refused before writing with `staleSelection` / `captureInvalidated`; source remained unchanged. The diagnostic candidate did not reproduce it. Its root cause remains unresolved; diagnostic timing changes are not a proven fix.
- Earlier Word clipboard trials visibly changed text but ended unconfirmed, including an AX read failure. Later passes do not establish that transient failure is fixed.
- The delivered preset-focused build was tested with temporary direct presets and compatibility enabled; those conditions differed from the owner's ordinary custom-input use. Preset evidence must not be presented as normal-flow evidence.
- A bounded standalone native-panel experiment failed actual keyboard routing despite apparent field-editor ownership. It is not evidence that all native configurations are impossible. Its executable/test artifacts were removed; no such diagnostic is installed by this PR.
- Model fidelity remains imperfect (including accent preservation and required-detail failures). Exact transport/Undo checks do not certify semantic correctness.

### Automated checks

Before the pause, the asynchronous-copy tree compiled in an optimized App build with DEBUG test seams enabled and passed:

- **36 AppPillBridge XCTest tests**, including cancellation-ignoring capture, one-time input presentation, pending-recovery refusal and application termination outcomes;
- **50 ExplicitSelectionCopy Swift Testing tests**;
- **6 TransformationEngineExplicitSource Swift Testing tests**;
- **11 PillPanelFocusPolicy Swift Testing tests**.

The existing unrelated hosted OCR test was explicitly excluded. A first compilation found a missing `.capturing` case in a test-only state helper; that exhaustiveness error was corrected before the successful rerun. The separate strict Core harness passed **72 tests**. The diagnostic-only branch independently passed **6 report XCTest + 20 focus-return Swift tests** and its Release bundle passed strict/deep local signature verification.

These suites use mocks for copy/recovery and do not establish native Cmd-C ownership, runtime clipboard recovery UX or all-app success. The final archival combination has **not** been rebuilt or retested after the pause. No new release artifact was produced from this combined tree. Local candidate signing is not notarization.

## Unfinished work before any enablement or release

- Reproduce/localize the intermittent normal-input refusal without weakening target checks.
- Qualify normal custom-input flows in fresh, explicitly disposable Capy/ChatGPT contexts without touching user drafts or submitting prompts.
- Review and test the native Cmd-C host, singleton ownership and integration. Optimistic version/all-representation clipboard comparison is not an OS atomic compare-and-swap or producer authentication.
- Provide an explicit, accessible recovery/abandon decision before enabling a route that can retain another clipboard backup. The backend recovery method alone is not a usable recovery interface. Never automatically restore over a later same-text user copy as if ownership were proven.
- Keep unknown/proxy/multi-selection destinations out of automatic paste; copied text alone cannot certify a safe target.
- Decide the deferred UI/redesign work, including visible retained-output handling, separately with the owner.
- Run the applicable complete regression suite and native matrix after resumption, review the combined changes and package/sign/notarize appropriately before considering a release.

## Paused state

At pause, owned Imrse build/test processes were verified stopped. Existing running app, system clipboard, user drafts and unrelated work were left untouched. No merge or installation is part of this archival PR. Resume only on the owner's direction.
