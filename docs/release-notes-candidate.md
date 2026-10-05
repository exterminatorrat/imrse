# Candidate first-preview release notes

**Draft only — not published.** Harry selected **`v0.2.0-beta.1`** for preparation
as a downloadable ARM64 preview. The tag, bundle, archive and public assets do not
yet exist; public release and asset upload still need separate approval. The
candidate bundle is planned to use numeric metadata version `0.2.0`, build `12`.
Current `main` still declares version `0.1.2`, build `11`; this documentation
does not change version metadata. See the [release-readiness checklist](release-readiness.md).

## imrse: your AI commands, everywhere you type

imrse is a native macOS menu-bar app for rewriting selected text in place. Choose
an on-device model or your own provider, give an instruction, and let imrse
replace the original selection only after the complete result and target are
verified. It can refuse a target it cannot safely validate.

### Highlights in the candidate source

- Native selected-text transformations, configurable activation/preset shortcuts,
  cancellation and the latest verified inverse Undo.
- An explicit managed Qwen3 4-bit library on Apple silicon, plus advanced
  OpenAI-compatible endpoints such as the user's local Ollama server.
- Named API-key setup for OpenAI, OpenRouter, Anthropic/Claude, DeepSeek, Gemini,
  Grok/xAI, Mistral, Together AI, Fireworks AI and Cerebras. Native Anthropic
  Messages streaming is separate from compatible endpoints.
- Existing eligible ChatGPT plan authorization, plus OpenRouter browser
  connection, Hugging Face OAuth and GitHub Copilot device authorization/runtime
  integration, with prerequisites and billing distinctions shown in Settings.
- Credential isolation, pinned account destinations, stale-operation guards and
  no silent switch from account access to remote API-key billing. Copilot's
  adapter disables tools/ambient login and keeps session files in memory.
- Native settings/appearance, local-only mode and conservative selection capture,
  including the previously merged transient-focus/range-local fallback repair.

These describe implemented candidate source, not an assurance that every app,
model, account or runtime has completed live validation.

### Requirements and setup

The declared runtime minimum is macOS 14. The preview target is ARM64 only;
managed in-app inference requires Apple silicon. A local universal bundle's
`x86_64` slice is not evidence of Intel compatibility, and minimum-OS smoke has
not been completed. Limit the candidate's claims to the architecture/OS evidence
from its final clean-machine checks.

Build-from-source requirements are separate from runtime requirements: Swift 6.2+
with SwiftBuild support and an appropriate Xcode/Metal toolchain. No official
prebuilt asset or download URL exists yet. Until a separately approved candidate
is published, use the [README](../README.md) source-build and first-use instructions.

Grant Input Monitoring for global activation and Accessibility for reading and
replacing a selection. Updates and rollback are manual; no automatic updater is
included. Before replacing an app, back up the previous bundle and keep only one
copy running. A changed ad-hoc app identity can cause macOS to recheck Keychain
access; handle prompts yourself on the Mac, never in an issue or chat. Preserve
Application Support and Keychain data; never automate consent.

### Gatekeeper and user-controlled launch

The selected preview will be ad-hoc signed, not Developer ID signed or notarized;
there is no Apple Developer account or publisher identity, and no Apple safety
certification is claimed. Gatekeeper may block a downloaded app, and managed Macs
may disallow exceptions. Only for an app the recipient has verified is expected,
unmodified and nonmalicious, Apple may show **Open Anyway** after the first blocked
launch in **System Settings → Privacy & Security**. The recipient must inspect
the alert and confirm **Open** themselves. This is a manual, per-app exception,
not a publisher identity, trust or notarization claim. Never disable Gatekeeper
globally, strip quarantine flags, bypass a suspected tampered/malicious app, or
automate security/Keychain prompts. See Apple's [Developer ID overview](https://developer.apple.com/developer-id/)
and [Open Anyway instructions](https://support.apple.com/en-us/102445).

### Provider and privacy boundaries

API use is billed/quota-managed by the selected provider. ChatGPT plan usage needs
eligible account permission; identity login alone is insufficient. OpenRouter
browser connection uses its API credits. Hugging Face uses account inference
credits/billing, not unlimited consumer-plan inference. Copilot depends on the
user's plan, organization policy and a supported installed official runtime.
Hugging Face/GitHub public OAuth app IDs remain a release setup gate. Claude
consumer OAuth is not offered; Claude API access uses an API key.

imrse sends selected text and the instruction to the chosen provider, not the
surrounding document. It has no imrse account/backend/telemetry or transformation
history; the latest Undo data is volatile, and credentials stay in Keychain.
Local-only prevents remote routing/fallback by imrse, but a third-party loopback
server can itself forward requests. See [SECURITY.md](../SECURITY.md).

### Known limits before publication

- The selected preview is deliberately ad-hoc signed and **not Developer ID signed,
  notarized, or Apple-certified**. This is the chosen preview scope, not a blocker
  to local preparation. Do not describe it as trusted or stable. Developer ID and
  notarization remain optional future work requiring a separate decision.
- Clean-machine installation, the manual Open Anyway flow when needed, permission/
  Keychain prompts, minimum-OS checks and installed physical-keyboard/provider-to-
  host smoke still need explicit validation. The candidate target is ARM64 only;
  Intel runtime support is not claimed.
- Rich text, complex web contenteditable, secure/read-only fields and unmeasured
  hosts are not promised to work. Safe refusal is an intentional outcome.
- Current per-provider live login/inference results were not specified by the
  user's approval to proceed. A real Qwen probe was skipped; actual installed
  Copilot no-disk/auth/inference behavior remains unverified.
- The local package's legal-content inventory still needs a separate correction:
  include the project MIT notice and accurately describe compiled dependencies.
  The packaging workstream owns those local resource/notice changes; this docs PR
  does not modify them or claim a completed legal audit.

### Verification evidence

Provider PR #6 passed all four CI jobs. The combined provider/capture build
passed 88 focused tests and a strict full native suite of 390 tests with one
opt-in probe skipped and no failures. Local resource/MLX-shader/plist/ad-hoc
signature packaging checks passed, and a verified bundle was deployed on the
MacBook with rollback and preserved saved settings/presets. Those checks are
not notarization, clean-machine installation or per-provider live certification.

### Feedback

Use disposable, non-sensitive text and report the app/macOS version, host,
provider route and redacted failure category. Never include selected/generated
private text, passwords, keys or tokens. See the
[provider guide](official-provider-connections.md) and
[remaining native gates](../UNVERIFIED_MACOS.md).

## Maintainer publication checklist

- [ ] Confirm the exact ARM64 beta metadata and final candidate artifact against the readiness gates.
- [ ] Correct and review the separate candidate package resources/notices; do not publish the current old bundle as a verified distribution.
- [ ] Replace draft support/install wording only with actually validated candidate facts.
- [ ] Attach only the approved candidate app/source archives, checksums and complete notices.
- [ ] Obtain Harry's explicit approval before tag/release creation and public asset uploads.

No download URLs, update promises or publication actions are implied by this draft.
