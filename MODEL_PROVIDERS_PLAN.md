# Curated model providers — implementation scope

## Goal

Make imrse usable without knowing model IDs or endpoint URLs. Offer a small curated text-model library, download and run local models inside the app, connect a ChatGPT account through official OAuth, and retain OpenAI/OpenRouter API keys and an advanced compatible endpoint. No imrse account, hosted backend, telemetry or agent tools are introduced.

This is a provider upgrade, not a rewrite of selection capture, the pill, generation/commit discipline or Undo. All changes remain local and uncommitted until explicitly authorized otherwise.

## Workstreams and ownership

1. **Shared routing contracts.** Preserve version-one configuration and existing providers/presets. Add separate `managedLocal` and `openAIChatGPT` transport kinds, pin their destinations and dispatch to explicit providers. Local-only includes managed native inference and continues to exclude remote fallback. Existing OpenAI-compatible endpoints remain valid.
2. **Managed local runtime.** Use native Apple Silicon inference rather than an external process/server. Begin with two compact/balanced quantized instruct models, identified by verified public manifests, pinned revisions, sizes, hashes and licenses. Installation is explicit, cancellable and atomic; installed assets load offline. Unknown, incomplete or corrupt models never run. Runtime availability and hardware requirements are visible; macOS 14 remains the app deployment target.
3. **OpenAI account connection.** Implement OpenAI's documented OSS/local OAuth registration with browser consent, loopback callback, PKCE, state/nonce and verified OIDC identity. Store credentials in Keychain, refresh rotating credentials atomically, and prevent cancelled/disconnected sessions from restoring tokens. Account inference uses the public Responses API, not private ChatGPT endpoints or borrowed Codex credentials.
4. **Native Models experience.** Replace manual configuration as the primary workflow with a provider browser and compact detail view. Local installation/selection, account connection, API-key connections and model choices use real runtime state. Custom endpoints remain available as an advanced option. Preserve current defaults, preset overrides and explicit fallback behavior.

Local/runtime, authentication and UI work have disjoint mutable ownership. Interfaces are shared before integration; verification uses separate build directories and a final coordinated integrated pass.

## Local safety contract

- No model downloads on launch, selection or first transformation. An explicit Download action shows the expected size and progress.
- Download into app-owned staging only; validate paths, HTTPS/redirect destinations, capacity, sizes and hashes before atomic installation. Cancellation never leaves an installed-looking partial model.
- No implicit hub/network fetch when loading an installed model. Reject unsupported models, unavailable runtime, excessive context and busy/removing assets conservatively.
- Bound context and output, cancel native generation, and release model/cache ownership. Do not log selected/generated text.
- Model removal cannot race an active load or generation. Only app-owned assets are removable.
- Local-only transformations never become cloud requests. No silent switch from subscription usage to paid API usage.

## OpenAI contract

Official documentation: [overview](https://developers.openai.com/siwc/token-sharing-open-source), [sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in), [models/inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference), [preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations).

Use a stable opaque host ID and the issued client ID associated with the verified account. Validate signature, issuer, audience, expiry, nonce, returning-account identity and granted ChatGPT-plan scopes. Browser/callback attempts are bounded and cancellable. Secrets and callback codes never appear in logs, diagnostics or configuration files. OAuth Keychain records use the reserved `oauth:<providerID>` namespace; ordinary API-key lookups cannot read them even if a configuration's transport kind is edited.

Requests use `store: false`, `stream: true`, instructions and user input. Only `response.completed` establishes successful generation; failed/incomplete/interrupted streams cannot commit. Curated choices are checked against the selected account's current model catalog. API-key and subscription connections remain visibly separate. Routing suppresses a ChatGPT account's remote API-key fallback so account failures cannot change billing routes. A local fallback can still be explicitly configured.

## Visual direction

`DESIGN.md` and the original pill kit remain authoritative. The pill and its artwork are untouched. Models is a quiet monochrome native utility view, not a dashboard: compact provider navigation, aligned text and controls, subtle separators, meaningful whitespace and no decorative cards, gradients or novelty icons. Primary labels use approximately 13-point system text; supporting copy/actions use approximately 11 points. Native selection, focus rings, destructive confirmations and accessible status labels carry interaction state.

At the current 660 × 500 content size, the selected provider and its primary action must be visible without searching below the fold. Detail content can scroll; progress and connection status must not shift the main controls. Use task-oriented model descriptions rather than unsupported rankings. Preview fixtures remain clearly disabled and cannot persist, access Keychain, open a browser, download, request permissions or invoke a provider.

## Acceptance and non-goals

Synthetic tests cover routing/privacy, download integrity/atomicity/cancellation/removal, runtime limits/cancellation, OAuth validation/session races, refresh/sign-out, catalog parsing and Responses terminal events. Narrow tests precede strict integrated Debug/Release suites and packaging. Inspect actual native UI and a relocated bundle's resources. Run a non-sensitive real local inference probe when feasible, without host writes or user credentials.

Human consent is required for a real ChatGPT login or API key. Host replacement/Undo, physical shortcut delivery, installed Keychain/TCC, VoiceOver/IME/Spaces and Developer ID/notarization remain separate gates. Do not convert compilation or rendering fixtures into a claim that those passed.

No fine-tuning, arbitrary model imports, model marketplace, background updates, benchmark leaderboard, multi-account manager, inference daemon, chat history, tools or filesystem agent behavior in this scope. The curated shortlist can evolve after text-transformation evaluation; initial inclusion is not proof that a model is best.
