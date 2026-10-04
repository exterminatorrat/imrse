# Official model-provider connections

Immers connects directly to the selected provider. It does not host an inference
backend, share credentials between providers, or treat account login as proof of
subscription entitlement. API keys and account credentials stay in Keychain;
configuration contains only model choices, destinations, and public OAuth client
IDs.

## API-key connections

Open **Settings → Models → Add provider → API keys**. Choose the provider, supply
its API key and an exact text-generation model ID, and save the selection. An API
key connection uses that provider's API quota/billing, not a consumer chat plan.

| Provider | Base destination | Transport |
| --- | --- | --- |
| OpenAI | `https://api.openai.com/v1` | OpenAI chat completions |
| OpenRouter | `https://openrouter.ai/api/v1` | OpenAI-compatible chat completions |
| Anthropic / Claude | `https://api.anthropic.com/v1` | Native Messages streaming |
| DeepSeek | `https://api.deepseek.com` | Compatible `/chat/completions` |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta/openai` | Official OpenAI-compatible API |
| Grok / xAI | `https://api.x.ai/v1` | Compatible chat completions |
| Mistral | `https://api.mistral.ai/v1` | Compatible chat completions |
| Together AI | `https://api.together.ai/v1` | Compatible chat completions |
| Fireworks AI | `https://api.fireworks.ai/inference/v1` | Compatible chat completions |
| Cerebras | `https://api.cerebras.ai/v1` | Compatible chat completions |

Model IDs are provider-specific. A catalog or suggested ID does not establish
that a key can use it. Use the provider's current model list and account access
rules. Groq is not a named provider in this expansion; Grok is the xAI route.

Claude uses its native Messages protocol so its text, thinking, tool and terminal
events are handled separately. A Claude Pro/Max subscription is not a Claude API
key. Anthropic's third-party authentication policy does not permit Immers to
offer consumer Claude login or borrow Claude Code credentials.

## Account connections

Open **Settings → Models → Add provider → Accounts**. Account entries show their
own authorization, prerequisites and billing description. They do not silently
switch to an API-key connection if authorization or inference fails.

### ChatGPT

The existing official ChatGPT OAuth route requests permission for plan-backed
Responses API inference. Successful identity login alone is insufficient: the
account must grant the plan-use scope and the chosen model must be available to
that account. OpenAI currently documents this flow for eligible open-source and
locally hosted apps; paid or remotely hosted distribution needs the applicable
OpenAI access approval.

### OpenRouter

Browser authorization uses PKCE and a local callback. OpenRouter issues a
user-controlled API key after approval, which Immers stores separately from
manually entered API keys. Requests use OpenRouter credits/API billing; this
does not use a ChatGPT, Claude or Gemini subscription. No borrowed OAuth app
registration is required for the local PKCE flow.

### Hugging Face

This route requires an Immers-owned **public OAuth app**, with no embedded
client secret. Register a loopback redirect matching
`http://127.0.0.1/auth/callback`; Hugging Face permits the actual local port to
vary. Enter the public client ID in the account sheet. The requested scopes are
`openid`, `profile`, and `inference-api`.

The connection uses Hugging Face Inference Providers. Applicable account/plan
compute credits can be consumed, followed by paid usage under Hugging Face's
billing rules. It is not unlimited subscription inference and does not run the
model on the user's Mac.

### GitHub Copilot

This route requires an Immers-owned GitHub OAuth application with device flow
enabled and a compatible official Copilot runtime installed separately. Enter
the public client ID, authorize the displayed device code in GitHub, and choose
a text model supported by the user's Copilot plan and organization policies.

The native adapter requires protocol version 3 and the verified runtime baseline
`1.0.83-2` or a compatible newer stable release. Older or unverified prerelease
runtimes fail before receiving credentials or selected text. The baseline was
checked against the official Darwin ARM64 artifact; an installed-runtime probe
is still needed before advertising live account inference as verified.

Immers does not install the runtime, reuse its cached login, or read GitHub CLI
credentials. The runtime integration must operate without tools, MCP, skills,
workspace context, ambient authorization or disk transcripts. A missing or
unsupported runtime is a prerequisite failure, not permission to use private
Copilot HTTP endpoints or weaken those restrictions.

Public OAuth application registrations, runtime installation and live account
consent are separate deployment/verification steps. Fixture tests do not prove
that a real account is entitled to inference.

## Existing local and custom routes

Managed local Qwen models remain available on Apple silicon. Ollama and other
local OpenAI-compatible text servers remain usable under **Custom advanced**;
for standard Ollama use `http://localhost:11434/v1`, the exact installed model
tag, and no API key. Multiple entries can select different models on one server.

Local-only mode allows managed inference or a loopback server and rejects remote
account/API connections and remote fallback. A loopback server can itself
forward requests, so Immers cannot promise how third-party local software routes
them. Image-only and embedding models are not text-transformation providers.

## Verification for this implementation

On October 4, 2026, the focused provider/account/runtime suite passed 71 tests.
A clean native build and full suite with Swift warnings treated as errors executed
373 tests, with no failures and one opt-in real Qwen download/inference probe skipped. The
authorized provider-list assertion preserves the original five contexts and
adds the eleven new contexts; no existing test was removed or weakened.

The release packaging script completed, including app resources, the MLX shader,
property-list validation and strict ad-hoc signature verification. The resulting
local bundle is `dist/imrse.app`; it is not installed or notarized. Native provider
picker and account/API sheets were inspected in isolated debug preview mode.

These checks use deterministic HTTP/runtime fixtures. No live provider login,
billable inference, installed Copilot-runtime probe or Linux execution was
performed. Public OAuth app registrations and live validation remain deployment
gates, not results established by these tests.

For the later MacBook rollout, the exact source and regression tests from the
already-merged capture fix in PR #5 were included without redesign. The combined
build passed 88 focused capture/provider tests and a strict full suite of 390
tests, with one opt-in probe skipped and no failures. Packaging passed again,
and the verified bundle was deployed to the MacBook with the previous app kept
for rollback and existing settings/presets unchanged. Harry subsequently approved
proceeding to the provider PR. That approval does not identify which individual
providers completed live login or inference; those outcomes are not asserted here.

## Official references

- [ChatGPT plan usage](https://developers.openai.com/siwc/token-sharing-open-source)
- [Anthropic API](https://platform.claude.com/docs/en/api/overview)
- [Anthropic third-party authentication policy](https://code.claude.com/docs/en/legal-and-compliance)
- [OpenRouter PKCE](https://openrouter.ai/docs/guides/overview/auth/oauth)
- [Hugging Face public OAuth](https://huggingface.co/docs/hub/oauth)
- [Hugging Face inference billing](https://huggingface.co/docs/inference-providers/en/pricing)
- [Copilot SDK authentication](https://docs.github.com/en/copilot/how-tos/copilot-sdk/auth/authenticate)
- [DeepSeek API](https://api-docs.deepseek.com/)
- [Gemini compatibility](https://ai.google.dev/gemini-api/docs/openai)
- [Google AI plan/API separation](https://ai.google.dev/gemini-api/docs/google-ai-plans)
- [xAI API](https://docs.x.ai/overview)
- [Mistral API keys](https://docs.mistral.ai/getting-started/quickstarts/studio/activate-and-generate-api-key)
- [Together API](https://docs.together.ai/docs/quickstart)
- [Fireworks compatibility](https://docs.fireworks.ai/tools-sdks/openai-compatibility)
- [Cerebras compatibility](https://inference-docs.cerebras.ai/resources/openai)
