#!/usr/bin/env python3
"""The app's third-party notices (plan-macos-v1 WI-10): `Resources/Acknowledgments.txt`, shipped in the bundle and
shown by XDict ▸ Acknowledgments.

    python3 -I Tools/notices.py generate              rewrite Resources/Acknowledgments.txt (a Mac with cargo)
    python3 -I Tools/notices.py check [--notices F] [--fonts DIR]
                                                      fail unless F is exactly what generate would write, naming every
                                                      linked crate or bundled font it lacks (`make test-tools`)

**What is covered**: every crate the dictionary service links, read from `cargo metadata --locked` for the service's
target (aarch64-apple-darwin): the crates reachable from `xdict-ffi` by normal dependencies (build and dev
dependencies are not linked; proc-macros are kept, conservatively, since their output is). XDict's own crates are ISC
and named once. Each crate's licence texts are the files it ships (LICENSE*, LICENCE*, COPYING*, NOTICE*, UNLICENSE*);
a crate that ships none gets the canonical text of its licence from `Tools/notices/` only where its licence expression
is exactly one listed in SUPPLIED, else the run fails. And every font in `Resources/Fonts` needs its family's
`OFL-<family>.txt` beside it, included verbatim.

**Committed, not generated at bundle time**: the bundle is assembled and signed on a Mac that may hold no cargo
registry, a notice is a legal text worth reviewing in a diff when it changes, and `check` holds the committed file to
the lockfile on every `make test`, so it cannot go stale silently. Identical texts are printed once, with every crate
that ships them listed above.
"""
import argparse
import glob
import hashlib
import json
import os
import subprocess
import sys

APPLE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORE = os.path.join(os.path.dirname(os.path.dirname(APPLE)), "core")
NOTICES = os.path.join(APPLE, "Resources", "Acknowledgments.txt")
FONTS = os.path.join(APPLE, "Resources", "Fonts")
TRIPLE = "aarch64-apple-darwin"
ROOT = "xdict-ffi"
PREFIXES = ("LICENSE", "LICENCE", "COPYING", "NOTICE", "UNLICENSE")
# Licences whose canonical text is complete without a copyright line of the crate's own.
SUPPLIED = {"MPL-2.0": os.path.join(APPLE, "Tools", "notices", "MPL-2.0.txt")}


def fail(why):
    print(f"notices: {why}", file=sys.stderr)
    sys.exit(1)


def linked_crates():
    """(name, version, licence, [texts]) for each registry crate the service links, sorted; XDict's own names."""
    done = subprocess.run(["cargo", "metadata", "--format-version", "1", "--locked", "--filter-platform", TRIPLE],
                          cwd=CORE, capture_output=True, text=True)
    if done.returncode != 0:
        fail(f"cargo metadata failed: {done.stderr.strip()[-600:]}")
    meta = json.loads(done.stdout)
    packages = {p["id"]: p for p in meta["packages"]}
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    roots = [i for i, p in packages.items() if p["name"] == ROOT and p["source"] is None]
    if len(roots) != 1:
        fail(f"expected one workspace crate {ROOT}, found {len(roots)}")
    seen, stack = set(), roots
    while stack:
        here = stack.pop()
        if here in seen:
            continue
        seen.add(here)
        stack.extend(d["pkg"] for d in nodes[here]["deps"] if any(k["kind"] is None for k in d["dep_kinds"]))
    own = sorted(packages[i]["name"] for i in seen if packages[i]["source"] is None)
    crates, missing = [], []
    for i in seen:
        p = packages[i]
        if p["source"] is None:
            continue
        folder = os.path.dirname(p["manifest_path"])
        files = sorted(f for f in glob.glob(os.path.join(folder, "*"))
                       if os.path.isfile(f) and os.path.basename(f).upper().startswith(PREFIXES))
        texts = [read(f) for f in files]
        if not texts and p.get("license") in SUPPLIED:
            texts = [read(SUPPLIED[p["license"]])]
        if not texts:
            missing.append(f"{p['name']} {p['version']} ({p.get('license')})")
        crates.append((p["name"], p["version"], p.get("license") or "unstated", texts))
    if missing:
        fail("no licence text for: " + ", ".join(sorted(missing))
             + " — add its licence's canonical text to Tools/notices/ and SUPPLIED, once checked")
    return own, sorted(crates, key=lambda c: (c[0], c[1]))


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().strip() + "\n"


def fonts(folder):
    """{family: OFL text} for each bundled font's family; fails naming a font with no notice beside it."""
    faces = sorted(f for f in os.listdir(folder) if f.lower().endswith((".ttf", ".otf", ".ttc")))
    families, missing = {}, []
    for face in faces:
        family = face.split("-")[0].rsplit(".", 1)[0]
        notice = os.path.join(folder, f"OFL-{family}.txt")
        if os.path.isfile(notice):
            families[family] = read(notice)
        else:
            missing.append(f"{face} (no OFL-{family}.txt)")
    if missing:
        fail("bundled fonts without their notice: " + ", ".join(missing))
    return families


def render(own, crates, families):
    out = ["XDict — third-party notices", "",
           "XDict is ISC-licensed. Its dictionary service links the Rust crates below; its entries use the fonts below.",
           f"XDict's own crates: {', '.join(own)}.", "", "Fonts", "====="]
    for family in sorted(families):
        out.append(f"font {family} (SIL Open Font License 1.1)")
    out += ["", "Rust crates", "==========="]
    for name, version, licence, _ in crates:
        out.append(f"crate {name} {version} ({licence})")
    out += ["", "License texts", "============="]
    for family in sorted(families):
        out += ["", f"--- font {family}", "", families[family].rstrip()]
    users, order = {}, []
    for name, version, _, texts in crates:
        for text in texts:
            key = hashlib.sha256(text.encode()).hexdigest()
            if key not in users:
                users[key] = (text, [])
                order.append(key)
            users[key][1].append(f"{name} {version}")
    for key in order:
        text, names = users[key]
        out += ["", f"--- {', '.join(names)}", "", text.rstrip()]
    return "\n".join(out) + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["generate", "check"])
    parser.add_argument("--notices", default=NOTICES)
    parser.add_argument("--fonts", default=FONTS)
    args = parser.parse_args()
    families = fonts(args.fonts)
    own, crates = linked_crates()
    wanted = render(own, crates, families)
    if args.mode == "generate":
        with open(args.notices, "w", encoding="utf-8") as f:
            f.write(wanted)
        print(f"notices: {len(crates)} crates, {len(families)} font families -> {os.path.relpath(args.notices, APPLE)}")
        return
    have = read(args.notices) if os.path.isfile(args.notices) else ""
    if have == wanted:
        print(f"notices: {len(crates)} linked crates and {len(families)} font families, each with its notice")
        return
    lines = set(have.splitlines())
    lacking = [f"crate {n} {v}" for n, v, _, _ in crates if not any(l.startswith(f"crate {n} {v} ") for l in lines)]
    lacking += [f"font {f}" for f in sorted(families) if not any(l.startswith(f"font {f} ") for l in lines)]
    fail(f"{os.path.relpath(args.notices, APPLE)} is stale"
         + (f"; it lacks {', '.join(lacking)}" if lacking else " (a text or a version changed)")
         + ": python3 -I Tools/notices.py generate")


if __name__ == "__main__":
    main()
