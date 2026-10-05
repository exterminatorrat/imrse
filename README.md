<p align="center">
  <img src="Resources/AppIcon.iconset/icon_128x128@2x.png" alt="imrse app icon" width="96">
</p>

<h1 align="center">imrse</h1>

<p align="center"><strong>Your AI commands, everywhere you type.</strong></p>

<p align="center">A native macOS menu-bar app that rewrites selected text in place with a model you choose—and leaves targets it cannot safely verify unchanged.</p>

<p align="center">
  <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-14%2B%20runtime-111827?logo=apple&logoColor=white" alt="macOS 14 and later runtime"></a>
  <a href="Package.swift"><img src="https://img.shields.io/badge/build%20toolchain-Swift%206.2%2B-F05138?logo=swift&logoColor=white" alt="Swift 6.2 or later build toolchain"></a>
  <a href=".github/workflows/verify.yml"><img src="https://github.com/exterminatorrat/imrse/actions/workflows/verify.yml/badge.svg" alt="Verify GitHub Actions workflow status"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-4b5563" alt="MIT license"></a>
</p>

<p align="center">
  <a href="#availability">Availability</a> ·
  <a href="#build-and-launch-from-source">Build</a> ·
  <a href="#first-run">First run</a> ·
  <a href="#models-and-provider-billing">Models</a> ·
  <a href="#privacy-and-safety">Privacy</a> ·
  <a href="#engineering-and-license">Engineering &amp; license</a>
</p>

## Availability

There are currently no Git tags, published releases, or public prebuilt app assets, so there is no official download URL. An ARM64 beta/preview is being prepared locally in a separate packaging workstream; no public release is authorized by these docs. Its working candidate identifier is `v0.2.0-beta.1`, with planned numeric app metadata `0.2.0`, build `12`. Current `main` remains at version `0.1.2`, build `11`, and this documentation does not change it.

The preview will be ad-hoc signed and unnotarized. No Apple Developer account or Developer ID publisher identity is available, and Developer ID signing/notarization are not being pursued for this preview; that does not prevent local preparation. Gatekeeper may block a downloaded app. This is not a stable, Apple-certified, notarized, or auto-updating distribution, and its ad-hoc signature does not identify a trusted publisher. Until an actual asset is prepared and its public release is separately approved, build from source using the instructions below.

The provider/capture source change passed all four CI checks. Local verification reported 88 focused tests and a strict 390-test suite (one opt-in probe skipped, zero failures); app resources and the ad-hoc signature passed packaging checks. One app was deployed on macOS 26.2 with its previous bundle retained for rollback. No per-provider live sign-in or inference result, or live privacy CLI probe, is claimed. See the [release readiness notes](docs/release-readiness.md) and [release-notes candidate](docs/release-notes-candidate.md) for the current release assessment.

## Build and launch from source

**App runtime:** macOS 14 or later. **Build toolchain:** Swift 6.2 or later with SwiftBuild support. The package's `swift-tools-version: 6.0` declaration is not the supported toolchain version for the current app build. The packaged app's Metal resources are verified with the repository's pinned Xcode 26.6 and its Metal toolchain; native test CI separately pins Xcode 26.3.

On a Mac with the required Xcode and Metal toolchain selected, run these commands from a terminal:

```sh
git clone https://github.com/exterminatorrat/imrse.git
cd imrse
swift test --jobs 1 -Xswiftc -warnings-as-errors
./scripts/build-app.sh
open dist/imrse.app
```

The build script uses SwiftBuild, assembles the app resources, verifies the bundle, and writes `dist/imrse.app`. It produces a local ad-hoc-signed app unless you configure a signing identity; it does not notarize the app. Updates and rollback are manual; the inspected source has no automatic updater. Before rebuilding over an existing `dist/imrse.app`, make a separate Finder copy elsewhere if you want to keep that older bundle. To install the new app, use Finder to copy it to `~/Applications` or `/Applications`; back up an existing `imrse.app` before replacing it, and launch only the copy you intend to use. Keep the previous bundle until the new one works. Do not delete `~/Library/Application Support/imrse` or imrse's Keychain items to troubleshoot an update.

## First run

1. Click the imrse menu-bar icon to open Settings, then go to **Models → Add Provider**. Choose an available provider or model, complete any explicit local-model download or account setup, then choose your default model.
2. Allow **Input Monitoring** for the global shortcut and **Accessibility** for reading and replacing the selected text. macOS manages these separately in **System Settings → Privacy & Security**.
3. For a safe first try, create a disposable TextEdit document and choose **Format → Make Plain Text**. Select a short paragraph, double-tap **Control**, enter an instruction such as “Make this concise,” and press **Return**. An empty instruction uses your `default.md` instruction or the built-in default.
4. Wait for the completed replacement. Right-click or Control-click the imrse menu-bar icon and choose **Undo** while the target is unchanged to restore the original. Press **Escape** before completion to cancel.

imrse only replaces a target it can still verify. An unsupported, secure, read-only, or changed selection is left unchanged rather than pasted into a guessed field. The completed TextEdit plain-text probe does not establish compatibility with every app or rich-text editor.

After an ad-hoc app update, macOS may show a login-Keychain password prompt. Handle any such prompt locally on your own Mac; never give your password, API key, or token to another person or put it in an issue.

## Models and provider billing

### On-device models

Managed models run locally on **Apple silicon only**. Downloads are explicit and verified: Qwen3 1.7B (about 984 MB) and Qwen3 4B Instruct (about 2.28 GB). The app does not silently send local-model requests to a cloud provider.

### Account and API-key providers

Select **Settings → Models → Add Provider** to configure a connection. For the exact endpoints, OAuth setup, and model-ID requirements, see [Official provider connections](docs/official-provider-connections.md).

- **API keys:** OpenAI and OpenRouter, plus Anthropic/Claude, DeepSeek, Google Gemini, Grok (xAI), Mistral, Together AI, Fireworks, and Cerebras. These use each provider's API quota and billing, not a consumer chat plan. Use an exact text-generation model ID your account can access. Grok is the xAI route; it is not Groq.
- **ChatGPT account:** Requires an eligible plan-use entitlement and a model available to that account. Signing in alone does not prove inference access, and a failed account request does not switch to API-key billing.
- **OpenRouter account:** Uses OpenRouter credits/API billing, not a ChatGPT, Claude, or Google consumer subscription.
- **Hugging Face account:** Uses Inference Providers and available compute credits or paid usage. Connecting requires the app's public OAuth client ID; it does not run the model on your Mac.
- **GitHub Copilot account:** Requires the app's public OAuth client ID and a compatible official Copilot runtime already installed separately (protocol v3; baseline `1.0.83-2` or a compatible newer stable release). imrse does not install it, reuse its cached login, or read GitHub CLI credentials. Your Copilot plan and organization policies still determine access.

Claude consumer OAuth is not offered; Claude Pro/Max is not an Anthropic API key. Google AI consumer plans do not include API usage. For Hugging Face and Copilot, an account sign-in is not proof that your plan or organization permits inference; see the provider guide for their separate prerequisites.

### Ollama and compatible local servers

For a standard Ollama setup, add a **Custom advanced** endpoint using `http://localhost:11434/v1`, disable the API-key requirement, and enter the exact model tag shown by `ollama list`. Local-only mode allows managed on-device models or loopback endpoints and blocks remote fallback. A local server can still forward requests to another service, which imrse cannot control or guarantee to be local.

## Privacy and safety

The model request contains the selected text and your instruction, not the surrounding document. imrse has no account, inference backend, telemetry, or transformation history. The original and latest replacement are kept in volatile memory for one-step Undo and are cleared when you quit. API keys and account credentials are stored in Keychain, not in configuration or preset files. Clipboard replacement is optional and off by default.

Cloud providers handle text sent to them under their own data policies. Local-only mode restricts imrse's own routing, but cannot guarantee that a third-party loopback server will not forward a request. Read [Security and privacy](SECURITY.md) before connecting a provider or sharing diagnostics.

## Compatibility and verification

A recent locally validated app bundle contains both `arm64` and `x86_64` slices. That does **not** claim that imrse has been smoke-tested on Intel Macs or on the macOS 14 minimum version. Managed on-device models are limited to Apple silicon.

Replacement checks are bounded to measured targets: disposable plain text in TextEdit and input/textarea fixtures in Safari, Chrome, and Vivaldi. Rich-text editors, web `contenteditable` fields, and other unmeasured apps are not claimed as supported. See the [verification report](VERIFICATION.md) for test scope and [remaining macOS gates](UNVERIFIED_MACOS.md) for what is still unverified.

## Troubleshooting

- **The shortcut does nothing:** Check **System Settings → Privacy & Security → Input Monitoring**, allow imrse, and retry. Accessibility permission is also needed to read and replace selections.
- **Text stays unchanged:** Confirm the target still has a plain-text selection. Secure or read-only fields are intentionally unsupported. If the selection moved, the app changed, or the target changed during generation, select the text again and retry; Undo is available only while its target remains unchanged.
- **A model request fails:** Check that the provider is reachable, the exact model ID is supported by your account, and the provider has available API quota, credits, plan entitlement, and organization approval. An account login alone may not include inference.
- **Ollama is not found:** Start the Ollama server, check its model tag with `ollama list`, and verify the endpoint is exactly `http://localhost:11434/v1` with API-key authentication off.
- **A new account option is unavailable:** Hugging Face and Copilot need app-owned public OAuth client IDs; Copilot also needs the compatible runtime described above. See [Official provider connections](docs/official-provider-connections.md).
- **macOS asks for a Keychain password after an ad-hoc update:** Review and handle the prompt locally. Do not send anyone your password or delete Keychain items as a workaround.

When reporting a problem, use disposable non-sensitive text. Never include selected or generated text, passwords, API keys, tokens, or confidential content in issues. An ad-hoc download may be blocked by Gatekeeper. Only for an app you have independently confirmed is the expected, unmodified, nonmalicious build from a source you trust, Apple may offer **Open Anyway** in **System Settings → Privacy & Security** after the first blocked launch. Review the alert and confirm **Open** yourself; managed Macs may disallow this app-specific exception. It does not verify the publisher or make the app notarized. See Apple's [Open Anyway instructions](https://support.apple.com/en-us/102445). Never disable Gatekeeper globally, strip quarantine flags, bypass a suspected tampered or malicious app, or automate security or Keychain consent.

## Engineering and license

| Topic | Reference |
| --- | --- |
| Product behavior | [Product contracts](PRODUCT.md) |
| Architecture and data flow | [Architecture](ARCHITECTURE.md) |
| Provider setup and billing | [Official provider connections](docs/official-provider-connections.md) |
| Security and privacy | [Security](SECURITY.md) |
| Verification evidence | [Verification report](VERIFICATION.md) |
| Remaining macOS gates | [Unverified macOS behavior](UNVERIFIED_MACOS.md) |
| Release status | [Release readiness](docs/release-readiness.md) · [Release-notes candidate](docs/release-notes-candidate.md) |
| Apple distribution and Gatekeeper | [Developer ID](https://developer.apple.com/developer-id/) · [Open Anyway](https://support.apple.com/en-us/102445) |
| Design and tests | [Design notes](DESIGN.md) · [Acceptance tests](ACCEPTANCE_TESTS.md) · [macOS integration](MACOS_INTEGRATION.md) |

imrse is open source under the [MIT License](LICENSE), which permits commercial use, modification, and redistribution. Copies or substantial portions must include the copyright and license notice. Third-party dependencies, included assets, and downloaded model weights retain their own terms; see [third-party notices](pill-kit/THIRD_PARTY_NOTICES.md), [pill-kit license](pill-kit/upstream/LICENSE), and [Qwen3's Apache license](Sources/ImrseLocal/Resources/Qwen3-APACHE-LICENSE.txt).

<details>
<summary>Shortcuts and user files</summary>

The main shortcut can be recorded in Settings with Command, Option, or Control and optionally Shift. Double-tap Control remains a separate activation option. Preset shortcuts are saved explicitly and none are assigned by default; Command-1 through Command-9 fill a configured preset only while the imrse input is active. macOS and other apps' shortcut conflicts cannot be detected. **Command-comma** opens Settings while imrse is active; **Command-W** closes its window without quitting.

User files live in `~/Library/Application Support/imrse/`:

```text
config.json       versioned provider, shortcut, and appearance settings
default.md        instruction used when the input is empty
presets/*.md      portable named transformations
LocalModels/      app-managed verified model files
```

Advanced Settings opens this directory. imrse creates missing starter files without overwriting existing ones; a missing or blank `default.md` uses the built-in instruction. Reload configuration explicitly to pick up external edits. Preserve this directory and Keychain items when updating the app.

</details>
