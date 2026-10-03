<p align="center">
  <img src="Resources/AppIcon.iconset/icon_128x128@2x.png" alt="imrse app icon" width="96">
</p>

<h1 align="center">imrse</h1>

<p align="center"><strong>Your AI commands, everywhere you type.</strong></p>

<p align="center">A native macOS menu-bar app that transforms selected text in place using an on-device model or a provider you choose.</p>

<p align="center">
  <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&logoColor=white" alt="macOS 14 and later"></a>
  <a href="Package.swift"><img src="https://img.shields.io/badge/Swift-6.2%2B-F05138?logo=swift&logoColor=white" alt="Swift 6.2 or later"></a>
  <a href=".github/workflows/verify.yml"><img src="https://github.com/exterminatorrat/imrse/actions/workflows/verify.yml/badge.svg" alt="Verify GitHub Actions workflow status"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-4b5563" alt="MIT license"></a>
</p>

<p align="center">
  <a href="#use-it">Use it</a> ·
  <a href="#build-from-source">Build</a> ·
  <a href="#architecture">Architecture</a> ·
  <a href="#license">License</a>
</p>

## Use it

1. Select text in an app and double-tap **Control** to open imrse.
2. Enter an instruction, or leave it blank to use your `default.md` instruction.
3. Press **Return**. imrse generates the complete result, validates it, and rechecks the original selection before replacing it once.
4. Use **Undo** from the imrse menu to restore the latest verified replacement while its target is unchanged.

For first use, click the menu-bar icon and open **Models → Add Provider** in Settings. Download an on-device model, connect an eligible ChatGPT account, or configure an API key or compatible endpoint, then choose your default model. Try an instruction such as “Make this concise,” “Fix typos without changing the tone,” or “Turn this into three bullets.”

Global activation needs **Input Monitoring** permission; reading and replacing selected text needs **Accessibility** permission. These are separate macOS permissions. Unsupported or unverifiable selections are left unchanged rather than pasted into a guessed target.

## Model routes

| Route | What it does |
| --- | --- |
| On-device | Run one of two curated Qwen3 4-bit models on Apple silicon: 1.7B (about 984 MB) or 4B Instruct (about 2.28 GB). Downloads are explicit and verified; inference does not silently fall back to the cloud. |
| ChatGPT account | Use OpenAI’s official account flow and Responses API with models available to your account. It does not fall back to API-key billing. |
| API key | Connect a separate OpenAI or OpenRouter key; provider usage is billed by that provider. |
| Compatible endpoint | Configure an advanced endpoint and model manually. Local-only mode also permits loopback endpoints but never a remote fallback. |

## Privacy boundaries

There is no imrse account, backend, telemetry, or transformation history. imrse uses the selected text and your instruction—not the surrounding document—and retains the latest original and replacement only in volatile memory for Undo, clearing them on quit. API keys and account sessions are stored in Keychain, not in configuration or preset files.

Cloud providers receive the selected text and instruction you send them, under their own data policies. Local-only restricts imrse to an on-device model or a loopback endpoint; a third-party loopback server can still forward requests itself. Clipboard replacement is optional and off by default. See [SECURITY.md](SECURITY.md) for the full boundary.

## Build from source

**Runtime:** macOS 14 or later. **Build toolchain:** Swift 6.2 or later with SwiftBuild support. The package declares Swift tools version 6.0; the newer compiler requirement is for the current build and CI configuration.

```sh
git clone https://github.com/exterminatorrat/imrse.git
cd imrse
swift test
scripts/build-app.sh
open dist/imrse.app
```

`swift test` also runs on Linux for the portable Core and Services modules; native macOS targets are excluded from that package graph. CI uses Xcode 26.3 for native tests. Resource-complete app packaging is verified with Xcode 26.6 and its Metal toolchain. The build script creates a local ad-hoc-signed app by default; it is not notarized.

## Architecture

| Module | Responsibility |
| --- | --- |
| `ImrseCore` | Portable transformation contracts, state, output validation, cancellation, and the latest Undo receipt. It imports Foundation only. |
| `ImrseServices` | Provider HTTP, routing, account sessions, and user-owned configuration and preset files. |
| `ImrseMac` | Native adapters for Accessibility, keyboard events, pasteboard, and Keychain. |
| `ImrseLocal` | Managed on-device model download, verification, installation, and inference on Apple silicon. |
| `ImrseApp` | The AppKit/SwiftUI menu-bar app, presentation, settings, and application lifetime. |

The native app uses SwiftUI and AppKit, with pill components supplied by [`pill-kit/native`](pill-kit/native). [`pill-kit/web`](pill-kit/web) is a separate React visual preview, not production UI or evidence of native rendering or host-app compatibility.

## Project status

imrse is in active development. Host compatibility is deliberately bounded: the public [verification report](VERIFICATION.md) records measured tests and replacement/Undo probes for specific fixtures, not universal support. See [remaining macOS gates](UNVERIFIED_MACOS.md) for what still needs verification before distribution; rich-text editors, web contenteditable fields, and other unmeasured hosts should not be assumed to work.

## Contributing

Issues and pull requests are welcome. Use a disposable, non-sensitive example when reporting a problem; never post selected text, generated text, credentials, or confidential content in a public issue. See [SECURITY.md](SECURITY.md) before sharing diagnostics.

## License

imrse is open source under the [MIT License](LICENSE), which permits commercial use, modification, and redistribution. Copies or substantial portions must include the copyright and license notice. Third-party dependencies, included assets, and downloaded model weights retain their own terms; see [pill-kit/THIRD_PARTY_NOTICES.md](pill-kit/THIRD_PARTY_NOTICES.md), [pill-kit/upstream/LICENSE](pill-kit/upstream/LICENSE), and [the Qwen3 Apache license](Sources/ImrseLocal/Resources/Qwen3-APACHE-LICENSE.txt).

## Advanced keyboard and configuration details

<details>
<summary>Shortcuts, files, and preset format</summary>

The main shortcut can be recorded in Settings; use Command, Option, or Control with a key, and optionally Shift. imrse rejects duplicate bindings of its own, but macOS and other apps’ shortcut conflicts cannot be detected. Double-tap Control remains an independent activation option. Preset shortcuts are saved explicitly, with none assigned by default; Command-1 through Command-9 fill a configured preset only while the imrse input is active.

Click the menu-bar icon to open Settings. Right-click or Control-click it for the imrse menu. **Command-comma** opens Settings while imrse is active, and **Command-W** closes its window without quitting. Hiding the menu-bar item makes imrse available from the Dock.

User files live in `~/Library/Application Support/imrse/`:

```text
config.json       versioned provider, shortcut, and appearance settings
default.md        instruction used when the input is empty
presets/*.md      portable named transformations
LocalModels/      app-managed verified model files
```

Advanced Settings opens this directory. On first launch, imrse creates missing starter files without overwriting existing ones; a missing or blank `default.md` uses the built-in instruction. Reload configuration explicitly to pick up external edits.

Presets use Markdown with JSON front matter. For example, save this as `presets/shorten.md`; the `id` must match the filename:

```markdown
---
{
  "id": "shorten",
  "name": "Shorten",
  "localOnly": false,
  "context": "selection"
}
---
Make the selected text more concise. Preserve its meaning, terminology, and useful formatting. Do not invent facts.
```

Optional front-matter fields include `providerID`, `model`, `fallbackProviderID`, `shortcut`, and `motion`; a preset may choose a provider/model and explicitly configure an eligible fallback. Unknown fields are rejected. Local-only presets allow on-device inference or loopback endpoints, never remote fallback.

Escape dismisses a ready pill or cancels generation. Submitting again does not start a parallel write.

</details>

## Engineering notes

- [Product contracts](PRODUCT.md)
- [Architecture and data flow](ARCHITECTURE.md)
- [Security and privacy](SECURITY.md)
- [Verification results](VERIFICATION.md)
- [Remaining macOS gates](UNVERIFIED_MACOS.md)
- [Design notes](DESIGN.md)
- [Acceptance tests](ACCEPTANCE_TESTS.md)
- [macOS integration](MACOS_INTEGRATION.md)
