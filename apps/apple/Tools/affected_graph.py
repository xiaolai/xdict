#!/usr/bin/env python3
"""**What a changed path reaches**: the compiled graph (Rust crates, Swift targets), generated, plus a short hand list for
what no compiler sees (drivers, fixtures, scripts, resources). Read by `Tools/gate-cache.py` for every gate's and E2E
sub-stage's key, and so by `make e2e`, `make e2e-pending` and `make land`.

    affected_graph.py generate          rewrite Tools/affected-graph.json from `cargo metadata` on core/ and SwiftPM's
                                        reading of Package.swift (`swift package dump-package`); needs cargo and swift,
                                        so it runs on a build Mac (`make affected-graph-update`)
    affected_graph.py check             exit 1 unless Tools/affected-graph.json is what `generate` would write now
    affected_graph.py select [-v] <path...>
                                        the E2E sub-stages those paths select, in run order (-v: why, on stderr)
    affected_graph.py html [--base <ref>] [<path...>]
                                        the picture, dev-docs/artifacts/affected/index.html: path -> crate/target ->
                                        gate/sub-stage, what the paths (default: the change since macos-v1) reach lit

**The graph.** A node is `crate:<name>` (a workspace crate's own files, less its tests), `tests:<name>` (its `tests/`,
`benches/`, `examples/`: read only by whoever runs that crate's tests), or `target:<name>` (a Swift target's directory).
A crate reaches its normal and build dependencies; `tests:X` also X's dev-dependencies; a target its dependencies, and
the binary target `xdictFFI` the crate it is built from (the hand list's `binary` line). An E2E sub-stage reaches what
the executables it launches reach (`launches`) and what its needs are built from (`builds`, by the catalog's needs).

**E2E selection is file-level first**: `Tools/e2e-affected.map` decides every path it names (first match); then the hand
list (`Tools/affected-hand.map`); then the path's owning node in the graph; and **a path none names reaches everything**
(fail-safe). Gates read the graph only. A graph whose manifests changed since it was generated is stale: every gate,
and every path the rules do not name, reaches everything, and stderr says so. Never a narrower selection on doubt.

**What the harness executes is derived, and widens the rules, never narrows them** (2026-10-17, after a refutation
found shared drivers, kit tools and fixtures reaching only some of the sub-stages that run them). `harness_uses` reads
`Tools/e2e.sh`: a repository path it names inside an `if needs <need>` block reaches every sub-stage with that need;
one it names anywhere else, and the run's entry chain (`ENTRY`), reach every sub-stage; a script it names is read the
same way one level down (the kit's `Tools/build-lab.sh`, the fixtures' `Tools/build-fixtures.sh`), so what the kit is
built of reaches every sub-stage that needs the kit; a cargo `--test`/`--example` it runs is that file. The hand list's
`reads <node> <pattern>` says what a node reads at run time that no compiler sees (the fixture writer reads
`conformance/fixtures`). A path's selection is its rule's (or graph's) answer **united** with these. Correct before
cheap: a kit tool reaches every kit sub-stage, though most run one product of the kit; splitting the kit by product
(`$kit/<product>` per sub-stage function) would narrow that later.

**Recorded coverage** (plan-verification §4.2, third bullet) plugs in at `Graph.recorded_coverage`: once an E2E run
records which files a sub-stage actually executed, that sub-stage's file set narrows to them there. Today it records
nothing, so it narrows nothing.

Environment for the tests: XDICT_AFFECTED_GRAPH, XDICT_AFFECTED_HAND, XDICT_E2E_AFFECTED_MAP, XDICT_E2E_SUBSTAGES (read by Tools/e2e-plan.sh).
"""
import fnmatch
import hashlib
import html
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GRAPH = os.environ.get("XDICT_AFFECTED_GRAPH") or os.path.join(HERE, "affected-graph.json")
HAND = os.environ.get("XDICT_AFFECTED_HAND") or os.path.join(HERE, "affected-hand.map")
MAP = os.environ.get("XDICT_E2E_AFFECTED_MAP") or os.path.join(HERE, "e2e-affected.map")
CRATE_TEST_DIRS = ("tests/", "benches/", "examples/")
# The run's entry chain: `make e2e` -> Tools/e2e-run.sh -> Tools/e2e.sh -> Tools/e2e-plan.sh over the catalog. Every
# sub-stage executes all of them.
ENTRY = ("apps/apple/Makefile", "apps/apple/Tools/e2e-run.sh", "apps/apple/Tools/e2e.sh", "apps/apple/Tools/e2e-plan.sh",
         "apps/apple/Tools/e2e-substages.txt")
HARNESS = "apps/apple/Tools/e2e.sh"
_REF = re.compile(r"(?<![\w$/.-])((?:\.\./)*(?:apps/apple/)?(?:Tools|Resources|Sources|Strings|conformance|core)/[A-Za-z0-9_./-]*)")
_CARGO = re.compile(r"-p\s+([A-Za-z0-9_-]+)\s+--(test|example)\s+([A-Za-z0-9_]+)")
_NEEDS_IF = re.compile(r"^(\s*)if\b.*\bneeds\s+\w+")
_FI = re.compile(r"^(\s*)fi\b")
# The gates' inputs (AGENTS.md "Which gates a change needs"): the crates and targets a gate builds and runs, as graph
# roots, plus the paths it reads that no compiler sees. A gate reaching any crate also reads core/Cargo.toml and
# core/Cargo.lock. `*` is every node of that kind.
GATES = {
    "core": (["core/"], ["tests:*"]),
    "apple-test": (["apps/apple/", "conformance/"], ["target:*", "crate:xdict-conformance"]),
    "entries": ([], ["tests:xdict-core"]),
    "lookup-corpus": ([], ["tests:xdict-lookup"]),
    "mdx-v3": ([], ["tests:xdict-mdx"]),
    "bindings": (["conformance/", "core/binding-env.sh"], ["crate:xdict-ffi", "crate:xdict-wasm",
                                                          "crate:xdict-conformance"]),
    "memory": (["core/binding-env.sh"], ["crate:xdict-ffi", "crate:xdict-wasm"]),
}
WORKSPACE_MANIFESTS = ("core/Cargo.toml", "core/Cargo.lock")


def die(text):
    print(f"affected-graph: {text}", file=sys.stderr)
    sys.exit(1)


def repo_root():
    return os.environ.get("XDICT_GATE_REPO") or subprocess.run(
        ["git", "-C", HERE, "rev-parse", "--show-toplevel"], check=True, capture_output=True, text=True).stdout.strip()


def blob_of(repo, path):
    """The file's git blob id, computed here: a build Mac's copy of the tree is no git repository."""
    full = os.path.join(repo, path)
    if not os.path.exists(full):
        return None
    data = open(full, "rb").read()
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


# --- generate ---------------------------------------------------------------------------------------------------------

def generate(repo):
    """The graph as the compilers' own tools read the manifests. Plain `cargo metadata --no-deps`: every workspace
    member's path dependencies are in it, which is all a workspace graph needs (no guppy)."""
    meta = json.loads(subprocess.run(
        ["cargo", "metadata", "--format-version", "1", "--no-deps", "--offline",
         "--manifest-path", os.path.join(repo, "core", "Cargo.toml")],
        check=True, capture_output=True, text=True).stdout)
    members = {p["name"] for p in meta["packages"]}
    crates, manifests = {}, ["core/Cargo.toml", "apps/apple/Package.swift"]
    for package in meta["packages"]:
        manifest = os.path.relpath(package["manifest_path"], repo)
        manifests.append(manifest)
        deps = sorted({d["name"] for d in package["dependencies"] if d["name"] in members and d["kind"] != "dev"})
        dev = sorted({d["name"] for d in package["dependencies"] if d["name"] in members and d["kind"] == "dev"})
        crates[package["name"]] = {"dir": os.path.dirname(manifest) + "/", "deps": deps, "dev": dev}
    package = json.loads(subprocess.run(
        ["swift", "package", "dump-package", "--package-path", os.path.join(repo, "apps", "apple")],
        check=True, capture_output=True, text=True).stdout)
    targets = {}
    for target in package["targets"]:
        kind = target["type"]
        path = target.get("path") or ("Tests/" if kind == "test" else "Sources/") + target["name"]
        deps = []
        for dep in target["dependencies"]:
            (value,) = dep.values()
            deps.append(value[0])
        targets[target["name"]] = {"type": kind, "dir": f"apps/apple/{path.rstrip('/')}/", "deps": sorted(deps)}
    return {"version": 1, "crates": dict(sorted(crates.items())), "targets": dict(sorted(targets.items())),
            "manifests": {m: blob_of(repo, m) for m in sorted(manifests)}}


def dumps(graph):
    return json.dumps(graph, indent=1, sort_keys=True) + "\n"


# --- the hand list ------------------------------------------------------------------------------------------------------

def read_hand(path):
    rules, controls, launches, builds, binaries, reads = [], {}, [], {}, {}, []
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError as error:
        die(f"no hand list at {path} ({error})")
    for raw in lines:
        words = raw.split()
        if not words or words[0].startswith("#"):
            continue
        head = words[0]
        if head == "control" and len(words) == 3:
            controls.setdefault(words[1], []).append(words[2])
        elif head == "launches" and len(words) >= 3:
            launches.append((words[1], words[2:]))
        elif head == "builds" and len(words) >= 3:
            builds[words[1]] = words[2:]
        elif head == "binary" and len(words) == 3:
            binaries[words[1]] = words[2]
        elif head == "reads" and len(words) == 3:
            reads.append((words[1], words[2]))
        elif head in ("control", "launches", "builds", "binary", "reads"):
            die(f"the hand list {path}: malformed `{raw.strip()}`")
        elif len(words) >= 2:
            rules.append((words[0], words[1], words[2:]))
        else:
            die(f"the hand list {path}: a rule with no names: `{raw.strip()}`")
    if not rules or not launches:
        die(f"the hand list {path} has no rule or no `launches` line")
    return rules, controls, launches, builds, binaries, reads


def _normal(word):
    """A path the harness names, from the repository's root."""
    word = word.rstrip("/.")
    while word.startswith("../"):
        word = word[3:]
    if word.startswith(("Tools/", "Resources/", "Sources/", "Strings/")):
        word = "apps/apple/" + word
    return os.path.normpath(word) if word else ""


def _named(text):
    """The repository paths and cargo targets a shell text names, line by line: [(line, {path or prefix})]."""
    out = []
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        found = {_normal(w) for w in _REF.findall(line)}
        for crate, kind, name in _CARGO.findall(line):
            found.add(f"core/{crate}/{'tests' if kind == 'test' else 'examples'}/{name}.rs")
        out.append((line, {f for f in found if f}))
    return out


def harness_uses(repo, listing_paths, needs, order):
    """path -> the sub-stages that execute it, derived from Tools/e2e.sh (see the module's doc). Empty when the
    repository has no harness (the tests' scratch repositories)."""
    try:
        text = open(os.path.join(repo, HARNESS), encoding="utf-8").read()
    except OSError:
        return {}
    every = set(order)

    def with_need(names):
        return {s for s in order if set(needs[s]) & names}
    named = {}   # path or prefix -> sub-stages
    def add(prefix, subs, depth):
        named.setdefault(prefix, set()).update(subs)
        if depth == 0 and prefix.startswith("apps/apple/Tools/") and prefix.endswith(".sh") and prefix != HARNESS:
            try:
                inner = open(os.path.join(repo, prefix), encoding="utf-8").read()
            except OSError:
                return
            for _, found in _named(inner):
                for f in found:
                    add(f, subs, 1)
    stack = []   # (indent, need names) of the open `if needs` blocks
    for line, found in _named(text):
        opened = _NEEDS_IF.match(line)
        if opened:
            stack.append((len(opened.group(1)), set(re.findall(r"\bneeds\s+(\w+)", line))))
        subs = with_need(stack[-1][1]) if stack else every
        for f in found:
            add(f, subs, 0)
        closed = _FI.match(line)
        if closed and stack and len(closed.group(1)) == stack[-1][0] and not opened:
            stack.pop()
    for path in ENTRY:
        named.setdefault(path, set()).update(every)
    uses = {}
    for prefix, subs in named.items():
        for path in listing_paths:
            if path == prefix or path.startswith(prefix + "/"):
                uses.setdefault(path, set()).update(subs)
    return uses


def read_map(path):
    """Tools/e2e-affected.map: file-level rules for the E2E sub-stages, first match decides."""
    rules, controls = [], {}
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError as error:
        die(f"no map at {path} ({error})")
    for raw in lines:
        words = raw.split()
        if not words or words[0].startswith("#"):
            continue
        if words[0] == "control" and len(words) == 3:
            controls.setdefault(words[1], []).append(words[2])
        elif len(words) >= 2:
            rules.append((words[0], words[1], words[2:]))
        else:
            die(f"the map {path}: malformed `{raw.strip()}`")
    if not rules:
        die(f"the map {path} has no rule")
    return rules, controls


def plan():
    """Sub-stages in run order, which are default, and each one's needs, from Tools/e2e-plan.sh's table."""
    out = subprocess.run(["bash", os.path.join(HERE, "e2e-plan.sh"), "table"], check=True, capture_output=True,
                         text=True).stdout
    order, default, needs = [], set(), {}
    for row in out.splitlines():
        sub, kind, need = row.split("\t")[:3]
        if sub not in order:
            order.append(sub)
            needs[sub] = [n for n in need.split(",") if n != "-"]
        if kind == "default":
            default.add(sub)
    return order, default, needs


# --- the graph ----------------------------------------------------------------------------------------------------------

class Graph:
    def __init__(self, listing=None, repo=None):
        """listing: path -> `mode:blob` of the tree the selection is for (for staleness); None trusts the graph as is."""
        try:
            self.data = json.load(open(GRAPH, encoding="utf-8"))
        except (OSError, ValueError) as error:
            die(f"no readable graph at {GRAPH} ({error}): `make affected-graph-update` on a build Mac writes it")
        if self.data.get("version") != 1:
            die(f"the graph {GRAPH} is not version 1")
        self.crates, self.targets = self.data["crates"], self.data["targets"]
        self.rules, self.controls, launches, self.builds, self.binaries, self.reads = read_hand(HAND)
        self.map_rules, map_controls = read_map(MAP)
        for sub, extra in map_controls.items():
            self.controls.setdefault(sub, []).extend(c for c in extra if c not in self.controls.get(sub, []))
        self.order, self.default, self.needs = plan()
        self.stale = self.staleness(listing, repo)
        if self.stale:
            print(f"affected-graph: {self.stale}: the graph is stale, so every path reaches everything "
                  "(`make affected-graph-update` on a build Mac)", file=sys.stderr)
        for kind, name in (n.split(":", 1) for n in self.binaries.values()):
            if kind != "crate" or name not in self.crates:
                die(f"`binary` names no crate: {kind}:{name}")
        for name, target in self.targets.items():
            if target["type"] == "binary" and name not in self.binaries:
                die(f"the binary target {name} has no `binary` line in {HAND}: what is it built from?")
        self.launches = {}
        for sub in self.order:
            for pattern, exes in launches:
                if fnmatch.fnmatchcase(sub, pattern) or sub.startswith(pattern + "."):
                    for exe in exes:
                        if self.targets.get(exe, {}).get("type") != "executable":
                            die(f"`launches` names no executable target: {exe}")
                    self.launches[sub] = exes
                    break
            else:
                die(f"no `launches` line covers the sub-stage {sub}")
        self.sub_nodes = {sub: self.closure(self.sub_roots(sub)) for sub in self.order}
        self.owners = sorted(((c["dir"], name) for name, c in self.crates.items()), key=lambda x: -len(x[0]))
        for node, _ in self.reads:
            self.expand_node(node)
        root = repo or repo_root()
        paths = list(listing) if listing is not None else subprocess.run(
            ["git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard"], check=True,
            capture_output=True, text=True).stdout.splitlines()
        self.uses = harness_uses(root, paths, self.needs, self.order)
        self.target_dirs = sorted(((t["dir"], name) for name, t in self.targets.items()), key=lambda x: -len(x[0]))

    def staleness(self, listing, repo):
        if listing is None:
            return None
        for path, blob in self.data["manifests"].items():
            if listing.get(path, "").rpartition(":")[2] != blob:
                return f"{path} is not as it was when the graph was generated"
        for path in listing:
            if (path.startswith("core/") and path.endswith("/Cargo.toml") and path.count("/") == 2
                    and path not in self.data["manifests"] and self.member_listed(path, repo)):
                return f"{path} is a crate the graph does not know"
        return None

    def member_listed(self, path, repo):
        """A crate directory the workspace lists (a non-member, like a study, is no node of the graph)."""
        root = os.path.join(repo or repo_root(), "core", "Cargo.toml")
        try:
            text = open(root, encoding="utf-8").read()
        except OSError:
            return True
        return f'"{path.split("/")[1]}"' in text

    # Nodes ------------------------------------------------------------------------------------------------------------
    def expand_node(self, token):
        kind, _, name = token.partition(":")
        if kind not in ("crate", "tests", "target"):
            die(f"no node kind {kind} in {token}")
        pool = self.targets if kind == "target" else self.crates
        if name == "*":
            return {f"{kind}:{n}" for n in pool}
        if name not in pool:
            die(f"no {kind} called {name}")
        return {token}

    def deps(self, node):
        kind, name = node.split(":", 1)
        if kind == "crate":
            return [f"crate:{d}" for d in self.crates[name]["deps"]]
        if kind == "tests":
            return [f"crate:{name}"] + [f"crate:{d}" for d in self.crates[name]["dev"]]
        target = self.targets[name]
        out = [f"target:{d}" for d in target["deps"]]
        if target["type"] == "binary":
            out.append(self.binaries[name])
        return out

    def closure(self, roots):
        seen, todo = set(), []
        for root in roots:
            todo.extend(self.expand_node(root))
        while todo:
            node = todo.pop()
            if node not in seen:
                seen.add(node)
                todo.extend(self.deps(node))
        return seen

    def sub_roots(self, sub):
        roots = [f"target:{exe}" for exe in self.launches[sub]]
        for need in self.needs[sub]:
            roots += self.builds.get(need, [])
        return roots

    def owner(self, path):
        """The node a path belongs to, or None."""
        for prefix, name in self.target_dirs:
            if path.startswith(prefix):
                return f"target:{name}"
        for prefix, name in self.owners:
            if path.startswith(prefix):
                rest = path[len(prefix):]
                return f"{'tests' if rest.startswith(CRATE_TEST_DIRS) else 'crate'}:{name}"
        return None

    # Selection --------------------------------------------------------------------------------------------------------
    def expand_names(self, names):
        wanted = set()
        for name in names:
            if ":" in name:
                nodes = self.expand_node(name)
                wanted |= {s for s in self.order if self.sub_nodes[s] & nodes}
            elif name == "all":
                wanted.update(self.order)
            elif "." in name:
                if name not in self.order:
                    die(f"the hand list names no sub-stage called {name}")
                wanted.add(name)
            else:
                stage = {s for s in self.order if s in self.default and (s == name or s.startswith(name + "."))}
                if not stage:
                    die(f"the hand list names no stage called {name}")
                wanted |= stage
        return wanted

    def why(self, path):
        """(sub-stages or None for everything, the reason): the rules' or graph's answer, united with what the harness
        derivation and the `reads` lines say executes the path."""
        got, reason = self.base_why(path)
        extra = set(self.uses.get(path, ()))
        for node, pattern in self.reads:
            if fnmatch.fnmatchcase(path, pattern):
                extra |= {s for s in self.order if node in self.sub_nodes[s]}
        if got is None or extra <= got:
            return got, reason
        return got | extra, f"{reason}; executed by {' '.join(s for s in self.order if s in extra - got)}"

    def base_why(self, path):
        for source, rules in (("map", self.map_rules), ("hand", self.rules)):
            got = self.by_rules(source, rules, path)
            if got is not None:
                return got
        if self.stale:
            return None, "no rule names it and the graph is stale: everything"
        node = self.owner(path)
        if node is None:
            return None, "no rule and no crate or target owns it: everything"
        return {s for s in self.order if node in self.sub_nodes[s]}, f"graph: {node}"

    def by_rules(self, source, rules, path):
        """(selection, reason) by the first rule matching, or None when no rule names the path."""
        for pattern, first, rest in rules:
            if not fnmatch.fnmatchcase(path, pattern):
                continue
            names = [first.removeprefix("check:")] + rest
            if "none" in names:
                return set(), f"{source}: {pattern} -> none"
            if "all" in names:
                return None, f"{source}: {pattern} -> all"
            selected = self.expand_names(names)
            if first.startswith("check:"):
                for sub in list(selected):
                    selected |= set(self.controls.get(sub, []))
            return selected, f"{source}: {pattern} -> {' '.join([first] + rest)}"
        return None

    def of(self, path):
        return self.why(path)[0]

    def recorded_coverage(self, sub):
        """The hook for coverage-recorded maps (§4.2, third bullet): the files an E2E run recorded `sub` executing, to
        narrow its compiled reach to; None while nothing is recorded, which narrows nothing."""
        return None

    def gate_nodes(self, gate):
        return self.closure(GATES[gate][1])

    def gate_reads(self, gate, path, nodes):
        if self.stale:
            return True
        prefixes, _ = GATES[gate]
        if any(path.startswith(p) for p in prefixes):
            return True
        if path in WORKSPACE_MANIFESTS:
            return any(n.startswith(("crate:", "tests:")) for n in nodes)
        node = self.owner(path)
        return node is not None and node in nodes

    def select_paths(self, paths, verbose=False):
        wanted = set()
        for path in paths:
            got, reason = self.why(path)
            if verbose:
                print(f"{path}: {reason}", file=sys.stderr)
            wanted |= ({s for s in self.order if s in self.default} if got is None else got)
        return [s for s in self.order if s in wanted]


# --- the picture --------------------------------------------------------------------------------------------------------

def changed_paths(repo, base):
    merge = subprocess.run(["git", "-C", repo, "merge-base", base, "HEAD"], check=True, capture_output=True,
                           text=True).stdout.strip()
    out = subprocess.run(["git", "-C", repo, "diff", "--name-only", merge, "--"], check=True, capture_output=True,
                         text=True).stdout.split()
    out += subprocess.run(["git", "-C", repo, "ls-files", "--others", "--exclude-standard"], check=True,
                          capture_output=True, text=True).stdout.split()
    return sorted(set(out))


def picture(graph, paths, label):
    """A self-contained page: no request leaves it."""
    nodes = sorted({f"crate:{c}" for c in graph.crates} | {f"tests:{c}" for c in graph.crates}
                   | {f"target:{t}" for t in graph.targets})
    edges = {n: sorted(graph.deps(n)) for n in nodes}
    checks = {f"e2e:{s}": sorted(graph.sub_nodes[s]) for s in graph.order}
    checks.update({g: sorted(graph.gate_nodes(g)) for g in GATES})
    rows = []
    for path in paths:
        got, reason = graph.why(path)
        node = None if graph.stale else graph.owner(path)
        subs = [s for s in graph.order if s in graph.default] if got is None else [s for s in graph.order if s in got]
        rows.append({"path": path, "node": node, "reason": reason, "subs": subs})
    data = {"label": label, "nodes": nodes, "edges": edges, "checks": checks, "rows": rows,
            "order": graph.order, "default": sorted(graph.default), "stale": graph.stale}
    payload = json.dumps(data).replace("</", "<\\/")
    return PAGE.replace("@TITLE@", html.escape(label)).replace("@DATA@", payload)


PAGE = r"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
<title>XDict: what a change reaches</title>
<style>
:root{--bg:#fbfbfa;--fg:#1d1d1f;--muted:#6e6e73;--line:#d8d8dc;--card:#fff;--hit:#c2410c;--hitbg:#ffedd5;--sel:#1d4ed8;--selbg:#dbeafe}
@media (prefers-color-scheme:dark){:root{--bg:#161618;--fg:#ececf0;--muted:#9a9aa2;--line:#34343a;--card:#1f1f23;--hit:#fb923c;--hitbg:#431c06;--sel:#93c5fd;--selbg:#172554}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif}
header{padding:20px 24px 8px}h1{font-size:20px;margin:0 0 4px}.sub{color:var(--muted)}
main{display:grid;grid-template-columns:minmax(220px,1.2fr) minmax(200px,1fr) minmax(200px,1fr);gap:16px;padding:12px 24px 32px}
@media (max-width:860px){main{grid-template-columns:1fr}}
section{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px;min-width:0}
h2{font-size:13px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);margin:0 0 8px}
ul{list-style:none;margin:0;padding:0}li{padding:3px 6px;border-radius:6px;cursor:pointer;overflow-wrap:anywhere}
li.hit{background:var(--hitbg);color:var(--hit);font-weight:600}li.sel{outline:2px solid var(--sel);background:var(--selbg)}
li.dim{opacity:.45}.k{color:var(--muted);font-size:12px}.why{display:block;color:var(--muted);font-size:12px}
.stats{display:flex;gap:16px;flex-wrap:wrap;padding:0 24px}.stat{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:8px 14px}
.stat b{font-size:20px;display:block}.warn{color:var(--hit);padding:0 24px}
</style></head><body>
<header><h1>What a change reaches</h1><div class="sub">@TITLE@ — click a path, node or check to see what it reaches; click again to clear.</div></header>
<div class="stats" id="stats"></div><p class="warn" id="warn"></p>
<main><section><h2>Changed paths → reason</h2><ul id="paths"></ul></section>
<section><h2>Crates and targets</h2><ul id="nodes"></ul></section>
<section><h2>Gates and E2E sub-stages</h2><ul id="checks"></ul></section></main>
<script>
const D=@DATA@;
const $=id=>document.getElementById(id);
const reach=n=>{const s=new Set(),t=[n];while(t.length){const x=t.pop();if(!s.has(x)){s.add(x);(D.edges[x]||[]).forEach(y=>t.push(y))}}return s};
const hitNodes=new Set(),hitChecks=new Set();
D.rows.forEach(r=>{if(r.node)reach(r.node).forEach(n=>hitNodes.add(n));r.subs.forEach(s=>hitChecks.add('e2e:'+s));
  Object.entries(D.checks).forEach(([c,ns])=>{if(!c.startsWith('e2e:')&&r.node&&ns.includes(r.node))hitChecks.add(c)})});
function li(ul,text,cls,extra,data){const e=document.createElement('li');e.textContent=text;if(cls)e.className=cls;
  if(extra){const w=document.createElement('span');w.className='why';w.textContent=extra;e.appendChild(w)}e.dataset.v=data;ul.appendChild(e);return e}
D.rows.forEach(r=>li($('paths'),r.path,'hit',r.reason+' → '+r.subs.length+' sub-stage(s)','p:'+r.path));
if(!D.rows.length)li($('paths'),'(no changed path)','',null,'');
D.nodes.forEach(n=>li($('nodes'),n,hitNodes.has(n)?'hit':'',null,'n:'+n));
Object.keys(D.checks).forEach(c=>li($('checks'),c+(c.startsWith('e2e:')&&!D.default.includes(c.slice(4))?'  (extra)':''),hitChecks.has(c)?'hit':'',null,'c:'+c));
const nsub=[...hitChecks].filter(c=>c.startsWith('e2e:')).length;
$('stats').innerHTML='';[[D.rows.length,'changed paths'],[hitNodes.size,'nodes reached'],[nsub,'E2E sub-stages selected'],[[...hitChecks].filter(c=>!c.startsWith('e2e:')).length,'gates reading a node']]
 .forEach(([v,l])=>{const d=document.createElement('div');d.className='stat';const b=document.createElement('b');b.textContent=v;d.appendChild(b);d.appendChild(document.createTextNode(l));$('stats').appendChild(d)});
if(D.stale)$('warn').textContent='The graph is stale ('+D.stale+'): everything is reached.';
let current=null;
document.addEventListener('click',ev=>{const e=ev.target.closest('li');if(!e||!e.dataset.v)return;
  const v=e.dataset.v;document.querySelectorAll('li').forEach(x=>x.classList.remove('sel','dim'));
  if(current===v){current=null;return}current=v;let ns=new Set(),cs=new Set();
  if(v.startsWith('p:')){const r=D.rows.find(r=>'p:'+r.path===v);if(r.node)ns=reach(r.node);r.subs.forEach(s=>cs.add('e2e:'+s));
    Object.entries(D.checks).forEach(([c,l])=>{if(!c.startsWith('e2e:')&&r.node&&l.includes(r.node))cs.add(c)})}
  else if(v.startsWith('n:')){const n=v.slice(2);ns=reach(n);Object.entries(D.checks).forEach(([c,l])=>{if(l.includes(n))cs.add(c)})}
  else{const c=v.slice(2);cs.add(c);(D.checks[c]||[]).forEach(n=>ns.add(n))}
  document.querySelectorAll('#nodes li').forEach(x=>x.classList.add(ns.has(x.dataset.v.slice(2))?'sel':'dim'));
  document.querySelectorAll('#checks li').forEach(x=>x.classList.add(cs.has(x.dataset.v.slice(2))?'sel':'dim'));
  e.classList.add('sel')});
</script></body></html>
"""


def main():
    if len(sys.argv) < 2:
        die("usage: generate | check | select [-v] <path...> | html [--base <ref>] [<path...>]")
    command, args = sys.argv[1], sys.argv[2:]
    repo = repo_root()
    if command == "generate":
        text = dumps(generate(repo))
        with open(GRAPH + ".new", "w", encoding="utf-8") as out:
            out.write(text)
        os.replace(GRAPH + ".new", GRAPH)
        print(f"affected-graph: wrote {GRAPH}")
    elif command == "check":
        want = dumps(generate(repo))
        have = open(GRAPH, encoding="utf-8").read() if os.path.exists(GRAPH) else ""
        if want != have:
            die(f"{GRAPH} is not what `generate` writes from the manifests now: `make affected-graph-update`")
        print("affected-graph: the graph is the manifests' own")
    elif command == "select":
        verbose = bool(args) and args[0] == "-v"
        if verbose:
            args = args[1:]
        if not args:
            die("select: name the paths")
        for sub in Graph().select_paths(args, verbose):
            print(sub)
    elif command == "html":
        base = "macos-v1"
        if args[:1] == ["--base"]:
            if len(args) < 2:
                die("--base takes a ref")
            base, args = args[1], args[2:]
        paths = args or changed_paths(repo, base)
        label = f"{len(paths)} path(s) given" if args else f"the working tree against {base}"
        out = os.path.join(os.path.dirname(repo), "dev-docs", "artifacts", "affected", "index.html")
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "w", encoding="utf-8") as page:
            page.write(picture(Graph(), paths, label))
        print(out)
    else:
        die(f"no command {command}")


if __name__ == "__main__":
    main()
