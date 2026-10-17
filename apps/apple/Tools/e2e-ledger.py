#!/usr/bin/env python3
"""The E2E ledger: what every E2E sub-stage did, when, where, and on which content, and what that lets a run skip.

    e2e-ledger.py record --fact macos=B --fact corpus=C --bundle <app> --build B --host H --os OS --tree T --mode M < log
        files one row per sub-stage of the run log's `RESULT<TAB>sub<TAB>pass|fail[<TAB>check]` lines (pass AND fail),
        with its seconds from `TIME<TAB>sub<TAB>seconds`, under the sub-stage's content key. The build's facts are the
        tested bundle's own (`<app>/Contents/Resources/Provenance.txt`, written by Tools/build-bundle.sh inside the
        signature) and cannot be supplied; a bundle that names another tree than T and the working copy is refused
    e2e-ledger.py plan [--release] [--max-days N] [--full] [--human] --fact name=value ... <sub-stage ...>
        per sub-stage `carried<TAB>sub<TAB>key<TAB><date> <host> <key-prefix><TAB>seconds` or
        `run<TAB>sub<TAB>key<TAB><why><TAB>seconds`; --human prints a table and the estimated minutes
    e2e-ledger.py show [--last N] [--stage S]       the last N rows (default 30), of one sub-stage or all
    e2e-ledger.py seconds                           `sub<TAB>seconds` of each sub-stage's latest timed row
    e2e-ledger.py failed-since <UTC time>           the sub-stages that failed in rows filed at or after it

**One record of runs, for development and release alike** (owner, 2026-10-17: "keep a ledger for what and when e2e has
done, so that even if we want to release, we could only run absolutely necessary portion of e2e"). A row is

    v2 sub result check key when host os tree mode seconds commit graph build seq chain

tab-separated: `check` the first failed check or `-`; `key` the sub-stage's content key (`Tools/gate-cache.py`'s: every
file, with its mode, that reaches the sub-stage by the graph, the hand list, `Tools/e2e-affected.map` and the harness
derivation, plus the facts) or `-` where the run's tree is unknown or moved; `host` the E2E Mac's hardware UUID; `os`
its macOS version and build; `tree` the bundle's source tree; `mode` development or release; `commit` HEAD where the
tree is HEAD's, else `-`; `graph` `ok` or `stale`; `build` the bundle's build number; `seq` the row's number from 1;
`chain` SHA-256 of the previous row's chain and this row. `<ledger>.head` holds the last row's seq and chain.

**The facts are part of every key**: `xcode` (version and build version), `swift` and `rust` of the build that made the
bundle, `macos` (the E2E Mac's build), `corpus` (`gate-cache.py corpus-id`, by content, or `none`), and the evaluator:
the graph, the hand list and the map, and the code that reads them (gate-cache.py, affected_graph.py, this file,
e2e-plan.sh), digested, so a change to what a key means changes every key. Mixed E2E Macs are evidence together
exactly when their macOS builds are equal.

**Carried** means, of the rows under the sub-stage's key now: none is from the future (over 5 minutes ahead); the last
filed passed, and is not older than any filed before it (a recorder that stalled cannot resurrect a key a newer
failure revoked); it was recorded with a graph that was not stale; and, with --release, it is younger than --max-days
(finite, over 0). Anything else runs, and says why. **Fail loud**: a ledger that is unreadable, has one malformed or
unfinished line, a broken chain, or disagrees with its head (cut short, or rolled back to an earlier copy without its
head) carries nothing; everything runs, and stderr says why. A copy of both files together is not detected.

**The recorder's boundary**: a verdict other than pass or fail is refused; a sub-stage passes only when every check the
catalog gives it (Tools/e2e-substages.txt) reported pass, else it is filed as a fail naming the check never reported.

The ledger: `$XDICT_E2E_LEDGER` (default ~/.local/share/xdict/e2e-ledger.tsv), outside every checkout and `.build`, so
worktrees share it and `make clean` keeps it; `e2e-manifests/<key>` beside it holds the inputs a key stands for (to
name what changed). Written under an exclusive lock (the row's time taken inside it), fsynced, its head last; read
under a shared one. `XDICT_E2E_LEDGER_CLOCK` sets the time a record files, for the tests.
"""
import datetime
import fcntl
import hashlib
import importlib.util
import math
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
LEDGER = os.environ.get("XDICT_E2E_LEDGER") or os.path.expanduser("~/.local/share/xdict/e2e-ledger.tsv")
HEAD = LEDGER + ".head"
LOCK = LEDGER + ".lock"
MANIFESTS = os.path.join(os.path.dirname(LEDGER), "e2e-manifests")
BUILD_FACTS = ("xcode", "swift", "rust")
RUN_FACTS = ("macos", "corpus")
EVALUATOR = ("gate-cache.py", "affected_graph.py", "e2e-ledger.py", "e2e-plan.sh")
FIELDS = ("v", "sub", "result", "check", "key", "when", "host", "os", "tree", "mode", "seconds", "commit", "graph", "build",
          "seq", "chain")
PATTERNS = {
    "v": r"v2", "sub": r"[a-z0-9.:-]+", "result": r"pass|fail", "check": r"[^\t]+", "key": r"[0-9a-f]{64}|-",
    "when": r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", "host": r"[A-Za-z0-9-]+", "os": r"[^\t]+", "tree": r"[0-9a-f]{40,64}|-",
    "mode": r"development|release", "seconds": r"\d+|-", "commit": r"[0-9a-f]{40,64}|-", "graph": r"ok|stale|-",
    "build": r"[^\t]+", "seq": r"[1-9]\d*", "chain": r"[0-9a-f]{64}",
}
LINE = re.compile("^" + r"\t".join(f"(?:{PATTERNS[f]})" for f in FIELDS) + "$")
GENESIS = "0" * 64
DEFAULT_SECONDS = 60
FUTURE_SLACK = 300
STAMP = "%Y-%m-%dT%H:%M:%SZ"


def die(text):
    print(f"e2e-ledger: {text}", file=sys.stderr)
    sys.exit(1)


def gate_cache():
    """Tools/gate-cache.py, loaded by its path, for its listing, graph and key."""
    spec = importlib.util.spec_from_file_location("gate_cache", os.path.join(HERE, "gate-cache.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_when(text):
    return datetime.datetime.strptime(text, STAMP).replace(tzinfo=datetime.timezone.utc)


def utcnow():
    return datetime.datetime.now(datetime.timezone.utc)


def chain_of(previous, fields):
    return hashlib.sha256((previous + "\n" + "\t".join(fields)).encode()).hexdigest()


class Locked:
    """The ledger's lock: shared to read, exclusive to write; waits up to 5 minutes."""

    def __init__(self, exclusive):
        self.mode = fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH

    def __enter__(self):
        os.makedirs(os.path.dirname(LOCK), exist_ok=True)
        self.handle = open(LOCK, "a")
        for _ in range(300):
            try:
                fcntl.flock(self.handle, self.mode | fcntl.LOCK_NB)
                return self
            except BlockingIOError:
                time.sleep(1)
        die(f"{LOCK} held for 5 min")

    def __exit__(self, *_):
        self.handle.close()


def read_unlocked():
    """(rows, None) or (None, why it cannot be trusted). A missing ledger with no head is an empty one."""
    exists = os.path.exists(LEDGER)
    try:
        head = open(HEAD, encoding="utf-8").read().split() if os.path.exists(HEAD) else None
    except (OSError, UnicodeDecodeError) as error:
        return None, f"its head {HEAD} is unreadable ({error})"
    if not exists:
        return ([], None) if head is None else (None, f"the ledger is gone but its head {HEAD} names row {head[0]}")
    try:
        raw = open(LEDGER, "rb").read().decode("utf-8")
    except (OSError, UnicodeDecodeError) as error:
        return None, f"the ledger {LEDGER} is unreadable ({error})"
    if raw and not raw.endswith("\n"):
        return None, f"the ledger {LEDGER} ends in an unfinished line"
    rows, previous = [], GENESIS
    for number, line in enumerate(raw.splitlines(), 1):
        if not LINE.match(line):
            return None, f"the ledger {LEDGER} is corrupt at line {number}"
        fields = line.split("\t")
        row = dict(zip(FIELDS, fields))
        if int(row["seq"]) != number or chain_of(previous, fields[:-1]) != row["chain"]:
            return None, f"the ledger {LEDGER} breaks its chain at line {number}"
        previous = row["chain"]
        rows.append(row)
    want = [str(len(rows)), previous] if rows else None
    if head != want:
        return None, (f"the ledger {LEDGER} disagrees with its head {HEAD} (head {head and ' '.join(head)}, ledger "
                      f"{want and ' '.join(want)}): cut short or rolled back")
    return rows, None


def read_ledger():
    with Locked(exclusive=False):
        return read_unlocked()


def parse_facts(args, required, forbidden=()):
    facts, rest = {}, []
    while args:
        word = args.pop(0)
        if word == "--fact":
            if not args or "=" not in args[0] or "\t" in args[0] or "\n" in args[0]:
                die("--fact takes name=value")
            name, value = args.pop(0).split("=", 1)
            if not value:
                die(f"the fact {name} is empty")
            if name in forbidden:
                die(f"the fact {name} is the tested bundle's (its Provenance.txt), never supplied")
            facts[name] = value
        else:
            rest.append(word)
    missing = [f for f in required if f not in facts]
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
    evaluator = [digest(p) for p in (module.GRAPH, module.HAND, module.MAP)]
    evaluator += [digest(os.path.join(HERE, name)) for name in EVALUATOR]
    facts = dict(facts, graph="+".join(evaluator))
    fact_list = [f"{k}={v}" for k, v in sorted(facts.items())]
    manifests = cache.inputs([f"e2e:{s}" for s in subs], listing, graph, module.GATES)
    out = {}
    for sub in subs:
        manifest = manifests[f"e2e:{sub}"]
        out[sub] = (cache.key_of(f"e2e:{sub}", manifest, fact_list), manifest, fact_list)
    return out, bool(graph.stale), cache


def save_manifest(key, manifest, fact_list):
    """Each writer its own temporary file, published by one rename: two writers of one new key cannot collide."""
    os.makedirs(MANIFESTS, exist_ok=True)
    path = os.path.join(MANIFESTS, key)
    if os.path.exists(path):
        return
    handle, temporary = tempfile.mkstemp(dir=MANIFESTS, prefix=f".{key[:12]}.")
    with os.fdopen(handle, "w", encoding="utf-8") as out:
        out.writelines(f"fact {f}\n" for f in fact_list)
        out.writelines(f"{manifest[p]} {p}\n" for p in sorted(manifest))
    os.replace(temporary, path)


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


def provenance(app):
    """The tested bundle's own account of itself: tree, xcode, swift, rust."""
    path = os.path.join(app, "Contents", "Resources", "Provenance.txt")
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except (OSError, UnicodeDecodeError) as error:
        die(f"the tested bundle has no readable provenance ({path}: {error}); nothing is recorded")
    found = dict(line.split("=", 1) for line in lines if "=" in line)
    missing = [n for n in ("tree",) + BUILD_FACTS if not found.get(n)]
    if missing or "\t" in "".join(found.values()):
        die(f"the tested bundle's provenance names no {', '.join(missing) or 'clean value'}; nothing is recorded")
    return found


def checks_by_sub():
    out = subprocess.run(["bash", os.path.join(HERE, "e2e-plan.sh"), "table"], check=True, capture_output=True,
                         text=True).stdout
    checks = {}
    for row in out.splitlines():
        parts = row.split("\t")
        checks.setdefault(parts[0], []).append(parts[4])
    return checks


def record(args):
    facts, rest = parse_facts(list(args), RUN_FACTS, forbidden=BUILD_FACTS + ("graph",))
    opts = {}
    while rest:
        name = rest.pop(0)
        if name not in ("--build", "--host", "--os", "--tree", "--mode", "--bundle") or not rest:
            die("usage: record --fact macos=… --fact corpus=… --bundle <app> --build B --host H --os OS --tree T --mode M")
        opts[name[2:]] = rest.pop(0)
    if set(opts) != {"build", "host", "os", "tree", "mode", "bundle"}:
        die("record needs --bundle, --build, --host, --os, --tree and --mode")
    results, took = {}, {}
    for line in sys.stdin.read().splitlines():
        parts = line.split("\t")
        if parts[0] == "TIME" and len(parts) >= 3 and parts[2].isdigit():
            took[parts[1]] = parts[2]
        elif parts[0] == "RESULT":
            if len(parts) < 3 or parts[2] not in ("pass", "fail"):
                die(f"a RESULT line with no verdict pass or fail: {line!r}; nothing is recorded")
            sub, result = parts[1], parts[2]
            check = parts[3] if len(parts) > 3 and parts[3] else "-"
            entry = results.setdefault(sub, {"fail": None, "passed": set()})
            if result == "fail" and entry["fail"] is None:
                entry["fail"] = check
            elif result == "pass":
                entry["passed"].add(check)
    if not results:
        die("the run log holds no RESULT line; nothing is recorded")
    catalog = checks_by_sub()
    verdicts = {}
    for sub, entry in results.items():
        if entry["fail"] is not None:
            verdicts[sub] = ("fail", entry["fail"])
            continue
        missing = [c for c in catalog.get(sub, []) if c not in entry["passed"]]
        verdicts[sub] = ("fail", f"{missing[0]} (never reported)") if missing else ("pass", "-")
    cache = gate_cache()
    tree = opts["tree"]
    if tree != "-":
        built = provenance(opts["bundle"])
        here = working_tree(cache)
        if built["tree"] != tree or tree != here:
            die(f"the tested bundle was built of {built['tree'][:12]}, the run names {tree[:12]} and the working copy is "
                f"{here[:12]}: no evidence of one tree is filed for another; nothing is recorded")
        facts = dict(facts, **{n: built[n] for n in BUILD_FACTS})
    known = [s for s in verdicts if re.fullmatch(PATTERNS["sub"], s)]
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
    with Locked(exclusive=True):
        rows, broken = read_unlocked()
        if broken:
            die(f"{broken}; nothing is recorded until it is repaired by hand")
        when = os.environ.get("XDICT_E2E_LEDGER_CLOCK") or utcnow().strftime(STAMP)
        parse_when(when)
        seq, previous = len(rows), rows[-1]["chain"] if rows else GENESIS
        lines = []
        for sub in sorted(known):
            result, check = verdicts[sub]
            key = "-"
            if sub in keyed:
                key, manifest, fact_list = keyed[sub]
                save_manifest(key, manifest, fact_list)
            seq += 1
            fields = ["v2", sub, result, check, key, when, opts["host"] or "-", opts["os"] or "-", tree, opts["mode"],
                      took.get(sub, "-"), commit, ("stale" if stale else "ok") if key != "-" else "-",
                      opts["build"] or "-", str(seq)]
            previous = chain_of(previous, fields)
            line = "\t".join(fields + [previous])
            if not LINE.match(line):
                die(f"refusing a malformed ledger row: {line!r}")
            lines.append(line + "\n")
        with open(LEDGER, "a", encoding="utf-8") as out:
            out.writelines(lines)
            out.flush()
            os.fsync(out.fileno())
        handle, temporary = tempfile.mkstemp(dir=os.path.dirname(LEDGER), prefix=".head.")
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            out.write(f"{seq} {previous}\n")
            out.flush()
            os.fsync(out.fileno())
        os.replace(temporary, HEAD)
    print(f"e2e-ledger: {len(lines)} rows filed in {LEDGER}" + ("" if tree != "-" else ", unkeyed (no tree)"))


def latest_seconds(rows):
    seconds = {}
    for row in rows or []:
        if row["seconds"].isdigit():
            seconds[row["sub"]] = int(row["seconds"])
    return seconds


def verdict(rows, key, release, max_days):
    """('carried', detail) or ('run', why) for the rows under one key, in the order they were filed."""
    now = utcnow()
    future = [r for r in rows if (parse_when(r["when"]) - now).total_seconds() > FUTURE_SLACK]
    if future:
        return "run", f"a row from the future ({future[0]['when']}) under its key"
    last = rows[-1]
    newest = max(r["when"] for r in rows)
    if last["result"] != "pass":
        return "run", f"failed last, {last['when']} ({last['check']})"
    if last["when"] < newest:
        return "run", f"its last pass ({last['when']}) is older than a row filed before it ({newest}): out of order"
    if last["graph"] != "ok":
        return "run", f"its pass of {last['when']} was recorded with a stale graph"
    if release and (now - parse_when(last["when"])).total_seconds() / 86400 > max_days:
        return "run", f"too old: passed {last['when']}, over {max_days:g} days"
    return "carried", f"{last['when']} {last['host'][:8]} {key[:12]}"


def plan(args):
    facts, rest = parse_facts(list(args), BUILD_FACTS + RUN_FACTS, forbidden=("graph",))
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
            if not math.isfinite(max_days) or max_days <= 0:
                die(f"--max-days must be finite and over 0, not {max_days}")
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
        elif broken:
            out.append(("run", sub, key, "the ledger cannot be trusted", took))
        elif stale:
            out.append(("run", sub, key, "the graph is stale now", took))
        else:
            mine = [r for r in rows if r["sub"] == sub]
            same = [r for r in mine if r["key"] == key]
            if same:
                action, detail = verdict(same, key, release, max_days)
            else:
                keyed_rows = [r for r in mine if r["key"] != "-"]
                action = "run"
                detail = why_changed(keyed_rows[-1]["key"], manifest, fact_list) if keyed_rows else "no row for it"
            out.append((action, sub, key, detail, took))
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
