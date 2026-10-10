# dictator-site

Angular (standalone, zoneless, strict TypeScript) app, prerendered to static files with `outputMode: "static"`.

    pnpm install
    pnpm build   # output: dist/site/browser
    pnpm dlx wrangler pages deploy dist/site/browser --project-name dictator-site --branch main
