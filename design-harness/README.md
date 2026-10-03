# Design harness

The standalone HTML preview is retired. The supplied React preview in [`pill-kit/web`](../pill-kit/web/) is the visual source of truth; do not rebuild the pill from the retired screenshots.

Start with the [pill-kit README](../pill-kit/README.md), [approved design contract](../pill-kit/DESIGN.md), and [integration instructions](../pill-kit/CAPY-INTEGRATION.md). The preview's own callbacks are explicitly simulated and must never be wired into the native backend.

Run the supplied checks from the React preview directory:

```sh
cd pill-kit/web
npm install
npm run typecheck
npm test
npx playwright install chromium
npm run test:browser
npm run build
```

The previous HTML files and their local dependency folder are preserved as a scratch backup on the author's device; they are not an active preview or validation target.
