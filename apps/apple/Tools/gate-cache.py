#!/usr/bin/env python3
"""The gate cache: a gate or an E2E sub-stage runs only when its input key has no recorded pass.

    gate-cache.py status [--full] [--fact name=value ...] <gate ...>
        one line a gate: `run<TAB>gate<TAB>key<TAB>why` or `skip<TAB>gate<TAB>key<TAB>date of the pass`
    gate-cache.py record <gate> <key> <seconds> <host>
        file a pass of <gate> under <key> (only after `status` computed that key on this machine)
    gate-cache.py corpus-id <folder>
        a corpus's identity (names, sizes, times), for a `--fact`
    gate-cache.py select-paths <path ...>
        the E2E sub-stages those paths select (`-v` first: why, on stderr); Tools/e2e-affected.sh asks this

**A key is the content a gate reads**, never a branch or a date: the path and blob of every file in its inputs, in the
working copy's tree (committed or not, as `Tools/source-tree.sh` reads it), plus the facts the caller names (rustc,
SwiftLint, the corpus). The gates' inputs:

    core, apple-test, entries, lookup-corpus, mdx-v3, bindings, memory
                                           the files of the crates and targets the gate reaches in the generated graph,
                                           plus the paths it reads that no compiler sees (`GATES` in
                                           Tools/affected_graph.py; AGENTS.md's table)
    e2e:<sub-stage>                        every file that reaches that sub-stage (Tools/affected_graph.py): by the hand
                                           list (`Tools/affected-hand.map`), else by the crate or target that owns it,
                                           else everything (fail-safe). `e2e` is every default sub-stage; `e2e-all`
                                           every one

**Changed means since that gate's last pass**: a miss names the first path whose content differs from the inputs of
the gate's most recent pass, so the reader sees why it runs.

**Fail loud**: a record that is missing, unreadable, or has one malformed line, or a pass whose manifest is gone, is no
pass at all: everything runs, and stderr says why. Never a skip on doubt. A release never reads this cache
(`Tools/release.sh` asks `Tools/e2e-status.sh require-fresh`, which reads the E2E record of runs only).

The record: `$XDICT_GATE_CACHE` (default ~/.cache/xdict-gates), outside every checkout so all worktrees share it:
`passes.tsv` (`v1, key, gate, date, seconds, host`) and `manifests/<key>` (the inputs that key stands for).
Environment for the tests: XDICT_GATE_REPO, XDICT_AFFECTED_GRAPH, XDICT_AFFECTED_HAND, XDICT_E2E_SUBSTAGES (read by
Tools/e2e-plan.sh).
"""
import datetime
import hashlib
import importlib.util
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.environ.get("XDICT_GATE_REPO") or subprocess.run(
    ["git", "-C", HERE, "rev-parse", "--show-toplevel"], check=True, capture_output=True, text=True).stdout.strip()
CACHE = os.environ.get("XDICT_GATE_CACHE") or os.path.expanduser("~/.cache/xdict-gates")
PASSES = os.path.join(CACHE, "passes.tsv")
MANIFESTS = os.path.join(CACHE, "manifests")
LINE = re.compile(r"^v1\t[0-9a-f]{64}\t[a-z0-9.:-]+\t\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\t\d+\t[A-Za-z0-9._-]+$")


def die(text):
    print(f"gate-cache: {text}", file=sys.stderr)
    sys.exit(1)


def git(*args, env=None):
    return subprocess.run(["git", "-C", REPO, *args], check=True, capture_output=True, text=True, env=env).stdout


def files():
    """path -> blob of the working copy's tree, built in an index of its own (as Tools/source-tree.sh does)."""
    with tempfile.TemporaryDirectory() as scratch:
        env = dict(os.environ, GIT_INDEX_FILE=os.path.join(scratch, "index"))
        git("read-tree", "HEAD", env=env)
        git("add", "--all", ":/", env=env)
        tree = git("write-tree", env=env).strip()
    listing = {}
    for line in git("ls-tree", "-r", "--full-tree", tree).splitlines():
        meta, path = line.split("\t", 1)
        listing[path] = meta.split()[2]
    if not listing:
        die("the working copy's tree lists no file")
    return listing


def load_graph(listing=None):
    """Tools/affected_graph.py, loaded by its path: `python3 -I` puts no script directory on sys.path."""
    spec = importlib.util.spec_from_file_location("affected_graph", os.path.join(HERE, "affected_graph.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module, module.Graph(listing, REPO)


def inputs(gates, listing, graph, gate_names):
    """gate -> {path: blob} it reads."""
    wanted = {}
    by_path = {path: graph.of(path) for path in listing} if any(g.startswith("e2e:") for g in gates) else {}
    for gate in gates:
        if gate in gate_names:
            nodes = graph.gate_nodes(gate)
            wanted[gate] = {p: b for p, b in listing.items() if graph.gate_reads(gate, p, nodes)}
        else:
            sub = gate[4:]
            wanted[gate] = {p: b for p, b in listing.items() if by_path[p] is None or sub in by_path[p]}
    return wanted


def key_of(gate, manifest, facts):
    h = hashlib.sha256()
    h.update(f"gate {gate}\n".encode())
    for fact in sorted(facts):
        h.update(f"fact {fact}\n".encode())
    for path in sorted(manifest):
        h.update(f"{manifest[path]} {path}\n".encode())
    return h.hexdigest()


def passes():
    """key -> (gate, date) and gate -> its latest pass's key; None if the record cannot be trusted (said why)."""
    if not os.path.exists(PASSES):
        print(f"gate-cache: no record at {PASSES}: everything runs", file=sys.stderr)
        return {}, {}
    by_key, latest = {}, {}
    try:
        lines = open(PASSES, encoding="utf-8").read().splitlines()
    except (OSError, UnicodeDecodeError) as error:
        print(f"gate-cache: the record {PASSES} is unreadable ({error}): everything runs", file=sys.stderr)
        return None
    for number, line in enumerate(lines, 1):
        if not LINE.match(line):
            print(f"gate-cache: the record {PASSES} is corrupt at line {number}: everything runs", file=sys.stderr)
            return None
        _, key, gate, date, _, _ = line.split("\t")
        if not os.path.exists(os.path.join(MANIFESTS, key)):
            print(f"gate-cache: the pass of {gate} at line {number} has no manifest: everything runs", file=sys.stderr)
            return None
        by_key[key] = (gate, date)
        latest[gate] = key
    return by_key, latest


def changed(gate, manifest, latest):
    if gate not in latest:
        return "no pass recorded"
    before = {}
    for line in open(os.path.join(MANIFESTS, latest[gate]), encoding="utf-8"):
        if line.startswith("fact "):
            continue
        blob, path = line.rstrip("\n").split(" ", 1)
        before[path] = blob
    # An edit first: a path that only joined or left the inputs (a new file, or the graph redrawing a gate's reach)
    # is named as that, never as changed.
    for path in sorted(set(before) & set(manifest)):
        if before[path] != manifest[path]:
            return f"changed: {path}"
    for path in sorted(set(manifest) - set(before)):
        return f"joined the inputs: {path}"
    for path in sorted(set(before) - set(manifest)):
        return f"left the inputs: {path}"
    return "changed: a fact (toolchain, host or corpus)"


def status(args):
    full, facts, gates = False, [], []
    while args:
        word = args.pop(0)
        if word == "--full":
            full = True
        elif word == "--fact":
            if not args or "=" not in args[0] or "\t" in args[0] or "\n" in args[0]:
                die("--fact takes name=value")
            facts.append(args.pop(0))
        else:
            gates.append(word)
    if not gates:
        die("status: name the gates")
    listing = files()
    module, graph = load_graph(listing)
    named = []
    for gate in gates:
        if gate == "e2e":
            named += [f"e2e:{s}" for s in graph.order if s in graph.default]
        elif gate == "e2e-all":
            named += [f"e2e:{s}" for s in graph.order]
        elif gate in module.GATES or (gate.startswith("e2e:") and gate[4:] in graph.order):
            named.append(gate)
        else:
            die(f"no gate called {gate}")
    manifests = inputs(named, listing, graph, module.GATES)
    record = None if full else passes()
    os.makedirs(MANIFESTS, exist_ok=True)
    for gate in named:
        key = key_of(gate, manifests[gate], facts)
        path = os.path.join(MANIFESTS, key)
        if not os.path.exists(path):
            with open(path + ".new", "w", encoding="utf-8") as out:
                out.writelines(f"fact {f}\n" for f in sorted(facts))
                out.writelines(f"{manifests[gate][p]} {p}\n" for p in sorted(manifests[gate]))
            os.replace(path + ".new", path)
        if full:
            print(f"run\t{gate}\t{key}\tFULL=1")
        elif record is None:
            print(f"run\t{gate}\t{key}\tno trustworthy record")
        elif key in record[0]:
            print(f"skip\t{gate}\t{key}\t{record[0][key][1]}")
        else:
            print(f"run\t{gate}\t{key}\t{changed(gate, manifests[gate], record[1])}")


def record(args):
    if len(args) != 4:
        die("usage: record <gate> <key> <seconds> <host>")
    gate, key, seconds, host = args
    if not os.path.exists(os.path.join(MANIFESTS, key)):
        die(f"no manifest for {key}: `status` computes a key before its gate runs")
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    line = f"v1\t{key}\t{gate}\t{now}\t{seconds}\t{host}"
    if not LINE.match(line):
        die(f"refusing a malformed record line: {line!r}")
    with open(PASSES, "a", encoding="utf-8") as out:   # one short append: atomic under O_APPEND
        out.write(line + "\n")


def corpus_id(args):
    """The corpus's identity, as a fact: every file's path, size and modification time under it, digested. Never its
    content (tens of GB); a dictionary replaced in place changes its size or time."""
    if len(args) != 1 or not os.path.isdir(args[0]):
        die("usage: corpus-id <folder>")
    h = hashlib.sha256()
    count = 0
    for root, dirs, names in os.walk(args[0]):
        dirs.sort()
        for name in sorted(names):
            path = os.path.join(root, name)
            st = os.stat(path)
            h.update(f"{os.path.relpath(path, args[0])} {st.st_size} {int(st.st_mtime)}\n".encode())
            count += 1
    if not count:
        die(f"the corpus {args[0]} holds no file")
    print(h.hexdigest()[:16])


def select_paths(paths):
    verbose = bool(paths) and paths[0] == "-v"
    for sub in load_graph()[1].select_paths(paths[1:] if verbose else paths, verbose):
        print(sub)


def main():
    if len(sys.argv) < 2:
        die("usage: status|record|select-paths")
    command, args = sys.argv[1], sys.argv[2:]
    if command == "status":
        status(args)
    elif command == "record":
        record(args)
    elif command == "corpus-id":
        corpus_id(args)
    elif command == "select-paths":
        select_paths(args)
    else:
        die(f"no command {command}")


if __name__ == "__main__":
    main()
