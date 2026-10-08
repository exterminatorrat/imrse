# Web editor investigation roadmap

**Status:** planning only. No browser/contenteditable feature or new compatibility claim is included in this change.

## Current evidence

README and [UNVERIFIED_MACOS.md](../UNVERIFIED_MACOS.md) bound measured browser behavior to disposable input/textarea fixtures in Safari, Chrome, and Vivaldi. The verification report also records that synthetic multi-segment span-contenteditable fixtures refused unchanged before clipboard preparation. These results do not establish compatibility with a real browser editor, Slack, Gmail, Notion, or any other unmeasured host.

The capture source uses `AXSelectedText`, `AXSelectedTextRange`, `AXStringForRange`, writable selected-text, role/protected-ancestry checks, focused-element/application identity, and post-write readback in its existing paths. Those are implementation inputs to investigate, not observations that a web editor exposes them with the required semantics. No live role, range, setter, focus, or readback tuple for a contenteditable host was established here.

## Gated investigation

1. **Keep the existing safety contract.** Any future path must keep the captured element and application identity, prove the original selected span and range immediately before writing, verify the completed mutation, and retain exact inverse Undo for the same target. Preserve UTF-16 range handling, secure/read-only/stale-target refusal, and every existing check's order. Never reacquire a different focused element after capture.
2. **Test proof logic without a browser first.** Add narrowly scoped fixtures for candidate roles, selected-text/range availability, writability, protected ancestry, application identity, post-write readback and Undo. Assert check/action order and conservative refusal when text mapping is ambiguous. Do not replace a structured editor's whole value to imitate a span edit.
3. **Collect host evidence only in a separately authorized, disposable setup.** Start with a local inert page and disposable text. Record the exact macOS/browser version, AX role and attributes observed, selected range, setter result, readback, focus/PID changes, and failure stage. Do not use private conversations or documents, submit a message, enter credentials, or expand clipboard eligibility. Testing a hosted service or account requires its own approved disposable fixture/account and non-submission boundary.
4. **Scope support to verified hosts.** Proceed only if the host provides a stable selected-span mapping and exact readback/Undo without weakening existing guards. If it exposes only a field-level value, produces ambiguous ranges, loses target ownership, or cannot prove the write, leave it unsupported. Publish a host-specific support statement only after source tests, strict suite, and separately recorded native evidence pass; update [README compatibility](../README.md#compatibility-and-verification) and [remaining macOS gates](../UNVERIFIED_MACOS.md) at that point.

## Explicit non-goals

This roadmap does not add browser automation, DOM/script injection, a browser extension, a general AX role allowlist, focus reacquisition, full-value flattening, clipboard-based selection capture, broader clipboard fallback, private-host testing, or a claim that contenteditable editors work. Refusal is the expected result whenever the existing proof cannot establish a safe selected-span replacement.
