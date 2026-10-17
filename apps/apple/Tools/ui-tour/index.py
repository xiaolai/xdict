#!/usr/bin/env python3
"""The UI tour's review page and route table, from routes.py and the tour's results.json.

    python3 -I index.py <out>            writes <out>/index.html (self-contained; images relative)
    python3 -I index.py <out> --routes   writes <out>/routes.md only (needs no results)
    python3 -I index.py <out> --before <results.json> --label <label>
                                         a before | after page: each route's earlier capture (light only) beside this
                                         round's, `<appearance>-<lang>-<label>`, in light and dark
"""
import html
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from routes import NOT_DRIVEN_WHY, ROUTES  # noqa: E402

out = sys.argv[1]
VARIANTS = ["light-en", "light-zh", "dark-en", "dark-zh"]
options = dict(zip(sys.argv[2::2], sys.argv[3::2])) if "--routes" not in sys.argv else {}


def routes_md():
    lines = ["# XDict macOS UI routes", "",
             "Generated from `apps/apple/Tools/ui-tour/routes.py` (`index.py <out> --routes`). Library `full` is the "
             "lookup fixtures (alpha, beta, records, slow; damaged, gone, locked); `empty` is none.", "",
             "| Route | Library | How a user gets there | What should be visible | Driven |", "|---|---|---|---|---|"]
    for route, library, how, expect, steps in ROUTES:
        driven = "yes" if steps is not None else f"no: {NOT_DRIVEN_WHY.get(route, '')}"
        lines.append(f"| `{route}` | {library} | {how.replace('|', '/')} | {expect.replace('|', '/')} | {driven} |")
    with open(os.path.join(out, "routes.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


CSS = """
:root{color-scheme:light dark;--bg:#f5f5f7;--card:#fff;--fg:#1d1d1f;--muted:#6e6e73;--line:#d2d2d7;--bad:#d70015;
--warn:#a05a00}
@media(prefers-color-scheme:dark){:root{--bg:#1c1c1e;--card:#2c2c2e;--fg:#f5f5f7;--muted:#a1a1a6;--line:#3a3a3c;
--bad:#ff453a;--warn:#ffb340}}
body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,BlinkMacSystemFont,sans-serif}
header{padding:24px 28px 8px}h1{font-size:22px;margin:0 0 4px}.muted{color:var(--muted)}
main{padding:12px 28px 40px;display:grid;gap:18px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px 18px}
.card h2{font-size:15px;margin:0 0 4px;font-family:ui-monospace,Menlo,monospace}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px;margin-top:12px}
figure{margin:0}figcaption{font-size:12px;color:var(--muted);margin-bottom:4px}
img{max-width:100%;border:1px solid var(--line);border-radius:6px;background:repeating-conic-gradient(#8881 0 25%,
transparent 0 50%) 0 0/16px 16px}
.fail{color:var(--bad);font-weight:600;white-space:pre-wrap}.warn{color:var(--warn);font-size:12px}
.none{color:var(--muted);font-style:italic;font-size:12px}nav a{margin-right:10px}
.pair{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;margin-top:12px;align-items:start}
@media(max-width:900px){.pair{grid-template-columns:1fr}}
.lang{font-size:12px;font-weight:600;margin-top:12px}
"""


def page():
    results = json.load(open(os.path.join(out, "results.json")))
    by = {(r["variant"], r["route"]): r for r in results}
    failures = sum(1 for r in results if r.get("failure"))
    shots = sum(len(r.get("shots", [])) for r in results)
    cards = []
    for route, library, how, expect, steps in ROUTES:
        body = [f"<h2 id='{route}'>{html.escape(route)}</h2>",
                f"<div><b>How:</b> {html.escape(how)} <span class='muted'>(library: {library})</span></div>",
                f"<div><b>Should show:</b> {html.escape(expect)}</div>"]
        if steps is None:
            body.append(f"<div class='none'>Not driven: {html.escape(NOT_DRIVEN_WHY.get(route, ''))}</div>")
        else:
            figures = []
            seen = sorted({v for (v, name) in by if name == route}) or VARIANTS
            for variant in seen:
                r = by.get((variant, route))
                caption = variant + (" (before)" if any(v == f"{variant}-after" for v in seen) else "")
                inner = [f"<figcaption>{html.escape(caption)}</figcaption>"]
                if r is None:
                    inner.append("<div class='none'>not run</div>")
                else:
                    for shot in r.get("shots", []):
                        src = html.escape(f"{variant}/{shot}")
                        inner.append(f"<a href='{src}'><img loading='lazy' src='{src}' alt='{route} {variant}'></a>")
                    if r.get("failure"):
                        inner.append(f"<div class='fail'>{html.escape(r['failure'])}</div>")
                    kinds = {}
                    for found in r.get("findings", []):
                        kinds.setdefault(found["kind"], []).append(found)
                    for kind, items in kinds.items():
                        sample = "; ".join(html.escape(str(i.get("text") or i.get("a") or i["where"]))[:80]
                                           for i in items[:3])
                        inner.append(f"<div class='warn'>AX {kind}: {len(items)} ({sample})</div>")
                figures.append("<figure>" + "".join(inner) + "</figure>")
            body.append("<div class='grid'>" + "".join(figures) + "</div>")
        cards.append("<section class='card'>" + "".join(body) + "</section>")
    nav = "".join(f"<a href='#{r[0]}'>{r[0]}</a>" for r in ROUTES)
    doc = (f"<!doctype html><html lang='en'><meta charset='utf-8'><meta name='viewport' "
           f"content='width=device-width,initial-scale=1'><title>XDict UI tour</title><style>{CSS}</style>"
           f"<header><h1>XDict UI tour</h1><div class='muted'>{len(ROUTES)} routes, {shots} captures, "
           f"{failures} failures. Red: the route could not be walked. Amber: what the accessibility tree flags "
           f"(truncation is not in the tree; look at the picture).</div><nav class='muted'>{nav}</nav></header>"
           f"<main>{''.join(cards)}</main></html>")
    with open(os.path.join(out, "index.html"), "w") as f:
        f.write(doc)


def figure(variant, record, route, caption):
    inner = [f"<figcaption>{html.escape(caption)}</figcaption>"]
    if record is None:
        inner.append("<div class='none'>not captured</div>")
    else:
        for shot in record.get("shots", []):
            src = html.escape(f"{variant}/{shot}")
            inner.append(f"<a href='{src}'><img loading='lazy' src='{src}' alt='{route} {variant}'></a>")
        if record.get("failure"):
            inner.append(f"<div class='fail'>{html.escape(record['failure'])}</div>")
    return "<figure>" + "".join(inner) + "</figure>"


def compared(before_path, label):
    """Each route, per language: the earlier capture (light; Settings from its own later round where it has one), then
    this round's light and dark."""
    before = {(r["variant"], r["route"]): r for r in json.load(open(before_path))}
    after = {(r["variant"], r["route"]): r for r in json.load(open(os.path.join(out, "results.json")))}
    failures = sum(1 for r in after.values() if r.get("failure"))
    shots = sum(len(r.get("shots", [])) for r in after.values())
    cards = []
    for route, library, how, expect, steps in ROUTES:
        body = [f"<h2 id='{route}'>{html.escape(route)}</h2>",
                f"<div><b>How:</b> {html.escape(how)} <span class='muted'>(library: {library})</span></div>",
                f"<div><b>Should show:</b> {html.escape(expect)}</div>"]
        if steps is None:
            body.append(f"<div class='none'>Not driven: {html.escape(NOT_DRIVEN_WHY.get(route, ''))}</div>")
        for lang in ("en", "zh"):
            if steps is None:
                break
            earlier = next(((v, before[(v, route)]) for v in (f"light-{lang}-after", f"light-{lang}")
                            if (v, route) in before), (f"light-{lang}", None))
            row = [figure(earlier[0], earlier[1], route, f"before ({earlier[0]})")]
            for appearance in ("light", "dark"):
                variant = f"{appearance}-{lang}-{label}"
                row.append(figure(variant, after.get((variant, route)), route, f"after, {appearance}"))
            body.append(f"<div class='lang'>{'English' if lang == 'en' else 'Chinese'}</div>"
                        "<div class='pair'>" + "".join(row) + "</div>")
        cards.append("<section class='card'>" + "".join(body) + "</section>")
    nav = "".join(f"<a href='#{r[0]}'>{r[0]}</a>" for r in ROUTES)
    doc = (f"<!doctype html><html lang='en'><meta charset='utf-8'><meta name='viewport' "
           f"content='width=device-width,initial-scale=1'><title>XDict UI tour: before and after</title>"
           f"<style>{CSS}</style><header><h1>XDict UI tour: before | after</h1><div class='muted'>{len(ROUTES)} routes; "
           f"this round {shots} captures, {failures} failures. Before: the review's light captures. After: this "
           f"round, light and dark.</div><nav class='muted'>{nav}</nav></header><main>{''.join(cards)}</main></html>")
    with open(os.path.join(out, "index.html"), "w") as f:
        f.write(doc)


routes_md()
if "--before" in options:
    compared(options["--before"], options.get("--label", "fixed"))
elif "--routes" not in sys.argv:
    page()
