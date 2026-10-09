# Installing or rolling back the local beta candidate

This note applies only to a locally generated `imrse 0.2.0-beta.1` macOS arm64 candidate with app version `0.2.0` and build `13`. Updating this document does not mean an app or archive has been built or that a signer has been selected. The packaging workflow requires a caller-selected 40-hex certificate SHA-1 and produces a locally certificate-signed experimental candidate; that does not claim a Developer ID signature, notarization ticket, or trusted public release. The presence of an archive does not prove the app is safe or untampered. The declared minimum is macOS 14.0; the packaging host's macOS version is not a minimum-version runtime test. Intel is not supported by this candidate.

The builder reads `IMRSE_SIGNING_CERTIFICATE_SHA1`; the packager requires `--signing-certificate-sha1` with the identical value. Missing, malformed, ad-hoc, or mixed selections are rejected. A selector is public metadata, not proof that its private key is available or that the resulting app has the expected signature.

Before extracting a copy, verify the archive and manifest from the same trusted handoff directory:

```sh
shasum -a 256 -c SHA256SUMS
```

Only continue when every listed file, including the ZIP, `MANIFEST.json`, `BUILD-PROVENANCE.json`, and `SOURCE-INPUT-MANIFEST.json`, reports `OK` and the handoff came from a source you trust. The checksum detects accidental or untrusted changes only when the checksum itself is obtained through a trusted channel; it does not establish publisher identity. Do not launch an archive whose provenance or integrity is uncertain.

The candidate must be installed manually. Quit the existing imrse instance before replacing its app bundle, save an untouched copy of the previous `.app` bundle somewhere outside the install location, then copy the candidate app into the same install location. Keep only one imrse instance running. The packaging procedure does not alter an installed app, `~/Library/Application Support/imrse/`, or Keychain entries.

Keep `~/Library/Application Support/imrse/` and Keychain entries intact during an update and rollback. The app stores provider configuration in Application Support and credentials in the macOS Keychain; deleting either can remove settings or credentials. Global shortcut capture requires Input Monitoring; selected-text replacement requires Accessibility. macOS may ask for either permission again after an update. Certificate signing alone does not establish that Accessibility or Input Monitoring grants persist after code changes; no TCC reuse promise is made until the changed code's designated-requirement compatibility and imrse's own authorization for both permissions are proven. Enable imrse individually under each section in System Settings > Privacy & Security, and handle any Keychain prompt personally; do not share passwords or grant a permission you do not recognize.

macOS may block this locally certificate-signed app because it is not notarized; no Developer ID or public-trust claim is made. After that blocked launch, go to System Settings > Privacy & Security > Open Anyway and select the app-specific option for imrse. Confirm the follow-up Open prompt only if you trust this exact app, verified its checksum and provenance through a trusted channel, know it has not been tampered with, and have independently determined it is not malicious; otherwise stop. This is an app-specific exception, not a global security change, and managed Macs may deny it. See Apple's instructions: [Safely open apps on your Mac](https://support.apple.com/en-us/102445). Never remove `com.apple.quarantine`, disable Gatekeeper, or use a command or profile to bypass macOS security checks.

To roll back, quit imrse fully, restore the saved previous `.app` bundle to its original install location, and leave Application Support and Keychain data unchanged. The app has no automatic updater; updates and rollback are manual. Keep the old app bundle until the candidate has passed your own installation, permissions, provider, selection, replacement, and Undo checks. Those runtime checks were not performed while preparing this candidate.
