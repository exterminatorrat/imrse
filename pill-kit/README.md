# imrse pill integration kit

Actual component source for the approved black-and-white imrse pill. This is a
focused UI kit for Capy to integrate into imrse, **not a replacement for imrse's
provider, Accessibility, shortcut or text-replacement architecture**.

Start with **CAPY-INTEGRATION.md**.

## Included

- `native/` — Swift package with `ImrsePillUI` (SwiftUI/AppKit + native Lottie) and
  `ImrsePillCore` (portable state machine and activity/animation sequencing).
- `web/` — Next.js/React interactive preview. Uses the byte-identical upstream
  `SpiralLoader` at `@/components/agent-elements/spiral-loader` and `<SpiralLoader size={24} />`.
- `upstream/` — untouched source files and the upstream MIT license.
- `reference/` — the corrected visual target, not a screenshot of this build.
- `evidence/` — actual checks performed in this session and explicit limitations.

## Run the portable tests (no third-party downloads)

```sh
cd web
node --test tests/*.test.mjs
cd ../native
swift test
```

On Linux, SwiftPM intentionally only builds/tests `ImrsePillCore`. It does NOT
prove that native UI builds. The native UI product is included on macOS.

## Run the React preview

Requires Node 22 or later and network access for the first dependency install.

```sh
cd web
npm install
npm run typecheck
npm run dev
```

Open http://127.0.0.1:3000. Double-Control is a **page-local demo** only; the native
application's real global shortcut handler must invoke the native panel.
`Invoke pill` is a preview-page control, not a persistent production launcher.
The preview's timed completion is explicitly simulated and is not a model call.

For browser tests:

```sh
npx playwright install chromium
npm run test:browser
npm run build
```

No lockfile is fabricated. Resolve dependencies and commit the actual lockfile in
the target environment. Review dependency advisories before shipping.

## Native use

Add `native/` as a local Swift package in Xcode and link `ImrsePillUI`. It resolves
Airbnb's `lottie-ios` package (which includes macOS support) and bundles the original
animation JSON resources locally. The UI never downloads animation assets.

Use `ImrsePillView(model:)` inside your existing panel, or the optional
`PillPanelController` when no panel exists. Do not install two panel owners.

`PillModel` exposes onSubmit/onCancel/onUndo callbacks and generated/applied/failed
methods. The host remains responsible for capturing the target before the panel
appears, provider requests, local/cloud policies, replacement validation and Undo.
See CAPY-INTEGRATION.md for the exact event mapping.

## Honesty about validation

The portable JavaScript/Swift tests ran here. Upstream blob identities and native
asset equivalence were verified. A real Mac was not available. npm dependency
installation was blocked by network/DNS restrictions; React typechecking/build
and Playwright tests are provided but were NOT executed in this session.
Read `evidence/VALIDATION.md` before claiming the UI is verified or integrated.

The linked GitHub repo was read but not modified. This ZIP does not establish
that Capy's private workspace, a branch, or the actual Mac application has changed.
