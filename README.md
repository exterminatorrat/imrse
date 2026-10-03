# imrse

**Your AI commands, everywhere you type.**

Select text, invoke imrse, describe an optional change, and press Return. imrse generates a complete transformation separately, then replaces the original selection only after checking that the captured target is still safe. An empty instruction uses your own `default.md`.

This is an open-source macOS menu-bar app, not a chatbot or cloud service. There is no imrse account, backend, telemetry, conversation history or required cloud model. Managed on-device models, a ChatGPT account, OpenAI/OpenRouter API keys and compatible endpoints use the same transformation lifecycle.

## Build and run

Requires macOS 14+ and a Swift 6.2+ toolchain with SwiftBuild support. SwiftPM resolves native Lottie for the supplied pill kit and MLX for managed inference on Apple silicon. Core and portable service code also build on Linux; macOS cryptographic account verification and the native local runtime are platform-specific.

```sh
swift test
./scripts/build-app.sh
open dist/imrse.app
```

The script uses SwiftBuild so MLX's compiled Metal resource is included, then creates a local ad-hoc signed bundle. Resource-complete packaging is verified with Xcode 26.6 and its Metal toolchain; CI separately keeps native test coverage on Xcode 26.3. It does not notarize or publish anything. For development use `CONFIGURATION=debug ./scripts/build-app.sh`. A distribution release needs a stable Developer ID signature and notarization; source compilation does not prove distribution readiness.

Core and Services also build and test on Linux:

```sh
swift test
```

The package excludes AppKit/SwiftUI targets on Linux rather than pretending those system APIs work there.

## First use

1. Click the imrse logo in the menu bar to open Settings directly, then choose Models and Add Provider. Choose Local on this Mac, a ChatGPT account, OpenAI API key, or OpenRouter. Download a local model explicitly, connect your account, or save your API key, then choose the model as default. Custom advanced retains manual endpoint/model settings. Credentials stay in Keychain, not configuration files.
2. Allow imrse under System Settings → Privacy & Security → Input Monitoring for global activation, and Accessibility for reading/replacing selected text. These are separate permissions. Shortcuts Settings shows their status and links to both panes. If keyboard monitoring is inactive after permission changes, return to imrse or choose Retry Keyboard Monitoring; quit and reopen if macOS requests it.
3. Select a few words in a disposable plain-text document. Double-tap Control, enter an instruction, and press Return. Shortcuts Settings lets you record, change, or clear the main keyboard shortcut. In Presets, record a shortcut and choose Save Preset to run that transformation directly. No preset shortcuts are assigned by default.
4. Use Undo in the imrse menu to restore the latest verified replacement. An edited or unavailable target blocks undo rather than risking another document.

Escape dismisses a ready pill and cancels generation. Repeated submission never starts parallel writes. Errors preserve the original selection whenever no commit has occurred; a replacement that cannot be verified is reported as failure, never success. Clipboard fallback is optional and disabled by default.

Settings uses the supplied sidebar layout: General, Models, Presets, Shortcuts, Advanced, and bottom-pinned About. About stays in the same retained window; providers and diagnostics open as sheets, and preset editing stays inline until Save or Cancel. Right-click or Control-click the menu-bar logo for invocation, presets, Undo, Settings and Quit. If you hide the menu-bar item in General, imrse appears in the Dock so Settings remains reachable. ⌘, opens Settings when imrse is active; ⌘W closes its window without quitting.

To record a shortcut, click Record… or Change, then press Command, Option, or Control together with a key; Shift can be added. Plain Escape or Cancel leaves the binding unchanged. Recording pauses global imrse activation and stops when the recorder loses focus. Duplicate imrse bindings are rejected without replacing the saved configuration. macOS and other-app collisions cannot be detected, so choose a chord that those applications leave available. Double-tap Control remains an independent activation option.

## Models and connections

Local on this Mac offers a curated compact Qwen3 1.7B 4-bit model (approximately 984 MB) and a balanced Qwen3 4B Instruct 4-bit model (approximately 2.28 GB), both Apache-2.0. Managed inference requires Apple silicon. Download is opt-in, shows progress, and verifies pinned artifact sizes and hashes before installation. Installed models load from the app's own library without an implicit network fetch. No transformation starts a download, and unsupported or excessive input is rejected instead of silently switching to the cloud. These are initial curated choices, not a benchmark ranking.

Continue with ChatGPT uses OpenAI's official open-source/local-app OAuth flow. It uses your eligible ChatGPT plan through the public Responses API, with account-specific available models; it does not import Codex credentials or ChatGPT conversations. API-key connections are separate and billed by their provider. A ChatGPT connection's failures never trigger remote API-key billing fallback. A real account connection requires your browser consent and may be limited by account/workspace policy.

Presets can override provider/model and explicitly configure an eligible fallback. Local-only permits managed on-device inference or a loopback endpoint and excludes remote fallback. A third-party loopback server can still forward requests itself; that server is outside imrse's boundary.

## Your files

Configuration lives in `~/Library/Application Support/imrse/`:

```text
config.json       versioned provider, shortcut and appearance settings
default.md        instruction used when the input is empty
presets/*.md      portable named transformations
LocalModels/     app-managed verified local model files
```

Advanced Settings opens this directory. Bootstrap creates missing starter files without overwriting your existing files. A missing or blank `default.md` uses the documented built-in instruction; user content is not overwritten to repair it. Explicit configuration reload picks up external edits.

Presets use Markdown with JSON front matter between `---` lines. For example:

```markdown
---
{
  "id": "concise",
  "name": "Concise",
  "localOnly": false,
  "context": "selection"
}
---
Make the selected text concise. Preserve its meaning, terminology and useful formatting. Do not invent facts.
```

Save this as `presets/concise.md`; its filename and `id` must match. Optional front-matter fields specify `providerID`, `model`, `fallbackProviderID`, `shortcut`, and `motion`. Unknown fields are rejected, so a typo such as `local_only` cannot silently disable the privacy requirement. Graphically recorded global/preset bindings are stored as a macOS physical `keyCode` and explicit modifier booleans; their displayed key labels use the current keyboard layout. Inspect the schema before hand editing, then reload from Advanced. Local-only permits managed local inference and loopback endpoints, never a remote fallback. Command-1 through Command-9 only fill configured presets inside the active pill input; they are not global defaults. See [SECURITY.md](SECURITY.md) for the boundary and limitations.

## Verification and limitations

The measured native, Linux, React, packaging and actual native-rendering results are recorded in [VERIFICATION.md](VERIFICATION.md). Native preview captures are explicitly separated from host replacement evidence.

The implementation has separate portable logic and real macOS adapters, but host-app compatibility must be physically measured. Rich-text editors, virtualized editors and web contenteditable fields may not expose enough AX state for safe replacement. Explicit refusal is preferable to an uncontrolled paste.

The supplied [React preview](pill-kit/web) is a visual evaluation instrument, not production UI and not evidence of native rendering. It runs the original SpiralLoader and explicitly simulated preview callbacks; none of those simulated completions ship in the native app. Run its checks with `npm ci`, `npm run typecheck`, `npm test`, `npm run test:browser`, and `npm run build` from `pill-kit/web`. [UNVERIFIED_MACOS.md](UNVERIFIED_MACOS.md) contains the exact first-Mac sequence, adapter assumptions and the unverified compatibility matrix. No host in that matrix should be advertised as supported before its manual gate passes.

## Product and engineering notes

- [PRODUCT.md](PRODUCT.md): interaction contracts and v0.1 boundary.
- [ARCHITECTURE.md](ARCHITECTURE.md): modules, ownership, concurrency and test seams.
- [DESIGN.md](DESIGN.md): silhouette, typography, motion and state behavior.
- [ACCEPTANCE_TESTS.md](ACCEPTANCE_TESTS.md): automated and native release gates.
- [MACOS_INTEGRATION.md](MACOS_INTEGRATION.md): platform adapters and system APIs.
- [SECURITY.md](SECURITY.md): threat model, credentials and privacy.

MIT licensed. No transformation data belongs in public bug reports; use the redacted diagnostic report and a non-sensitive reproduction.
