#!/usr/bin/env python3
"""The E2E ledger: what every E2E sub-stage did, when, where, and on which content, and what that lets a run skip.

    e2e-ledger.py record --fact name=value ... --build B --host H --os OS --tree T --mode M  < run log
        files one row per sub-stage of the run log's `RESULT<TAB>sub<TAB>pass|fail[<TAB>check]` lines (pass AND fail),
        with its seconds from `TIME<TAB>sub<TAB>seconds`, under the sub-stage's content key for these facts
    e2e-ledger.py plan [--release] [--max-days N] [--full] [--human] --fact name=value ... <sub-stage ...>
        per sub-stage `carried<TAB>sub<TAB>key<TAB><date> <host> <key-prefix><TAB>seconds` or
        `run<TAB>sub<TAB>key<TAB><why><TAB>seconds`; --human prints a table and the estimated minutes
    e2e-ledger.py show [--last N] [--stage S]       the last N rows (default 30), of one sub-stage or all
    e2e-ledger.py seconds                           `sub<TAB>seconds` of each sub-stage's latest timed row
    e2e-ledger.py failed-since <UTC time>           the sub-stages that failed in rows filed at or after it

**One record of runs, for development and release alike** (owner, 2026-10-17: "keep a ledger for what and when e2e has
done, so that even if we want to release, we could only run absolutely necessary portion of e2e"). A row is

    v1 sub result check key when host os tree mode seconds commit graph build

tab-separated: `check` the first failed check or `-`; `key` the sub-stage's content key (`Tools/gate-cache.py`'s: every
file that reaches the sub-stage by the graph, the hand list and `Tools/e2e-affected.map`, plus the facts) or `-` where
the run's tree is unknown or moved; `host` the E2E Mac's hardware UUID; `os` its macOS version and build; `tree` the
bundle's source tree; `mode` development or release; `commit` HEAD where the tree is HEAD's, else `-`; `graph` `ok` or
`stale`; `build` the bundle's build number.

**The facts are part of every key** and record and plan both refuse without them: `xcode`, `swift` and `rust` of the
host that built the bundle, `macos` (the E2E Mac's build), `corpus` (`gate-cache.py corpus-id`, or `none`). The graph's
own identity (the generated graph, the hand list and the map, digested) is added here, so a redrawn graph changes every
key. Mixed E2E Macs are evidence together exactly when their macOS builds are equal: the key holds the build.

**Carried** means: the latest row whose key equals the sub-stage's key now passed (a later failure on the same key
revokes it), was recorded with a graph that was not stale, and, with --release, is younger than --max-days. Anything
else runs, and says why: no row, the key changed (the first changed input, or the fact), failed last, too old, a stale
graph. **Fail loud**: a ledger that is unreadable or has one malformed line carries nothing; everything runs, and stderr
says why.

The ledger: `$XDICT_E2E_LEDGER` (default ~/.local/share/xdict/e2e-ledger.tsv), outside every checkout and `.build`, so
worktrees share it and `make clean` keeps it; `manifests/<key>` beside it holds the inputs a key stands for (to name
what changed). Appended under a lock: two E2E Macs of one split run file their rows at once.
"""
import datetime
import fcntl
import hashlib
import importlib.util
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
LEDGER = os.environ.get("XDICT_E2E_LEDGER") or os.path.expanduser("~/.local/share/xdict/e2e-ledger.tsv")
MANIFESTS = os.path.join(os.path.dirname(LEDGER), "e2e-manifests")
REQUIRED_FACTS = ("xcode", "swift", "rust", "macos", "corpus")
FIELDS = ("v", "sub", "result", "check", "key", "when", "host", "os", "tree", "mode", "seconds", "commit", "graph", "build")
PATTERNS = {
    "v": r"v1", "sub": r"[a-z0-9.:-]+", "result": r"pass|fail", "check": r"[^\t]+", "key": r"[0-9a-f]{64}|-",
    "when": r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", "host": r"[A-Za-z0-9-]+", "os": r"[^\t]+", "tree": r"[0-9a-f]{40,64}|-",
    "mode": r"development|release", "seconds": r"\d+|-", "commit": r"[0-9a-f]{40,64}|-", "graph": r"ok|stale|-",
    "build": r"[^\t]+",
}
LINE = re.compile("^" + r"\t".join(f"(?:{PATTERNS[f]})" for f in FIELDS) + "$")
DEFAULT_SECONDS = 60


def die(text):
    print(f"e2e-ledger: {text}", file=sys.stderr)
    sys.exit(1)


def gate_cache():
    """Tools/gate-cache.py, loaded by its path, for its listing, graph and key."""
    spec = importlib.util.spec_from_file_location("gate_cache", os.path.join(HERE, "gate-cache.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_ledger():
    """(rows, None) or (None, why it cannot be trusted). A missing ledger is an empty one."""
    if not os.path.exists(LEDGER):
        return [], None
    try:
        lines = open(LEDGER, encoding="utf-8").read().splitlines()
    except (OSError, UnicodeDecodeError) as error:
        return None, f"the ledger {LEDGER} is unreadable ({error})"
    rows = []
    for number, line in enumerate(lines, 1):
        if not LINE.match(line):
            return None, f"the ledger {LEDGER} is corrupt at line {number}"
        rows.append(dict(zip(FIELDS, line.split("\t"))))
    return rows, None


def parse_facts(args):
    facts, rest = {}, []
    while args:
        word = args.pop(0)
        if word == "--fact":
            if not args or "=" not in args[0] or "\t" in args[0] or "\n" in args[0]:
                die("--fact takes name=value")
            name, value = args.pop(0).split("=", 1)
            if not value:
                die(f"the fact {name} is empty")
            facts[name] = value
        else:
            rest.append(word)
    missing = [f for f in REQUIRED_FACTS if f not in facts]
    if missing:
        die(f"no fact for {', '.join(missing)}: a key without them would carry a run across a toolchain or a macOS build")
    return facts, rest


def digest(path):
    try:
        return hashlib.sha256(open(path, "rb").read()).hexdigest()[:16]
    except OSError:
        return "none"


def keys(facts, subs):
    """sub -> (key, manifest, fact list) for these facts, and whether the graph is stale, of the working copy."""
    cache = gate_cache()
    listing = cache.files()
    module, graph = cache.load_graph(listing)
    for sub in subs:
        if sub not in graph.order:
            die(f"no sub-stage called {sub}")
    facts = dict(facts, graph="+".join(digest(p) for p in (module.GRAPH, module.HAND, module.MAP)))
    fact_list = [f"{k}={v}" for k, v in sorted(facts.items())]
    manifests = cache.inputs([f"e2e:{s}" for s in subs], listing, graph, module.GATES)
    out = {}
    for sub in subs:
        manifest = manifests[f"e2e:{sub}"]
        out[sub] = (cache.key_of(f"e2e:{sub}", manifest, fact_list), manifest, fact_list)
    return out, bool(graph.stale), cache


def save_manifest(key, manifest, fact_list):
    os.makedirs(MANIFESTS, exist_ok=True)
    path = os.path.join(MANIFESTS, key)
    if os.path.exists(path):
        return
    with open(path + ".new", "w", encoding="utf-8") as out:
        out.writelines(f"fact {f}\n" for f in fact_list)
        out.writelines(f"{manifest[p]} {p}\n" for p in sorted(manifest))
    os.replace(path + ".new", path)


def why_changed(key_before, manifest, fact_list):
    path = os.path.join(MANIFESTS, key_before)
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return "key changed (the last row's manifest is gone)"
    before_facts = {line[5:].split("=", 1)[0]: line[5:] for line in lines if line.startswith("fact ")}
    before = dict(reversed(line.split(" ", 1)) for line in lines if not line.startswith("fact "))
    for path in sorted(set(before) & set(manifest)):
        if before[path] != manifest[path]:
            return f"changed: {path}"
    for path in sorted(set(manifest) - set(before)):
        return f"changed: {path} (joined the inputs)"
    for path in sorted(set(before) - set(manifest)):
        return f"changed: {path} (left the inputs)"
    for fact in fact_list:
        name = fact.split("=", 1)[0]
        if before_facts.get(name) != fact:
            return f"changed: the fact {before_facts.get(name, name + '=?')} -> {fact}"
    return "key changed"


def working_tree(cache):
    with tempfile.TemporaryDirectory() as scratch:
        env = dict(os.environ, GIT_INDEX_FILE=os.path.join(scratch, "index"))
        cache.git("read-tree", "HEAD", env=env)
        cache.git("add", "--all", ":/", env=env)
        return cache.git("write-tree", env=env).strip()


def record(args):
    facts, rest = parse_facts(list(args))
    opts = {}
    while rest:
        name = rest.pop(0)
        if name not in ("--build", "--host", "--os", "--tree", "--mode") or not rest:
            die("usage: record --fact ... --build B --host H --os OS --tree T --mode M < run log")
        opts[name[2:]] = rest.pop(0)
    if set(opts) != {"build", "host", "os", "tree", "mode"}:
        die("record needs --build, --host, --os, --tree and --mode")
    results, took = {}, {}
    for line in sys.stdin.read().splitlines():
        parts = line.split("\t")
        if parts[0] == "TIME" and len(parts) >= 3 and parts[2].isdigit():
            took[parts[1]] = parts[2]
        elif parts[0] == "RESULT" and len(parts) >= 3:
            sub, result = parts[1], parts[2]
            check = parts[3] if len(parts) > 3 and parts[3] else "-"
            # A sub-stage passes only if every assertion in it passed; the first failed check names it.
            if result == "fail" and results.get(sub, ("pass",))[0] != "fail":
                results[sub] = ("fail", check)
            elif sub not in results:
                results[sub] = ("pass", "-")
    if not results:
        die("the run log holds no RESULT line; nothing is recorded")
    cache = gate_cache()
    tree = opts["tree"]
    if tree != "-" and tree != working_tree(cache):
        print("e2e-ledger: the working copy is not the run's tree; its rows carry no key", file=sys.stderr)
        tree = "-"
    known = [s for s in results if re.fullmatch(PATTERNS["sub"], s)]
    keyed, stale = {}, False
    if tree != "-":
        order = cache.load_graph()[1].order
        keyed, stale, _ = keys(facts, [s for s in known if s in order])
    commit = "-"
    if tree != "-":
        try:
            if cache.git("rev-parse", "HEAD^{tree}").strip() == tree:
                commit = cache.git("rev-parse", "HEAD").strip()
        except subprocess.CalledProcessError:
            pass
    when = now()
    lines = []
    for sub in sorted(known):
        result, check = results[sub]
        key = "-"
        if sub in keyed:
            key, manifest, fact_list = keyed[sub]
            save_manifest(key, manifest, fact_list)
        row = ["v1", sub, result, check, key, when, opts["host"] or "-", opts["os"] or "-", tree, opts["mode"],
               took.get(sub, "-"), commit, ("stale" if stale else "ok") if key != "-" else "-", opts["build"] or "-"]
        line = "\t".join(row)
        if not LINE.match(line):
            die(f"refusing a malformed ledger row: {line!r}")
        lines.append(line + "\n")
    os.makedirs(os.path.dirname(LEDGER), exist_ok=True)
    with open(LEDGER + ".lock", "w") as lock:
        for waited in range(300):
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                time.sleep(1)
        else:
            die(f"{LEDGER}.lock held for 5 min; nothing recorded")
        with open(LEDGER, "a", encoding="utf-8") as out:
            out.writelines(lines)
    print(f"e2e-ledger: {len(lines)} rows filed in {LEDGER}" + ("" if tree != "-" else ", unkeyed (no tree)"))


def age_days(when):
    then = datetime.datetime.strptime(when, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    return (datetime.datetime.now(datetime.timezone.utc) - then).total_seconds() / 86400


def latest_seconds(rows):
    seconds = {}
    for row in rows or []:
        if row["seconds"].isdigit():
            seconds[row["sub"]] = int(row["seconds"])
    return seconds


def plan(args):
    facts, rest = parse_facts(list(args))
    release, full, human, max_days, subs = False, False, False, 14.0, []
    while rest:
        word = rest.pop(0)
        if word == "--release":
            release = True
        elif word == "--full":
            full = True
        elif word == "--human":
            human = True
        elif word == "--max-days":
            try:
                max_days = float(rest.pop(0))
            except (IndexError, ValueError):
                die("--max-days takes a number")
        else:
            subs.append(word)
    if not subs:
        die("plan: name the sub-stages")
    keyed, stale, _ = keys(facts, subs)
    rows, broken = read_ledger()
    if broken:
        print(f"e2e-ledger: {broken}: nothing is carried, everything runs", file=sys.stderr)
    seconds = latest_seconds(rows)
    out = []
    for sub in subs:
        key, manifest, fact_list = keyed[sub]
        save_manifest(key, manifest, fact_list)
        took = seconds.get(sub, DEFAULT_SECONDS)
        if full:
            out.append(("run", sub, key, "FULL=1", took))
            continue
        if broken:
            out.append(("run", sub, key, "the ledger cannot be trusted", took))
            continue
        if stale:
            out.append(("run", sub, key, "the graph is stale now", took))
            continue
        mine = [r for r in rows if r["sub"] == sub]
        same = [r for r in mine if r["key"] == key]
        if not same:
            keyed_rows = [r for r in mine if r["key"] != "-"]
            why = why_changed(keyed_rows[-1]["key"], manifest, fact_list) if keyed_rows else "no row for it"
            out.append(("run", sub, key, why, took))
            continue
        last = same[-1]
        if last["result"] != "pass":
            out.append(("run", sub, key, f"failed last, {last['when']} ({last['check']})", took))
        elif last["graph"] != "ok":
            out.append(("run", sub, key, f"its pass of {last['when']} was recorded with a stale graph", took))
        elif release and age_days(last["when"]) > max_days:
            out.append(("run", sub, key, f"too old: passed {last['when']}, over {max_days:g} days", took))
        else:
            out.append(("carried", sub, key, f"{last['when']} {last['host'][:8]} {key[:12]}", took))
    if not human:
        for action, sub, key, detail, took in out:
            print(f"{action}\t{sub}\t{key}\t{detail}\t{took}")
        return
    for action, sub, key, detail, took in out:
        print(f"{sub:<22} {action} " + (detail if action == "carried" else f"— {detail}"))
    runs = [o for o in out if o[0] == "run"]
    total = sum(o[4] for o in runs)
    print(f"to run: {len(runs)} of {len(out)}, about {(total + 59) // 60} min by recorded seconds "
          f"({DEFAULT_SECONDS} s where none is recorded; a group's one launch counted per member)")


def show(args):
    last, stage = 30, None
    while args:
        word = args.pop(0)
        if word == "--last" and args and args[0].isdigit():
            last = int(args.pop(0))
        elif word == "--stage" and args:
            stage = args.pop(0)
        else:
            die("usage: show [--last N] [--stage S]")
    rows, broken = read_ledger()
    if broken:
        die(broken)
    picked = [r for r in rows if stage is None or r["sub"] == stage or r["sub"].startswith(stage + ".")][-last:]
    if not picked:
        print("no row" + (f" for {stage}" if stage else "") + f" in {LEDGER}")
        return
    print(f"{'WHEN':<21} {'SUB-STAGE':<22} {'RESULT':<6} {'SECS':>5} {'MODE':<11} {'HOST':<8} {'MACOS':<18} {'KEY':<12} CHECK")
    for r in picked:
        print(f"{r['when']:<21} {r['sub']:<22} {r['result']:<6} {r['seconds']:>5} {r['mode']:<11} {r['host'][:8]:<8} "
              f"{r['os']:<18} {r['key'][:12]:<12} {r['check']}")


def main():
    if len(sys.argv) < 2:
        die("usage: record|plan|show|seconds|failed-since")
    command, args = sys.argv[1], sys.argv[2:]
    if command == "record":
        record(args)
    elif command == "plan":
        plan(args)
    elif command == "show":
        show(args)
    elif command == "seconds":
        rows, broken = read_ledger()
        for sub, s in sorted(latest_seconds(None if broken else rows).items()):
            print(f"{sub}\t{s}")
    elif command == "failed-since":
        rows, broken = read_ledger()
        if broken or len(args) != 1:
            die(broken or "usage: failed-since <UTC time>")
        print(" ".join(sorted({r["sub"] for r in rows if r["result"] == "fail" and r["when"] >= args[0]
                               and r["sub"] != "cleanup"})))
    else:
        die(f"no command {command}")


if __name__ == "__main__":
    main()
