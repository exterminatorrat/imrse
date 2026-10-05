# First-release readiness

## Recommendation

Prepare the selected **`v0.2.0-beta.1` downloadable preview** for Apple silicon,
not a stable or general-trust release. Its app bundle will be ad-hoc signed and
unnotarized: no Apple Developer account or Developer ID publisher identity is
available, and signing/notarization are not being pursued for this preview. This
is an explicit distribution limitation, not a blocker to local preparation. A
downloaded app may be blocked by Gatekeeper; any Open Anyway exception is a
manual, per-app action for a known, unmodified, nonmalicious build only. Keep the
source-build path as a fallback. No public tag, release or asset is authorized
by this readiness work; those still need separate approval.

This document is preparation only. It creates no release, tag, assets, version
bump, signing submission, account registration or runtime installation.

## Real current state

| Item | Observed state |
| --- | --- |
| Source baseline | `main` includes provider PR [#6](https://github.com/exterminatorrat/imrse/pull/6), merge `d5c9748420f4ac46aba3f4e0f461162a658ecc3d`, and the earlier capture fix. |
| App metadata | `Resources/Info.plist`: version **0.1.2**, build **11**, identifier `org.imrse.app`, minimum macOS **14.0**. No metadata was changed for this preparation. |
| GitHub publication | No repository tags, GitHub releases or release assets existed when inspected on October 5, 2026. No official prebuilt download or public download URL exists. |
| Current local artifact | A universal `arm64`/`x86_64` bundle was built with minimum OS metadata 14.0. It is ad-hoc signed, not Developer ID signed or notarized. A universal binary is not proof of Intel/minimum-OS runtime compatibility. |
| Selected preview candidate | A separate local packaging workstream is preparing `v0.2.0-beta.1` with numeric app metadata `0.2.0`/build `12`, **ARM64 only**, and an ad-hoc signature. No public tag/release/asset exists; this documentation does not change version metadata. |
| Apple signing and Gatekeeper | No Apple Developer account or Developer ID publisher identity is available; no Apple safety certification or notarization is claimed. This preview deliberately does not pursue them. Gatekeeper may reject a downloaded app, and a managed Mac may disallow its manual app-specific exception. |
| Deployment | The verified provider/capture bundle was deployed on the Apple-silicon MacBook running macOS 26.2, with the prior bundle retained and saved settings/presets preserved. A Keychain access prompt was observed after the ad-hoc identity changed. |
| Updates | No automatic-updater/appcast component is declared in the inspected package/source. Describe only manual update and rollback; do not promise automatic updates. |

## What is verified

- PR #6 passed portable Linux, native, package and design CI. Local strict native
  verification executed **390 tests**, with no failures and one opt-in real Qwen
  download/inference probe skipped; **88** focused capture/provider tests passed.
- Release packaging verified the app/resource bundles, MLX shader, property list
  and strict ad-hoc signature. Native settings were observed in inert preview
  mode. These checks do not establish Gatekeeper/notarization or live accounts.
- Local risk-focused reviews covered credentials/OAuth/routing, account
  cancellation/removal/quit, successful stream completion and restricted Copilot
  operation. The published blobs matched the tested local source. This was not a
  GitHub/platform review or exhaustive provider/entitlement certification.
- [VERIFICATION.md](../VERIFICATION.md) records bounded production-adapter
  replacement/Undo fixtures in TextEdit plain text and browser input/textarea
  controls. [UNVERIFIED_MACOS.md](../UNVERIFIED_MACOS.md) distinguishes those from
  full installed, physical-keyboard and broader host compatibility.

Harry approved moving the deployed build to the provider PR, but no list of
individual successful account logins or model calls was supplied. Do not turn
that approval into a claim that every provider was live-tested.

## Prioritized gates and decisions

| Priority | Gate | Required next step and owner |
| --- | --- | --- |
| P0 | Preview distribution policy | Harry selected an ARM64-only downloadable ad-hoc/unnotarized beta preview. Do not gate local preparation on developer membership; signing and notarization are not being pursued for this candidate. Keep a separate, optional trusted Developer ID/notarized distribution path for a later approval. No signing credentials were inspected. |
| P0 | Asset-specific legal content | The inspected local app contained Agent Elements, dependency and Qwen notices, but no root imrse MIT copyright/license text was found in its resource notices. The copied kit notice also says runtime dependencies are not bundled in its ZIP, which is not an accurate description of the compiled app. A separate local packaging workstream owns correcting the exact candidate resources/notices before any public binary redistribution. This docs PR does not change sources, the packager, or notice files; this finding is not a general legal-compliance conclusion. |
| P0 | Clean-machine first use and Gatekeeper | On a clean user account/Mac, validate the exact ARM64 archive, first launch, one app instance, permissions, Keychain access, model setup and a first transformation/Undo. If macOS blocks the known, untampered, nonmalicious candidate, verify the manual **System Settings → Privacy & Security → Open Anyway** flow after the blocked launch, where available, and have the user review and confirm **Open** themselves. Managed Macs may disallow it. Test the intended macOS minimum or narrow the support claim. Do not automate Gatekeeper or Keychain consent, disable Gatekeeper globally, or strip quarantine. |
| P0 | Installed end-to-end smoke | With disposable text and explicitly approved credentials/usage, complete physical invocation → provider result → one verified replacement → exact Undo in TextEdit plain text and at least one chosen browser input/textarea. Include cancellation, app-switch/stale-selection refusal, secure/read-only refusal and provider failure. Automated tests and warmed capture probes are narrower evidence. |
| P1, scope-dependent | Official account readiness | For marketed one-click accounts, supply Immers-owned public OAuth registrations for Hugging Face/GitHub and verify consent, expiry/refresh/reconnect, model entitlement and disconnect. ChatGPT must grant eligible plan-use permission; OpenRouter browser connection uses API credits, not consumer subscriptions. |
| P1, scope-dependent | Copilot runtime | Confirm a supported official runtime is installed, then run an approved real-runtime no-disk/tool-denial/auth/inference probe. The adapter requires protocol v3 and verified baseline `1.0.83-2` or compatible newer stable runtime. No runtime was found in the supported MacBook locations; no runtime was installed. |
| P1, scope-dependent | Local/provider interoperability | The real Qwen probe was skipped and current per-provider live results are unspecified. Verify the routes promised in the preview, or clearly mark their live status and setup requirements. API keys do not establish model access by themselves. |
| P1 | Version/tag/assets | The preparation target is tag `v0.2.0-beta.1` with app metadata `0.2.0`/build `12`, ARM64 only. The version/architecture plan is not yet an artifact or tag. Validate metadata, archive integrity, checksums, complete notices, resource relocation and candidate notes before asking for separate public-release approval. |
| P1 | Manual update/rollback | Rehearse graceful quit, a separate backup of the old app, replacement with one new instance, permission/Keychain rechecks and rollback without deleting Application Support or Keychain data. No updater exists in the inspected source; never automate security or Keychain prompts. Define configuration-compatibility limits before promising rollback across versions. |
| P2 | Broader accessibility/host coverage | IME, VoiceOver, full-screen Spaces, multiple displays, rich-text/contenteditable and unmeasured applications remain bounded validation work. Keep the support matrix honest rather than claiming every editor works. |

This document records readiness status; it is not blanket implementation
authorization. A separate local packaging workstream owns preparing the specified
ARM64 preview and correcting its asset-specific notices. That work does not
authorize publishing local packaging/version/notice changes or expand into app features/CI infrastructure, Apple signing
or notarization, OAuth registration, unrelated installation, or live provider
use. Those actions remain outside this documentation scope and require their own
explicit authorization and bounded owner.

## Candidate version and assets

Harry selected **`v0.2.0-beta.1`** as the downloadable preview target. The
separately prepared candidate bundle is planned to use numeric app metadata
`0.2.0`/build `12` and **ARM64 only**; `main` still declares `0.1.2`/build `11`.
No public tag, release or uploaded asset exists. Local artifact preparation is
separate; no version change, tag, asset upload or public release is authorized by
this documentation work.

If the exact candidate passes its gates and Harry later approves publication,
the proposed asset set is an ARM64-only ZIP of the ad-hoc-signed app, a SHA-256
checksum file, approved release notes, the imrse `LICENSE`, and accurate
third-party/model notices. Label the app clearly as an unnotarized beta preview;
do not include user settings, presets, credential stores or downloaded model
weights. Do not invent a filename or download URL before the artifact exists.
GitHub source archives can come from an approved tag; a DMG or updater is not in
scope for this candidate.

## Gatekeeper and manual launch

An ad-hoc signature does not identify an approved publisher or establish that a
download is safe. Gatekeeper may block this preview, and managed Macs may forbid
user exceptions. Only after a blocked launch, and only when the recipient has
verified the exact app is expected, unmodified and nonmalicious, Apple may offer
**Open Anyway** in **System Settings → Privacy & Security**. The user must inspect
the alert and confirm **Open** themselves. This per-app exception is not a
notarization, publisher identity, or safety certification. Never disable
Gatekeeper globally, strip quarantine, bypass a suspected tampered/malicious app,
or automate security/Keychain consent. Use the source-build fallback if no
approved asset is available.

## Candidate go/no-go checklist

- [ ] The exact `v0.2.0-beta.1` preview scope, ARM64 architecture, metadata and risk wording are verified.
- [ ] The ad-hoc/unnotarized preview limitation is explicit; do not start Developer ID enrollment/signing/notarization for this candidate.
- [ ] Project MIT and distribution-specific third-party/model notices are complete.
- [ ] The exact candidate passes the existing CI/package/resource checks.
- [ ] Clean-machine install, permissions/Keychain walkthrough and user-driven Open Anyway exception (if needed and available) pass without automated or global security changes.
- [ ] Installed physical-shortcut transformation, exact Undo and safe refusal/cancel smoke pass.
- [ ] Every marketed provider/account path has consented live evidence or an explicit limitation.
- [ ] OAuth public app IDs and any required official runtime are ready for the advertised scope.
- [ ] Archive/checksums/version/tag/release-note contents match the exact candidate.
- [ ] Manual update/rollback is rehearsed without deleting user data.
- [ ] Harry explicitly approves creation of the tag, public release and each asset upload.

Until those gates close and Harry separately approves publication, there is no
public download. If later published, describe this as a limited, manual-update,
ad-hoc-signed/unnotarized ARM64 beta—not as a trusted, stable, Apple-certified,
auto-updating, universally compatible app or one proven across every
subscription/provider. A later Developer ID/notarized route remains optional
future work, not a prerequisite for preparing this preview.

## References

[First-use README](../README.md) · [Provider setup/billing](official-provider-connections.md) ·
[Candidate notes](release-notes-candidate.md) · [Security](../SECURITY.md) ·
[Verification](../VERIFICATION.md) · [Native gates](../UNVERIFIED_MACOS.md) ·
[Package metadata](../Resources/Info.plist) · [Packaging script](../scripts/build-app.sh) ·
[MIT license](../LICENSE) · [Third-party notices](../pill-kit/THIRD_PARTY_NOTICES.md) ·
[Apple Developer ID](https://developer.apple.com/developer-id/) ·
[Apple Open Anyway instructions](https://support.apple.com/en-us/102445)
