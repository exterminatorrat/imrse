# Security and privacy

## Threat model

imrse handles selected text, provider credentials and a temporary ability to write back into another application. The principal risks are sending private text to an unintended endpoint, insecure credential persistence, writing into the wrong field, treating a truncated model response as complete, and exposing content in logs or diagnostic reports.

The local user and operating system are trusted. Providers receive the selected text and transformation instruction by design; a cloud provider's own retention policy is outside imrse's control. A loopback provider may itself forward requests remotely: local-only guarantees imrse's endpoint routing, not third-party server behavior.

## Boundaries

- Capture and replacement reject secure inputs. This is defense in depth, not a claim that every application's custom password widget exposes perfect AX metadata.
- Only selection context exists in v0.1. No screenshots, document-wide context, clipboard ingestion, imrse account, telemetry or imrse backend exists. An optional OpenAI account connection authorizes provider inference, not access to ChatGPT conversations.
- Credentials are supplied through Keychain to an individual provider request. They are not stored in configuration, presets, logs or reports.
- Local-only permits verified managed on-device inference or loopback hosts, forbids remote fallback, and must reject cross-boundary redirects. Other endpoints require HTTPS except local loopback HTTP for local inference.
- Output is collected and validated before a single commit. Malformed, interrupted, empty or oversized output never becomes a successful transformation.
- Original text and the latest replacement remain in volatile memory for conservative undo. Quit clears them. Configuration and presets are user content on disk; system backups may copy those files.
- Clipboard replacement is disabled by default. When enabled it takes a temporary multi-type snapshot, validates focus and target around a bounded paste, and restores only if no independent clipboard change occurred. Some pasteboard types use lazy/promised data that cannot be perfectly reproduced.
- No automatic retry to a different provider unless a preset explicitly allows a safe eligible fallback. Authentication and invalid requests should be actionable rather than repeatedly resubmitted.

## Model and account connections

Managed models use fixed public repositories/revisions and artifact sizes/SHA-256 hashes. Downloads require an explicit action and use app-owned staging, constrained redirects and atomic installation. Inference loads verified installed assets offline, bounds input/output and must reject incomplete generation. Models never receive tool, shell, filesystem or network privileges. The model library contains weights/tokenizer data, not transformation history.

OpenAI account login uses browser consent with a loopback callback, PKCE, state/nonce checks and signed OIDC identity validation. Tokens are isolated in the reserved `oauth:<providerID>` Keychain namespace; API-key lookups cannot read them. A token-free account registration can remain after disconnect so reauthorization uses the correct issued client ID. Refresh, disconnect and cancellation must not let stale completions restore active credentials. Official Responses requests use `store: false` and `stream: true`; that does not replace the provider's applicable data policy. Only completed final-answer text may become replacement content.

ChatGPT-plan connections do not fall back to remote API-key providers, even if a preset names one. API-key and subscription billing are separate choices; account usage limits do not authorize another billing route. Real browser authorization and installed-bundle Keychain access require user consent and separate validation.

## Reports and logging

Reports may include OS/app version, AX permission state, monitoring state, application bundle ID, AX role, selection length, target validity, provider/model, lifecycle stage, strategy and normalized error category. These can still reveal application usage: review a report before sharing it. Reports must never contain selection, generated output, whole field values, API keys, authorization headers, raw HTTP error bodies or pasteboard contents.

## Reporting a vulnerability

Do not put private transformation content or credentials into a public issue. Describe the affected behavior, a minimal non-sensitive reproduction, build version and normalized diagnostic category. Security reports should focus on a concrete boundary failure rather than unverified compatibility assumptions.
