# Installing or rolling back the local beta candidate

This note applies only to a locally generated `imrse 0.2.0-beta.1` macOS arm64 candidate with app version `0.2.0` and build `13`. Updating this document does not mean an app or archive has been built. Any such candidate is experimental, ad-hoc signed, has no Developer ID signature or notarization ticket, and is not a trusted public release. The presence of an archive does not prove the app is safe or untampered. The declared minimum is macOS 14.0; the packaging host's macOS version is not a minimum-version runtime test. Intel is not supported by this candidate.

Before extracting a copy, verify the archive and manifest from the same trusted handoff directory:

```sh
shasum -a 256 -c SHA256SUMS
```

Only continue when every listed file, including the ZIP, `MANIFEST.json`, `BUILD-PROVENANCE.json`, and `SOURCE-INPUT-MANIFEST.json`, reports `OK` and the handoff came from a source you trust. The checksum detects accidental or untrusted changes only when the checksum itself is obtained through a trusted channel; it does not establish publisher identity. Do not launch an archive whose provenance or integrity is uncertain.

The candidate must be installed manually. Quit the existing imrse instance before replacing its app bundle, save an untouched copy of the previous `.app` bundle somewhere outside the install location, then copy the candidate app into the same install location. Keep only one imrse instance running. The packaging procedure does not alter an installed app, `~/Library/Application Support/imrse/`, or Keychain entries.

Keep `~/Library/Application Support/imrse/` and Keychain entries intact during an update and rollback. The app stores provider configuration in Application Support and credentials in the macOS Keychain; deleting either can remove settings or credentials. Global shortcut capture requires Input Monitoring; selected-text replacement requires Accessibility. macOS may ask for either permission again after an update. Enable imrse individually under each section in System Settings > Privacy & Security, and handle any Keychain prompt personally; do not share passwords or grant a permission you do not recognize.

macOS may block this ad-hoc signed app because it has no Developer ID signature or notarization. After that blocked launch, go to System Settings > Privacy & Security > Open Anyway and select the app-specific option for imrse. Confirm the follow-up Open prompt only if you trust this exact app, verified its checksum and provenance through a trusted channel, know it has not been tampered with, and have independently determined it is not malicious; otherwise stop. This is an app-specific exception, not a global security change, and managed Macs may deny it. See Apple's instructions: [Safely open apps on your Mac](https://support.apple.com/en-us/102445). Never remove `com.apple.quarantine`, disable Gatekeeper, or use a command or profile to bypass macOS security checks.

To roll back, quit imrse fully, restore the saved previous `.app` bundle to its original install location, and leave Application Support and Keychain data unchanged. The app has no automatic updater; updates and rollback are manual. Keep the old app bundle until the candidate has passed your own installation, permissions, provider, selection, replacement, and Undo checks. Those runtime checks were not performed while preparing this candidate.
