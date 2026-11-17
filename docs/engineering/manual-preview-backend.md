# Manual preview backend (not wired to UI)

`ManualPreviewSession` is an independent ImrseCore primitive for the upcoming UI.
It does not use `TransformationEngine`'s selection/replacement pipeline. Its only
injected effect is `TextProvider`, so the existing dispatch/routing/local-model
provider implementation can be supplied by future app composition. This change
does not instantiate the session in the app or expose a new user workflow.

## Intended future boundary

1. User explicitly supplies text (for example, a visible Paste Source action).
   The caller passes that string; this backend never samples the clipboard.
2. User chooses the provider and submits the instruction. The caller must make
   local/remote destination and consent clear. Provider configuration, localOnly
   and an explicitly supplied fallback are forwarded unchanged; no fallback or
   network destination is invented here. Existing provider validation/admission
   remains authoritative. No real generation occurs in backend unit tests.
3. A completed preview contains the exact input and output for review, including
   unchanged output. It does not say an editor was changed.
4. A future explicit Copy Result action may request text with the current preview
   ID. The accessor returns a string only. Clipboard writing and its success/error
   must be implemented separately in that action. Never automatically paste,
   restore focus, replace AX text, or advertise Undo for this session.

Native paste may affect multiple model selections in Code or Obsidian even when
accessibility exposes only one. This workflow does not verify any editor target,
selection count or paste outcome. The user must control and inspect the paste.

## Bounds and lifecycle

Input/output are capped at 1 MiB UTF-8; instruction at 64 KiB, matching current
core limits. Empty input/model and empty/oversized output fail closed. Partial
output is never exported. No content, instruction, response metadata or raw error
text is logged/persisted by the session. Provider errors are closed ImrseError
values (unrecognized errors become providerUnavailable).

Generation is single-consumer. Cancel, dismissal or the 90-second cooperative
deadline invalidates the result and requests cancellation, but keeps admission
closed until this session's provider call/stream consumer exits. A provider that
ignores cancellation can keep the session busy. This is not a hard kill or proof
that a background producer stopped: the provider's own cancellation, model lease
and resource lifetime contract remains responsible for actual producer cleanup.
There is no automatic retry. Preview references expire after 180 seconds or on
cancel/dismiss/new submission. Task deadlines are cooperative, not real-time
wall-clock guarantees. Strings already returned/copied by a caller cannot be
revoked or guaranteed zeroed; future UI must clear its own retained state too.

No source text is captured from applications, no apply receipt exists, and there
is no copied/applied/undo state. Existing normal app behavior is unchanged until
explicit future UI/composition wiring is implemented and tested.
