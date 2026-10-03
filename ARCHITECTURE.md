# Architecture

## Boundaries

`ImrseCore` imports only Foundation. It owns contracts, transformation state, output validation, cancellation and the latest undo receipt. `ImrseServices` owns HTTP providers, routing, account sessions and user-owned files. Its portable paths use Core/Foundation (FoundationNetworking on Linux); OAuth signature/PKCE verification conditionally uses macOS Security/CryptoKit and fails closed when that capability is unavailable. Neither module imports AppKit, SwiftUI or macOS Accessibility.

`ImrseMac` adapts AX, CoreGraphics event monitoring, NSPasteboard and Keychain to the portable contracts. `ImrseApp` owns presentation, native panel behavior, settings and application lifetime. Native targets are excluded from the Linux package graph, not replaced with simulated native implementations.

`ImrseLocal` is a native managed-model target. On Apple silicon it uses pinned MLX Swift LM dependencies, verified local artifacts and bounded native inference; other Mac architectures expose unsupported runtime status. The actor-owned library handles explicit downloads, staging, integrity, installation and removal. A distinct `managedLocal` provider dispatches here rather than to an HTTP endpoint. Local loading never invokes a Hub downloader.

`pill-kit/native` is the supplied local Swift package. `ImrsePillCore` owns presentation IDs/status rhythm; `ImrsePillUI` renders the approved SwiftUI components and original Lottie resources. It does not replace the host transformation engine. The app maps actual engine events into its presentation lifecycle and reuses its existing panel. `pill-kit/web` is the separate React preview; simulated preview callbacks never enter the app target.

`settings-kit` preserves the supplied settings source and reference screenshot as design provenance. The app adapts that presentation to its actual `AppModel`, String-based provider/preset identities and existing services; mock callbacks are not a production dependency. AppKit owns the application lifetime, template status item and one retained 900 × 570 Settings window. Left-click opens that window directly; right/Control-click opens the operational menu. SwiftUI owns its six sidebar destinations, provider/diagnostics sheets and in-memory preset drafts. Hiding the status item switches to a Dock-visible application rather than stranding Settings.

## Data flow

The shortcut handler invokes the engine on MainActor. `SelectionAccess.capture` synchronously identifies the target before any presentation callback. The UI observes engine state; it cannot choose a different target. The app resolves an instruction/provider from loaded settings and submits a request. A provider returns bounded text deltas; the engine accumulates them in memory, validates completion and revalidates the original target before calling the replacement adapter. A successful verified commit yields a single receipt for undo.

The app never types partial responses into a host. There is no content history, persistent transformation queue, background job service or content telemetry.

Provider dispatch distinguishes compatible API endpoints, official ChatGPT-account Responses inference and managed local generation. Account models are filtered against account availability. Local-only permits native inference/loopback, never remote fallback; a ChatGPT primary cannot silently fall back to remote API-key billing. Only completed final output is released for host validation, not reasoning/commentary or token-budget exhaustion.

## Concurrency and ownership

Selection and presentation are MainActor-isolated because macOS responder and AX handles belong to a single adapter owner. Providers and credential stores are Sendable. Generation is an owned cancellable task, not detached work. Cancellation invalidates the active operation before releasing captured content, so late responses cannot commit. Replacement is a small commit phase: do not interrupt a write halfway through or let a second operation start before the first adapter settles.

Targets are opaque snapshot IDs in Core. The AX element and any platform verification details live in the native registry. A receipt contains only the original selection, completed replacement and strategy. No host document is retained in the engine. Undo must revalidate the replacement, application and target; stale targets fail closed.

## Configuration

Application Support stores versioned JSON settings, `default.md`, portable Markdown presets and app-managed `LocalModels`. Keychain stores API keys under stable provider IDs and OAuth sessions under reserved `oauth:<providerID>` keys; configuration/preset JSON never contains credentials. A token-free OAuth registration can remain after sign-out. Read/parse configuration outside streaming loops, use atomic writes, and reload intentionally when user-owned files are edited.

Menu-bar visibility and system/light/dark appearance are persisted configuration preferences. Explicit decoding supplies visible/system defaults for older files; invalid values and undeclared keys remain errors. Login registration is still the real ServiceManagement state, not a stored Boolean. Removing an active account provider disconnects its OAuth session before deleting its token-free registration and rechecks cancellation, termination and preset references before saving.

## Test seams

`SelectionAccess`, `TextProvider` and `CredentialStore` have deterministic test doubles. Services have an injectable transport and incremental SSE parser. Native uncertainty stays behind adapters; a browser harness tests visual intent but is not evidence of NSPanel focus or AX interoperability.
