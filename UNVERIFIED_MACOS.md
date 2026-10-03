# Remaining native validation gates

The current measured results are in [VERIFICATION.md](VERIFICATION.md). Passing
tests, a signed local bundle or a browser DOM harness does not prove installed
host compatibility, production account policy or physical shortcut delivery.

## Before distribution

1. Use a stable Developer ID signature and notarization. Recheck installed
   Keychain access and Accessibility/Input Monitoring grants for that identity.
2. Test physical global/preset shortcuts, modifier timing, Secure Input,
   recording cancellation, sleep/wake and event-tap recovery. Synthetic injected
   events and responder tests are narrower evidence.
3. Complete installed provider-to-host transformation, exact Undo and
   cancellation/app-switch sequences with non-sensitive disposable text.
4. Test nonempty multi-type clipboards, clipboard ownership changes and delayed
   paste behavior. Existing browser probes used an initially empty clipboard.
5. Verify IME composition, VoiceOver, Reduce Transparency, Reduced Motion,
   increased text size, full-screen Spaces and multi-display placement without
   weakening target-safety checks.
6. Perform a real login session to verify the registered main app starts once;
   verify disable/revoke behavior through native Login Items settings.

## Bounded host results

| Host | Measured target | Boundary |
| --- | --- | --- |
| TextEdit 1.20 | Disposable plain text, direct selected-text replacement and exact inverse Undo | Rich text and the complete installed sequence remain unverified. |
| Safari 26.6.2 | Local input/textarea, opt-in clipboard replacement and exact Undo | Known structured fixture refused unchanged; broader web editors remain unverified. |
| Chrome 154.0.8037.95 | Same fixture, bounded range/text Undo readback and repeat runs | Full installed sequence and other editor structures remain unverified. |
| Vivaldi 8.2.4133.80 | Same local input/textarea with an isolated profile | Known structured fixture refused unchanged; broader editors remain unverified. |
| Notes, Mail, ChatGPT web, Slack, Discord, Notion, VS Code, Cursor | No full installed compatibility sequence completed | Do not advertise support based on toolkit or DOM tests. |

One earlier Safari clipboard attempt failed transiently despite subsequent
passes; its initial cause was not established. A simple exposed AX tree is not
proof of plain-text semantics, and OS/target races remain possible. Explicit
refusal is correct when a target cannot be verified safely.

## Safe manual sequence

Use a new disposable document, not a password, important unsaved file or
confidential paragraph. Select a first line containing combining marks, CJK and
emoji while preserving a second line. Invoke, enter an instruction and submit
once, then repeatedly; only one completed replacement is permitted. Undo must
restore the original exactly. Move the caret, edit the span, switch apps or close
the host and retry: conservative failure must not overwrite stale text.

Repeat with an empty instruction, a provider error, a slow stream cancelled at
different phases, a changed clipboard and a denied/revoked permission. Inspect
only the redacted diagnostic report for categories and confirm it contains no
selected/generated text, credentials or clipboard material.

New `balanced` and `slow` motion values are supported alongside legacy
`instant` and `smooth`. Older application builds cannot necessarily decode new
values; pair a deliberate downgrade with a matching configuration backup while
preserving newer edits. Do not silently restore older user settings.
