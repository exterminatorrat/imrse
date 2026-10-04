# Official provider connections

## Scope

Implement named API-key providers for Anthropic/Claude, DeepSeek, Google Gemini,
xAI/Grok, Mistral, Together AI, Fireworks AI, and Cerebras. Preserve OpenAI,
OpenRouter, managed local models, compatible endpoints, presets, and existing
configuration. Groq is explicitly excluded.

Add official account connections for OpenRouter (PKCE-issued API key), Hugging
Face (OAuth inference scope), and GitHub Copilot (official authenticated runtime).
Keep the existing ChatGPT account connection. Never advertise Claude consumer
subscription access or Gemini consumer subscriptions as API entitlement.

## Architecture and ownership

1. Provider contracts and API services: add explicit Anthropic and account
   transport kinds, token-free OAuth client metadata, a named official API
   catalog, native Anthropic Messages streaming, dispatch and validation.
   Other named API providers reuse the existing compatible transport with pinned
   known destinations. Custom compatible destinations remain supported.
2. Account services: implement bounded official authorization, PKCE/state,
   callback validation, scope checks, credential refresh where supported,
   disconnect, identity/model discovery and account HTTP inference. Store secrets
   under reserved account namespaces, never ordinary API-key identities.
3. Copilot runtime: use only the official documented runtime/SDK protocol, with
   explicit user authorization, no ambient login, no tools, MCP, skills,
   filesystem context, or persisted transformation history. Do not install the
   runtime or register an external OAuth application automatically. If the
   installed runtime cannot enforce these constraints, fail closed.
4. Native app: extend existing provider sheets and AppModel lifecycle; distinguish
   account access from API billing, permit explicit model IDs, show unmet client
   registration/runtime prerequisites, and integrate provider removal and
   cancellation. Keep existing settings chrome and unrelated user edits intact.

Build workers own disjoint service files. A separate UI worker owns app changes
after service interfaces settle. All workers use the local device. No commits,
pushes, external app registrations, or real billable inference are authorized by
this implementation request.

## Acceptance criteria

- Every named API provider has the correct endpoint, auth method, model selection,
  billing copy and dispatch. Groq never appears in the provider catalog.
- Native Anthropic streams only final text and requires a successful terminal
  event. Reject malformed/error/truncated/tool/reasoning-only output; enforce
  request/output limits and cancellation.
- Existing version-one files decode unchanged; optional new metadata contains no
  credentials. Invalid kind/destination/client combinations fail validation.
- Account credentials cannot be read by changing a provider to API-key transport.
  OAuth redirects, state, PKCE and required scopes are validated; refresh and
  disconnect races cannot resurrect credentials.
- Account routes never silently change billing accounts or fall back to remote
  API-key routes. Local-only mode rejects all remote account/API destinations.
- Copilot cannot execute commands, access files, inherit user credentials, attach
  workspace context, or preserve text history. Unsupported/missing runtime is a
  clear prerequisite, never an unsafe fallback.
- Settings handles sign-in, cancel, disconnect, save/select model and removal.
  Missing public OAuth app IDs are explicit. Keys/tokens never enter config,
  diagnostics, logs, process arguments or screenshots.

## Verification sequence

1. Write focused deterministic tests before each new parser/lifecycle/routing path.
2. Run narrow provider, account, routing and configuration tests with fixture
   transports; no real user keys or host writes.
3. Run native app/settings tests and strict compiler checks, then related/full
   suites for cross-cutting contracts.
4. Package the native app and inspect the rendered Add Provider and editor sheets
   in isolated preview mode; capture public-safe evidence.
5. Review account/routing/privacy changes independently and fix substantive
   findings. Report deterministic verification separately from live login and
   provider inference, which require user registrations/consent/runtime.

## External prerequisites

Hugging Face and GitHub require Immers-owned public OAuth client registrations.
The code must accept token-free client IDs and expose setup requirements rather
than ship borrowed client IDs. OpenRouter supports local PKCE callbacks without
that registration. Copilot is not installed on this device at plan creation.
Live account/inference testing is therefore a separate, explicitly reported gate.
