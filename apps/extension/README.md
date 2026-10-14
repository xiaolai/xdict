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
