#!/usr/bin/env python3
"""The reading frame's gallery page from `XDictEntryLab --gallery`'s report: one row per dictionary, before and after
side by side in light and dark, with the measured numbers. Usage: page.py <report.json> <index.html>. Images stay
beside the page, in `images/`."""
import html
import json
import sys
from collections import defaultdict
from statistics import mean


def num(rows, mode, key):
    values = [r["measure"][key] for r in rows if r["mode"] == mode and isinstance(r.get("measure"), dict)
              and isinstance(r["measure"].get(key), (int, float)) and r["measure"][key] == r["measure"][key]
              and abs(r["measure"][key]) != float("inf")]
    return mean(values) if values else None


def contained(rows, mode):
    values = [r["measure"].get("fixedContained") for r in rows if r["mode"] == mode and isinstance(r.get("measure"), dict)]
    return f"{values.count(True)}/{values.count(False)}/{values.count(None)}"


def lowest(rows, mode):
    """Computed contrast (colour against the background behind it), not pixels: the JPEG tile measure under-reads thin
    strokes (NCECD's transcription measured #707080 where its computed colour is #a3a3a8, 6.64:1)."""
    found = [r["measure"]["lowestContrast"] for r in rows if r["mode"] == mode and isinstance(r.get("measure"), dict)
             and isinstance(r["measure"].get("lowestContrast"), dict)]
    if not found:
        return "–"
    worst = min(found, key=lambda f: f["ratio"])
    return f"{worst['ratio']}:1 ({html.escape(worst['colour'])} on {html.escape(worst['background'])})"


def _marks(rows, mode):
    return [r["marks"] for r in rows if r["mode"] == mode and isinstance(r.get("marks"), dict)]


def marks_sum(rows, mode, key):
    return sum(m.get(key) or 0 for m in _marks(rows, mode))


def marks_leaks(rows, mode):
    return sum(len(m.get("leaks") or []) for m in _marks(rows, mode))


def marks_mismatch(rows, mode):
    return sum(len(m.get("foldMismatch") or []) for m in _marks(rows, mode))


def marks_low(rows, mode):
    found = [m["labelLowest"] for m in _marks(rows, mode) if isinstance(m.get("labelLowest"), (int, float))]
    return f"{min(found)}:1" if found else "–"


def totals(report):
    """The whole gallery's marks, for the page's head."""
    out = {}
    for mode in ("core-light", "core-dark"):
        ms = _marks(report["rows"], mode)
        lows = [m["labelLowest"] for m in ms if isinstance(m.get("labelLowest"), (int, float))]
        out[mode] = {"renders": len(ms), "marked": sum(m.get("marked") or 0 for m in ms),
                     "leaks": sum(len(m.get("leaks") or []) for m in ms), "labels": sum(m.get("labels") or 0 for m in ms),
                     "labelLowest": min(lows) if lows else None, "heads": sum(m.get("heads") or 0 for m in ms),
                     "stated": sum(m.get("stated") or 0 for m in ms), "clicked": sum(m.get("clicked") or 0 for m in ms),
                     "mismatch": sum(len(m.get("foldMismatch") or []) for m in ms)}
        ls = [r["layout"] for r in report["rows"] if r["mode"] == mode and isinstance(r.get("layout"), dict)]
        out[mode].update({"dotWorst": max([l.get("dotWorst") or 0 for l in ls] or [0]),
                          "pronOff": sum(l.get("pronOff") or 0 for l in ls), "pronTotal": sum(l.get("pronTotal") or 0 for l in ls),
                          "labelGapOver": sum(l.get("labelGapOver") or 0 for l in ls),
                          "foldGapOver": sum(l.get("foldGapOver") or 0 for l in ls),
                          "spacePunct": sum(l.get("spacePunct") or 0 for l in ls)})
    return out


def fmt(v, digits=0):
    return "–" if v is None else f"{v:.{digits}f}"


def main(report_path, out_path):
    report = json.load(open(report_path))
    for extra in sys.argv[3:]:   # later views (frame + core), same entries
        more = json.load(open(extra))
        report["rows"] += more["rows"]
        report["failures"] += more.get("failures", [])
        report["folding"] = more.get("folding", report.get("folding"))
    by_dict = defaultdict(list)
    for row in report["rows"]:
        by_dict[row["dict"]].append(row)
    folding = report.get("folding", {})
    parts = []
    for name in sorted(by_dict):
        rows = by_dict[name]
        overflow = {m: any(r["measure"].get("overflow") for r in rows if r["mode"] == m and isinstance(r.get("measure"), dict))
                    for m in ("before-light", "after-light")}
        fold = folding.get(name)
        fold_text = "–" if fold is None else ("yes" if isinstance(fold, dict) and fold.get("worked") else "NO")
        stats = (
            f"<tr><th></th><th>before</th><th>frame</th><th>frame + core</th></tr>"
            f"<tr><td>left margin px</td><td>{fmt(num(rows, 'before-light', 'left'))}</td><td>{fmt(num(rows, 'after-light', 'left'))}</td><td>{fmt(num(rows, 'core-light', 'left'))}</td></tr>"
            f"<tr><td>right margin px</td><td>{fmt(num(rows, 'before-light', 'right'))}</td><td>{fmt(num(rows, 'after-light', 'right'))}</td><td>{fmt(num(rows, 'core-light', 'right'))}</td></tr>"
            f"<tr><td>dominant size px</td><td>{fmt(num(rows, 'before-light', 'dominant'), 1)}</td><td>{fmt(num(rows, 'after-light', 'dominant'), 1)}</td><td>{fmt(num(rows, 'core-light', 'dominant'), 1)}</td></tr>"
            f"<tr><td>line length (chars)</td><td>{fmt(num(rows, 'before-light', 'lineChars'))}</td><td>{fmt(num(rows, 'after-light', 'lineChars'))}</td><td>{fmt(num(rows, 'core-light', 'lineChars'))}</td></tr>"
            f"<tr><td>overflow</td><td>{'yes' if overflow['before-light'] else 'no'}</td><td>{'yes' if overflow['after-light'] else 'no'}</td></tr>"
            f"<tr><td>XDict font share</td><td>{fmt(num(rows, 'before-light', 'xdictFontShare'), 2)}</td><td>{fmt(num(rows, 'after-light', 'xdictFontShare'), 2)}</td><td>{fmt(num(rows, 'core-light', 'xdictFontShare'), 2)}</td></tr>"
            f"<tr><td>fixed contained (R13): yes/no/undecided</td><td>{contained(rows, 'before-light')}</td><td>{contained(rows, 'after-light')}</td><td>{contained(rows, 'core-light')}</td></tr>"
            f"<tr><td>backgrounds/borders left</td><td></td><td></td><td>{fmt(num(rows, 'core-light', 'boxes'), 1)}</td></tr>"
            f"<tr><td>images on page / shown</td><td></td><td></td><td>{sum(r['measure'].get('images', 0) for r in rows if r['mode'] == 'core-light' and isinstance(r.get('measure'), dict))} / {sum(r['measure'].get('imagesShown', 0) for r in rows if r['mode'] == 'core-light' and isinstance(r.get('measure'), dict))}</td></tr>"
            f"<tr><td>lowest computed contrast, dark (frame + core)</td><td></td><td></td><td>{lowest(rows, 'core-dark')}</td></tr>"
            f"<tr><td>text below 4.5:1, computed, dark</td><td></td><td></td><td>{fmt(num(rows, 'core-dark', 'below45Share'), 3)}</td></tr>"
            f"<tr><td>marked pseudo-elements / dictionary glyphs left</td><td></td><td></td><td>{marks_sum(rows, 'core-light', 'marked')} / {marks_leaks(rows, 'core-light')}</td></tr>"
            f"<tr><td>labels; lowest computed contrast light / dark</td><td></td><td></td><td>{marks_sum(rows, 'core-light', 'labels')}; {marks_low(rows, 'core-light')} / {marks_low(rows, 'core-dark')}</td></tr>"
            f"<tr><td>fold heads / with state / clicked / chevron wrong</td><td></td><td></td><td>{marks_sum(rows, 'core-light', 'heads')} / {marks_sum(rows, 'core-light', 'stated')} / {marks_sum(rows, 'core-light', 'clicked')} / {marks_mismatch(rows, 'core-light')}</td></tr>"
            f"<tr><td>folding</td><td colspan=3>{fold_text}</td></tr>"
        )
        entries = []
        for kind in ("short", "long", "media"):
            shots = {r["mode"]: r for r in rows if r["kind"] == kind}
            if not shots:
                continue
            key = html.escape(next(iter(shots.values()))["key"])
            cells = "".join(
                f"<figure><img loading=lazy src='{html.escape(shots[m]['image'])}' alt='{key} {m}'><figcaption>{m}</figcaption></figure>"
                for m in ("before-light", "after-light", "core-light", "coresans-light", "coreserif-light", "before-dark", "after-dark", "core-dark", "coresans-dark", "coreserif-dark") if m in shots)
            entries.append(f"<div class=entry><h3>{kind}: {key}</h3><div class=shots>{cells}</div></div>")
        parts.append(f"<section><h2>{html.escape(name)}</h2><table class=stats>{stats}</table>{''.join(entries)}</section>")
    failures = "".join(f"<li>{html.escape(f)}</li>" for f in report.get("failures", []))
    page = f"""<!doctype html><html lang=en><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>XDict reading frame: before and after</title>
<style>
:root{{color-scheme:light dark;--bg:#fff;--fg:#1d1d1f;--muted:#6e6e73;--line:#d2d2d7}}
@media (prefers-color-scheme:dark){{:root{{--bg:#1c1c1e;--fg:#f5f5f7;--muted:#a1a1a6;--line:#3a3a3c}}}}
body{{margin:0;padding:24px;background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,"PingFang SC",sans-serif}}
h1{{font-size:24px}} h2{{border-top:1px solid var(--line);padding-top:16px}} h3{{font-size:14px;color:var(--muted)}}
.stats{{border-collapse:collapse;font-size:13px}} .stats td,.stats th{{padding:2px 10px;border-bottom:1px solid var(--line);text-align:right}}
.stats td:first-child{{text-align:left}}
.shots{{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:10px}}
figure{{margin:0}} img{{width:100%;border:1px solid var(--line);border-radius:6px}} figcaption{{font-size:12px;color:var(--muted)}}
</style>
<h1>XDict reading frame: before and after</h1>
<p>Before: the dictionary as it styles itself. After: the shell's reading frame alone (reading-style.md §1 tokens, R1, R10, R13), without the core's normalization; frame = Sans (the default before P18), serif = the Serif face (ADR-0010 Q7); core = frame + the core's normalization (merged tree), in New York since parity P18; coresans = the same in Sans (coreserif: Serif before P18). Window 820×900 points; numbers are light-mode means over the
three entries.</p>
<h2>Marks (icon sweep §8)</h2><pre>{html.escape(json.dumps(totals(report), indent=1))}</pre>
{''.join(parts)}
<h2>Failures</h2><ul>{failures or '<li>none</li>'}</ul>
</html>"""
    open(out_path, "w").write(page)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
