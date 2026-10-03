# Validation report

## Executed in the producing Linux environment

| Check | Result | Evidence |
|---|---|---|
| JavaScript state/word tests plus source/asset identity tests | 23 passed; 0 failed | web-tests.txt |
| Swift portable lifecycle / status / spiral-sequence tests | 15 passed; 0 failed | swift-tests.txt |
| Upstream component Git blob identity | Exact match | SOURCE-MANIFEST.json and source tests |
| Upstream animation-data Git blob identity | Exact match | SOURCE-MANIFEST.json and source tests |
| Native JSON assets compared to original exports | Equivalent, both assets | source tests |
| Native UI Swift parser | 6 UI files parsed; exit 0 | native-syntax.txt |
| TypeScript/TSX syntax/transpilation | 11 files; 0 syntax errors | typescript-syntax.txt |

Portable tests were first run against missing behavior and failed; the original
red logs are retained. The final logs above are the passing rerun.

The native parser is NOT a macOS SDK typecheck. TypeScript transpilation is NOT
React/Next dependency-aware typechecking. These checks must not be relabeled as
native or web build validation.

## Not executed successfully

- React dependency installation: network/DNS access was unavailable; the subsequent
  offline install failed because dependencies were not in cache. See dependency-install.txt.
- npm run typecheck / npm run build: not run, because dependencies could not be installed.
- Playwright React integration tests: supplied (8 tests) but NOT run here.
- Native ImrsePillUI build and runtime: NOT run; this machine is Linux.
- Native screen, input, Lottie renderer, AX target, provider, replacement or Undo
  integration: NOT validated. The latter operations belong to the consuming app.

## Integration status

The component source and handoff package were created. No GitHub write, commit,
push, PR, Capy workspace mutation, deployment, or actual Mac installation was made.
The public imrse repository was read and reported empty at inspection time;
Capy's private working copy was not inspected.

## Issues corrected during implementation review

- Escape needed an active-interaction listener after the input disappears; a
  handler attached only to the former input would miss processing-state Escape.
- Repeated native invocation now preserves an existing input draft.
- Unmapped native Command-number shortcuts are forwarded instead of swallowed.
- An enqueued native animation completion is invalidated on stop, preventing a
  dismissed loader from restarting itself.
- The lifecycle rejects stale completion, duplicate submission and premature
  success events. Generation alone is never treated as confirmed replacement.

## Next verification environment

Capy can install web dependencies and run the included browser checks on Linux.
A Mac is still required for the native build and the manual checklist in
native/UNVERIFIED_MACOS.md. Do not replace failed native tests with a browser claim.
