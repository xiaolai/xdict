# extension

The browser extension for Chrome, Edge and Firefox, in TypeScript: it captures the word under the pointer or the
selection in a web page and shows the answer of the XDict app installed on the same computer, reached through the
browser's native messaging. It never carries the core and never stores a dictionary; without the app it says so.

- Safari's wrapper is built from this source but lives in `apps/apple/`, since a Safari extension ships inside
  an app.
- Each desktop shell owns its native-messaging host and the IPC endpoint the host talks to; nothing here parses
  a dictionary file.
- Entry HTML runs only in a confined renderer with no extension API, never in the page's document, and the
  extension ships in a browser only after that browser passes the hostile-input suite of ADR-0007 decision 14.

Not started.

## Icons

`icons/` is generated from `apps/apple/Resources/XDict.icon` (`apps/apple/Tools/icons/README.md`). Never edit it by
hand: run `cd apps/apple && make icons`. Where it plugs in, once `manifest.json` exists:

```json
"icons": { "16": "icons/icon-16.png", "32": "icons/icon-32.png", "48": "icons/icon-48.png", "128": "icons/icon-128.png" },
"action": {
  "default_icon": { "16": "icons/icon-16.png", "32": "icons/icon-32.png" },
  "theme_icons": [
    { "light": "icons/toolbar-16-light.png", "dark": "icons/toolbar-16-dark.png", "size": 16 },
    { "light": "icons/toolbar-32-light.png", "dark": "icons/toolbar-32-dark.png", "size": 32 }
  ]
}
```

`theme_icons` is Firefox's alone. Its `light` icon is drawn on dark toolbars, and its `dark` icon on light ones. Chrome
and Edge ignore it and show `default_icon`.
