#!/usr/bin/env python3
"""**The reading style's defect ledger** (`style-ledger.tsv`, beside this file): every defect seen gets a row before it
is fixed, and is closed with the guard that holds it and the commit that fixed it.

    ledger.py list [--open]           the rows, or only the open ones
    ledger.py show <id>               one row, field by field
    ledger.py repro <id> [--theme T]  Tools/gallery/hot.sh on the row's entries (`--dry-run` prints the command)
    ledger.py check                   fails on a malformed ledger: see `problems`
    ledger.py triage <report.json>    maps a gallery report's failures to rows; prints `NEW: …` for the rest, exit 0

A guard is a gallery check (`G14`; a lab check id such as `strayMarker`), a Swift test `Type.method`, or a core test
`crate::test_name`. `--ledger` and `--root` (the repository) are for the tests.
"""
import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
COLUMNS = ["id", "opened", "symptom", "repro", "mechanism", "rule", "fix_at", "guard", "status", "commit"]
STATUSES = {"open", "fixed", "wontfix"}
THEMES = {"light", "dark", "sepia"}
# `dict:key[@theme]`: a gallery short name (or a 297 file's 12-hex id); `*` for any entry of it. A key may start with
# `@` (LDOCE's `@verbs_dial_2`); only a trailing `@light`, `@dark` or `@sepia` is a theme.
ENTRY = re.compile(r"^(?P<dict>[a-z0-9][a-z0-9-]*):(?P<key>[^,\t:]*[^,\t:@])(?:@(?P<theme>light|dark|sepia))?$")
# What must never be written into a tracked file (AGENTS.md): an absolute home path or an IPv4 address.
PRIVATE = re.compile(r"/Users/|/home/|\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b")
SKIP_DIRS = {".git", "target", ".build", "node_modules", "dev-docs"}


def read(path):
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if not lines or lines[0].split("\t") != COLUMNS:
        sys.exit(f"ledger: {path}: the first line must be the header: {' '.join(COLUMNS)}")
    rows = []
    for number, line in enumerate(lines[1:], start=2):
        fields = line.split("\t")
        rows.append((number, dict(zip(COLUMNS, fields)) if len(fields) == len(COLUMNS) else None, line))
    return rows


def entries(repro):
    """The row's entries as (dict, key, theme), or None when malformed; `-` is none yet."""
    if repro == "-":
        return []
    out = []
    for part in repro.split(","):
        m = ENTRY.match(part.strip())
        if not m:
            return None
        out.append((m["dict"], m["key"].strip(), m["theme"]))
    return out


def source_files(root, top, suffix):
    for base, dirs, files in os.walk(os.path.join(root, top)):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            if name.endswith(suffix):
                yield os.path.join(base, name)


def text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def guard_found(guard, root):
    """Whether the guard exists in the repository, by grep: never assumed."""
    if re.fullmatch(r"G\d+", guard):
        checks = text(os.path.join(root, "apps/apple/Sources/XDictEntryLab/GalleryChecks.swift"))
        return re.search(r"note\('" + guard + r"'", checks) is not None
    m = re.fullmatch(r"([a-z][a-z0-9_]*)::([a-z_][a-z0-9_]*)", guard)
    if m:
        crate = os.path.join("core", m[1].replace("_", "-"))
        fn = re.compile(r"\bfn " + m[2] + r"\s*\(")
        return any(fn.search(text(p)) for p in source_files(root, crate, ".rs"))
    m = re.fullmatch(r"([A-Z][A-Za-z0-9_]*)\.([a-zA-Z_][A-Za-z0-9_]*)", guard)
    if m:
        owner = re.compile(r"\b(struct|enum|class|extension|actor) " + m[1] + r"\b")
        fn = re.compile(r"\bfunc " + m[2] + r"\s*\(")
        return any(owner.search(t) and fn.search(t) for t in map(text, source_files(root, "apps", ".swift")))
    if re.fullmatch(r"[a-z][A-Za-z0-9]*", guard):
        # A lab check id: an invariant (`strayMarker: {}`) or a layout key (`("speakerTight", …`).
        pattern = re.compile(r"['\"]" + guard + r"['\"]|\b" + guard + r": \{\}")
        return any(pattern.search(text(p)) for p in source_files(root, "apps/apple/Sources/XDictEntryLab", ".swift"))
    return False


def commit_exists(sha, root):
    return subprocess.run(["git", "-C", root, "cat-file", "-e", sha + "^{commit}"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def problems(path, root):
    out, seen = [], set()
    if subprocess.run(["git", "-C", root, "rev-parse", "--git-dir"], stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL).returncode != 0:
        return [f"{root} is not a git repository: commits cannot be checked"]
    for number, row, line in read(path):
        where = f"line {number}"
        if row is None:
            out.append(f"{where}: {len(line.split(chr(9)))} fields, not {len(COLUMNS)}")
            continue
        where = f"line {number} ({row['id']})"
        if PRIVATE.search(line):
            out.append(f"{where}: an absolute path or an IP address")
        if not re.fullmatch(r"D\d+", row["id"]):
            out.append(f"{where}: id is not D<n>")
        if row["id"] in seen:
            out.append(f"{where}: duplicate id")
        seen.add(row["id"])
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", row["opened"]):
            out.append(f"{where}: opened is not YYYY-MM-DD")
        if not row["symptom"].strip() or row["symptom"] == "-":
            out.append(f"{where}: no symptom")
        if entries(row["repro"]) is None:
            out.append(f"{where}: malformed repro {row['repro']!r} (want dict:key[@theme],… or -)")
        if not re.fullmatch(r"R\d+|-", row["rule"]):
            out.append(f"{where}: rule is not R<n> or -")
        if row["status"] not in STATUSES:
            out.append(f"{where}: bad status {row['status']!r}")
        if row["status"] == "fixed" and (row["guard"] == "-" or row["commit"] == "-"):
            out.append(f"{where}: fixed without a guard and a commit")
        if row["guard"] != "-" and not guard_found(row["guard"], root):
            out.append(f"{where}: guard {row['guard']!r} is defined nowhere in the repository")
        if row["commit"] != "-" and not (re.fullmatch(r"[0-9a-f]{7,40}", row["commit"])
                                         and commit_exists(row["commit"], root)):
            out.append(f"{where}: commit {row['commit']!r} does not exist")
    return out


def find(path, ident):
    for _, row, _ in read(path):
        if row and row["id"] == ident:
            return row
    sys.exit(f"ledger: no row {ident}")


# A gallery failure: "<dict> <mode> <key>: <what>", or "<dict> <light|dark>: G2 …" for a dictionary's dominant size.
def parse_failure(line):
    place, sep, what = line.partition(": ")
    if not sep:
        return None
    words = place.split(" ")
    dictionary = words[0]
    mode = words[1] if len(words) > 1 else ""
    key = " ".join(words[2:]) or None
    m = re.match(r"(G\d+)\b", what)
    check = (m[1] if m else None) or (re.match(r"R invariant (\w+)", what) or [None, None])[1] \
        or (re.search(r"\((\w+) [-\d.]", what) or [None, None])[1] or "other"
    return {"check": check, "dict": dictionary, "key": key, "theme": "dark" if mode.endswith("dark") else "light",
            "what": what}


def triage(path, report):
    import json
    with open(report, encoding="utf-8") as f:
        failures = json.load(f).get("failures", [])
    rows = [row for _, row, _ in read(path) if row]
    seen, known, new = set(), 0, 0
    for line in failures:
        f = parse_failure(line)
        if f is None:
            print(f"NEW: other ? — unparsed failure, not in the ledger: {line[:200]}")
            new += 1
            continue
        mark = (f["check"], f["dict"], f["key"])
        if mark in seen:
            continue
        seen.add(mark)
        hits = []
        for row in rows:
            if row["guard"] != f["check"]:
                continue
            listed = entries(row["repro"]) or []
            if any(d == f["dict"] and k == f["key"] for d, k, _ in listed):
                hits.append((row, "exact"))
            elif any(d == f["dict"] for d, _, _ in listed) or not listed:
                hits.append((row, "same check" if not listed else "same dictionary"))
        entry = f"{f['dict']}:{f['key'] or '*'}"
        if hits:
            known += 1
            for row, how in hits:
                print(f"KNOWN: {f['check']} {entry} — {row['id']} ({row['status']}, {how}): {row['symptom']}")
        else:
            new += 1
            print(f"NEW: {f['check']} {entry} — not in the ledger")
    print(f"ledger triage: {len(seen)} distinct failures, {known} known, {new} new"
          + (" — file a row for each NEW before fixing it" if new else ""))


def main(argv):
    p = argparse.ArgumentParser(prog="ledger.py", description="The reading style's defect ledger.")
    p.add_argument("--ledger", default=os.path.join(HERE, "style-ledger.tsv"))
    p.add_argument("--root", default=os.path.abspath(os.path.join(HERE, "../../../..")))
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list").add_argument("--open", action="store_true")
    sub.add_parser("show").add_argument("id")
    r = sub.add_parser("repro")
    r.add_argument("id")
    r.add_argument("--theme", choices=sorted(THEMES))
    r.add_argument("--dry-run", action="store_true")
    sub.add_parser("check")
    sub.add_parser("triage").add_argument("report")
    a = p.parse_args(argv)

    if a.cmd == "list":
        for _, row, line in read(a.ledger):
            if row is None:
                print(f"?\t{line}")
            elif not a.open or row["status"] == "open":
                print(f"{row['id']:<5} {row['status']:<7} {row['guard']:<12.60} {row['symptom']}")
    elif a.cmd == "show":
        row = find(a.ledger, a.id)
        for c in COLUMNS:
            print(f"{c:>9}: {row[c]}")
    elif a.cmd == "repro":
        row = find(a.ledger, a.id)
        listed = entries(row["repro"])
        if listed is None:
            sys.exit(f"ledger: {a.id}'s repro is malformed: {row['repro']!r}")
        named = [(d, k, t) for d, k, t in listed if k != "*"]
        for d, k, _ in listed:
            if k == "*":
                print(f"ledger: {a.id} names {d}:* (no entry yet); add a key to its repro to render it", file=sys.stderr)
        if not named:
            sys.exit(f"ledger: {a.id} has no entry to render yet")
        theme = a.theme or next((t for _, _, t in named if t), None)
        command = [os.path.join(HERE, "hot.sh")] + [f"{d}:{k}" for d, k, _ in named]
        if theme:
            print(f"ledger: hot.sh renders every mode; look at the *-{theme}.jpg pictures")
        if a.dry_run:
            print(" ".join(command))
            return 0
        return subprocess.run(command).returncode
    elif a.cmd == "check":
        found = problems(a.ledger, a.root)
        for line in found:
            print(f"ledger: {line}", file=sys.stderr)
        rows = [row for _, row, _ in read(a.ledger) if row]
        counts = {s: sum(r["status"] == s for r in rows) for s in sorted(STATUSES)}
        print(f"ledger check: {len(rows)} rows ({', '.join(f'{v} {k}' for k, v in counts.items())}), "
              f"{len(found)} problems")
        return 1 if found else 0
    elif a.cmd == "triage":
        triage(a.ledger, a.report)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
