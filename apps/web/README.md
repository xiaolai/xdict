# web

The Web build in TypeScript. (The browser extension is in `apps/extension/` and asks the native app, ADR-0008.)
Dictionary files are read in the browser and never uploaded; xdict.ai serves code only. Not started.

## Icons

`icons/` is generated from `apps/apple/Resources/XDict.icon` (`apps/apple/Tools/icons/README.md`). Never edit it by
hand: run `cd apps/apple && make icons`. Where it plugs in, once the site exists, with `icons/` served at `/icons/`:

```html
<link rel="icon" href="/icons/favicon.ico" sizes="16x16 32x32 48x48">
<link rel="icon" href="/icons/icon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/icons/apple-touch-icon.png">
<link rel="mask-icon" href="/icons/safari-pinned-tab.svg" color="#23407A">
<link rel="manifest" href="/manifest.webmanifest">
```

`icon.svg` follows the reader's light or dark appearance. `icons/manifest.webmanifest` names the 192 and 512 icons,
`any` and `maskable`, by paths starting `icons/`. Serve it from the folder that holds `icons/`, at `/manifest.webmanifest`
above, or change the paths with it.
