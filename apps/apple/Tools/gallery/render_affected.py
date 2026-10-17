#!/usr/bin/env python3
"""**Which pictures a change needs, and which already passed** (owner, 2026-10-18: "哪怕是要跑，也不是每次都要 full run").
The gallery's and the UI tour's counterpart of the gates' cache and the E2E selection. Renders nothing.

    render_affected.py select  [--base REF | --range A..B | --paths P...] [--full]
        every selected picture (`dict:key:kind  view  run|carried <date>  — why`), every route, the paths no rule
        names, then the pending line
    render_affected.py pending [same]      one line: `Render needed (not run): <n> pictures, <m> routes — <why>` or
                                           `Render: nothing pending` (`make render-pending`, the end of `make land`)
    render_affected.py plan    [same]      what `make render-affected` renders: `views<TAB><v,...><TAB><dict:key:kind>`
                                           an entry, then `routes<TAB><id,...>`
    render_affected.py keys --lab-id ID [--views v,...] <dict:key[:kind]>...
                                           `<dict:key@view><TAB><key>` a picture (hot.sh, before it renders)
    render_affected.py record --keys F --report R
                                           a pass for every picture of the report whose checks passed (hot.sh, run.sh)
    render_affected.py record-routes <id,...>
                                           a pass for those UI-tour routes on this tree (render-affected.sh, after the tour)
    render_affected.py lab-id              the lab's id for this tree (lab.sh and run.sh stamp the installed lab)

**Since when** (2026-10-18: a merged change whose renders were declined must not vanish): with no --base, --range or
--paths, the change is everything since the last commit whose every selected picture and route had passed
(`clean.tsv`, filed by `record` and `record-routes` once nothing is left), else since ANCHOR, the commit render
selection landed on, said as such. A start that is not in this history, or no history at all (a gate's copy), is
`Render: cannot compute: …`, exit 2, never "nothing pending".

**What a path selects** is `render-affected.map` (beside this file; the owner's rule of 2026-10-18 is written there):
one dictionary's change only that dictionary, a shared file one entry a dictionary in light core, windows and menus
their tour routes, anything else nothing. FULL=1 (`--full`) is the only way to the full gallery.

**A render key** is what a picture reads: the style files its view reads (the map's `reads`), the lab (the files of
XDictEntryLab's closure in the generated graph, the core included, less the style it is handed; with the core's
STYLE), the dictionary's files (`gate-cache.py corpus-id` of its folder in the corpus), the entry and the view. A
picture whose key has a pass in `$XDICT_RENDER_CACHE/passes.tsv` (default ~/.cache/xdict-renders) is carried. No corpus,
or a record with one malformed line, carries nothing, and says so. Routes have no key: a route's pass (`routes.tsv`)
counts for the source tree it was walked on.

Environment, for the tests: XDICT_RENDER_REPO, XDICT_RENDER_MAP, XDICT_GALLERY_KEYS (a gallery report naming the
entries; default the main checkout's dev-docs/artifacts/reading-frame/report-core.json, a copy of the E2E Mac's
gallery-keys.json), XDICT_RENDER_CORPUS (default ~/xdict-corpus/the24), XDICT_RENDER_CACHE, XDICT_RENDER_LAB_ID (the
lab's id given, not derived), XDICT_RENDER_ANCHOR.
"""
import datetime
import fnmatch
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(HERE)


def _repo():
    """The repository's root: git's, or, in a copy with no history (land's snapshot), four folders above this file."""
    if os.environ.get("XDICT_RENDER_REPO"):
        return os.environ["XDICT_RENDER_REPO"]
    found = subprocess.run(["git", "-C", HERE, "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return found.stdout.strip() if found.returncode == 0 else os.path.dirname(os.path.dirname(os.path.dirname(TOOLS)))


REPO = _repo()
MAP = os.environ.get("XDICT_RENDER_MAP") or os.path.join(HERE, "render-affected.map")
CACHE = os.environ.get("XDICT_RENDER_CACHE") or os.path.expanduser("~/.cache/xdict-renders")
PASSES = os.path.join(CACHE, "passes.tsv")
# The commits whose every selected picture and route had passed, one a line (`v1, commit, date`): pending counts from
# the last of them that is in this history. Routes have no key: a route's pass is filed under the source tree it saw.
CLEAN = os.path.join(CACHE, "clean.tsv")
ROUTE_PASSES = os.path.join(CACHE, "routes.tsv")
# Until a commit is fully rendered, pending counts from where this selection landed (render-affected's merge, 42ff98c,
# first parent): everything since is unseen.
ANCHOR = os.environ.get("XDICT_RENDER_ANCHOR") or "5a010b770264546bdcd301359b9295b7d57191c9"
PROFILES = "core/xdict-entry/src/roles/profiles.rs"
LEDGER = "apps/apple/Tools/gallery/style-ledger.tsv"
STYLE_DIR = "apps/apple/Sources/XDictEntryView/Style/"
STYLE_GEN = "apps/apple/Sources/XDictEntryView/EntryStyleFiles.swift"
SHARED = "shared file: reaches every dictionary"
HINT = "scope it to the dictionary's profile row to render only that dictionary"
ENTRY_TOKENS = ("rep", "profile", "ledger")
LINE = re.compile(r"^v1\t[0-9a-f]{64}\t[^\t]+@[a-z-]+\t\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
# A ledger repro: `dict:key[@theme]`, `*` for any entry (Tools/gallery/ledger.py's ENTRY).
REPRO = re.compile(r"^(?P<dict>[a-z0-9][a-z0-9-]*):(?P<key>[^,\t:]*[^,\t:@])(?:@(?:light|dark|sepia))?$")
COLOUR = re.compile(r"colou?r|dark", re.IGNORECASE)


class MapError(Exception):
    pass


class CannotCompute(Exception):
    """No start to count from (no git history, a start commit not in it): said, never read as nothing pending."""


LAST_DIE = []


def die(text):
    LAST_DIE.append(text)
    print(f"render: {text}", file=sys.stderr)
    sys.exit(1)


# --- The map -------------------------------------------------------------------------------------------------------------

class Map:
    def __init__(self):
        self.dicts, self.represent = [], None
        self.viewsets, self.routesets, self.profiles = {}, {}, {}
        self.reads, self.rules = [], []


def read_map(path):
    m = Map()
    for number, raw in enumerate(open(path, encoding="utf-8"), 1):
        words = raw.split("#", 1)[0].split()
        if not words:
            continue
        head, rest = words[0], words[1:]
        where = f"{os.path.basename(path)}:{number}"
        if head == "dicts":
            m.dicts = rest
        elif head == "represent" and len(rest) == 1:
            m.represent = rest[0]
        elif head == "viewset" and len(rest) >= 2:
            m.viewsets[rest[0]] = rest[1:]
        elif head == "routeset" and len(rest) >= 2:
            m.routesets[rest[0]] = rest[1:]
        elif head == "profile" and len(rest) >= 2:
            m.profiles[rest[0]] = rest[1:]
        elif head == "reads" and len(rest) >= 2:
            m.reads.append((rest[0], rest[1:]))
        elif head in ("dicts", "represent", "viewset", "routeset", "profile", "reads"):
            raise MapError(f"{where}: `{head}` is malformed")
        else:
            if not rest:
                raise MapError(f"{where}: {head} names nothing it selects (`none` for nothing)")
            for t in rest:
                ok = t == "none" or t in ENTRY_TOKENS or t.startswith(("dict:", "views:", "routes:", "route:"))
                if not ok:
                    raise MapError(f"{where}: no token {t}")
                if t.startswith("views:") and t[6:] not in m.viewsets:
                    raise MapError(f"{where}: no viewset {t[6:]}")
                if t.startswith("routes:") and t[7:] not in m.routesets:
                    raise MapError(f"{where}: no routeset {t[7:]}")
            entries = [t for t in rest if t in ENTRY_TOKENS or t.startswith("dict:")]
            if entries and not any(t.startswith("views:") for t in rest):
                raise MapError(f"{where}: {head} selects entries but names no views (`views:<set>`)")
            m.rules.append((head, rest))
    if not m.dicts or not m.represent or "all" not in m.viewsets:
        raise MapError(f"{path}: needs `dicts`, `represent` and the viewset `all`")
    for cls, ids in m.profiles.items():
        for d in ids:
            if d not in m.dicts:
                raise MapError(f"profile {cls} names {d}, not one of `dicts`")
    return m


def route_ids():
    sys.path.insert(0, os.path.join(TOOLS, "ui-tour"))
    try:
        from routes import ROUTES
    finally:
        sys.path.pop(0)
    return [r[0] for r in ROUTES]


def expand_routes(globs, ids):
    return [r for r in ids if any(fnmatch.fnmatchcase(r, g) for g in globs)]


def check_map(m, ids, profiles_text):
    """Every route pattern matches a route; every role-table row has its `profile` line and every line its row."""
    globs = [g for gs in m.routesets.values() for g in gs]
    globs += [t[6:] for _, ts in m.rules for t in ts if t.startswith("route:")]
    for g in globs:
        if not expand_routes([g], ids):
            raise MapError(f"the route pattern {g} matches no route of Tools/ui-tour/routes.py")
    rows = {sig for _, _, sig in profile_rows(profiles_text)}
    for sig in sorted(rows - set(m.profiles)):
        raise MapError(f"the role-table row {sig} ({PROFILES}) has no `profile` line in the map: which dictionaries?")
    for sig in sorted(set(m.profiles) - rows):
        raise MapError(f"`profile {sig}` names no row of {PROFILES}")


# --- What a change touches -----------------------------------------------------------------------------------------------

def profile_rows(text):
    """(first line, last line, signature's first class) of each row of `PROFILES`, 1-based, comments above included."""
    lines = text.split("\n")
    try:
        start = next(i for i, l in enumerate(lines) if "pub(crate) const PROFILES" in l)
    except StopIteration:
        return []
    rows, depth, seg = [], 0, start + 2
    for i in range(start + 1, len(lines)):
        code = lines[i].split("//", 1)[0]
        if depth == 0 and code.strip() == "];":
            break
        for ch in code:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    body = "\n".join(lines[seg - 1:i + 1])
                    found = re.search(r'signature:\s*&\[\s*"([^"]+)"', body)
                    rows.append((seg, i + 1, found.group(1) if found else "?"))
                    seg = i + 2
    return rows


def ledger_rows(text):
    """line -> (dicts its repro names, about colour) for the ledger's rows; the header is no row."""
    out = {}
    lines = text.split("\n")
    header = lines[0].split("\t") if lines else []
    if "repro" not in header:
        return out
    col = header.index("repro")
    for i, line in enumerate(lines[1:], 2):
        f = line.split("\t")
        if len(f) <= col:
            continue
        dicts = set()
        for part in f[col].split(","):
            hit = REPRO.match(part.strip())
            if hit:
                dicts.add(hit.group("dict"))
        out[i] = (dicts, bool(COLOUR.search(line)))
    return out


def ledger_repros(path):
    """dict -> keys the ledger reproduces a defect on (not `*`)."""
    out = {}
    try:
        lines = open(path, encoding="utf-8").read().split("\n")
    except OSError:
        return out
    header = lines[0].split("\t")
    col = header.index("repro") if "repro" in header else None
    for line in lines[1:]:
        f = line.split("\t")
        if col is None or len(f) <= col:
            continue
        for part in f[col].split(","):
            hit = REPRO.match(part.strip())
            if hit and hit.group("key") != "*" and hit.group("key") not in out.get(hit.group("dict"), []):
                out.setdefault(hit.group("dict"), []).append(hit.group("key"))
    return out


class Selection:
    def __init__(self):
        self.pictures = {}   # (dict, key, view) -> {why}
        self.kinds = {}      # (dict, key) -> kind
        self.routes = {}     # id -> {why}
        self.unmatched = []
        self.hint = None


def decide(m, path):
    for pattern, tokens in m.rules:
        if fnmatch.fnmatchcase(path, pattern):
            return tokens
    return None


def select(paths, m, keys, ledger, ids, hunks, profiles_text, full=False, ledger_text=None):
    s = Selection()

    def add(d, kind, key, views, why):
        s.kinds.setdefault((d, key), kind)
        for v in views:
            s.pictures.setdefault((d, key, v), set()).add(why)

    def entries_of(d, views, why):
        if d not in keys:
            die(f"the gallery's keys hold no entry of {d}")
        for kind, key in keys[d]:
            add(d, kind, key, views, why)
        for key in ledger.get(d, []):
            add(d, "ledger", key, views, why + " (style ledger)")

    def rep(views, why):
        for d in m.dicts:
            if d not in keys:
                die(f"the gallery's keys hold no entry of {d}")
            kind, key = next(((k, v) for k, v in keys[d] if k == m.represent), keys[d][0])
            add(d, kind, key, views, f"{why} ({SHARED})")
        s.hint = HINT

    if full:
        for d in m.dicts:
            for kind, key in keys.get(d, []):
                add(d, kind, key, m.viewsets["all"], "FULL=1")
        for r in ids:
            s.routes.setdefault(r, set()).add("FULL=1")
        return s
    for path in paths:
        tokens = decide(m, path)
        if tokens is None:
            s.unmatched.append(path)
            continue
        views = [v for t in tokens if t.startswith("views:") for v in m.viewsets[t[6:]]]
        for t in tokens:
            if t == "rep":
                rep(views, path)
            elif t.startswith("dict:"):
                entries_of(t[5:], views, path)
            elif t == "profile":
                lines = hunks.get(path)
                rows = profile_rows(profiles_text)
                if lines is None:
                    touched, outside = {sig for _, _, sig in rows}, False
                else:
                    touched = {sig for a, b, sig in rows if any(a <= n <= b for n in lines)}
                    outside = any(not any(a <= n <= b for a, b, _ in rows) for n in lines)
                for sig in sorted(touched):
                    for d in m.profiles.get(sig, []):
                        entries_of(d, views, f"{path} (row {sig})")
                if outside:
                    rep(views, f"{path} (outside every row)")
            elif t == "ledger":
                rows = ledger_rows(ledger_text or "")
                lines = hunks.get(path)
                chosen = rows.values() if lines is None else [rows[n] for n in lines if n in rows]
                for dicts, colour in chosen:
                    for d in sorted(dicts & set(m.dicts)):
                        extra = [v for v in m.viewsets["all"] if v.startswith("core-") and v.endswith("dark")]
                        entries_of(d, views + (extra if colour else []), f"{path} (row of {d})")
            elif t.startswith("route:"):
                for r in expand_routes([t[6:]], ids):
                    s.routes.setdefault(r, set()).add(path)
            elif t.startswith("routes:"):
                for r in expand_routes(m.routesets[t[7:]], ids):
                    s.routes.setdefault(r, set()).add(path)
    return s


# --- Keys -------------------------------------------------------------------------------------------------------------

def _gate_cache():
    os.environ.setdefault("XDICT_GATE_REPO", REPO)
    spec = importlib.util.spec_from_file_location("gate_cache", os.path.join(TOOLS, "gate-cache.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def listing():
    return _gate_cache().files()


def style_manifest(files, m, view):
    globs = [g for vg, gs in m.reads if fnmatch.fnmatchcase(view, vg) for g in gs]
    return {p: b for p, b in files.items() if any(fnmatch.fnmatchcase(p, g) for g in globs)}


def lab_paths(files):
    """The files the lab is built of: XDictEntryLab's closure in the generated graph, the core behind it included; not
    the style it is handed by --style-dir, nor the Swift generated from that style (the keys hold the style apart)."""
    module, graph = _gate_cache().load_graph(files)
    nodes = graph.closure(["target:XDictEntryLab"])
    out = {p for p in files if graph.owner(p) in nodes}
    out |= {p for p in ("apps/apple/Package.swift", "core/Cargo.lock", "core/Cargo.toml") if p in files}
    return {p for p in out if not p.startswith(STYLE_DIR) and p != STYLE_GEN}


def core_style():
    text = open(os.path.join(REPO, "core/xdict-entry/src/normalize.rs"), encoding="utf-8").read()
    found = re.search(r"pub const STYLE: u32 = (\d+);", text)
    if not found:
        die("no `pub const STYLE` in core/xdict-entry/src/normalize.rs")
    return found.group(1)


def lab_id(files):
    if os.environ.get("XDICT_RENDER_LAB_ID"):
        return os.environ["XDICT_RENDER_LAB_ID"]
    h = hashlib.sha256(f"style {core_style()}\n".encode())
    for p in sorted(lab_paths(files)):
        h.update(f"{files[p]} {p}\n".encode())
    return h.hexdigest()[:16]


def picture_key(picture, style, lab, dict_id):
    if dict_id is None:
        return None
    d, key, view = picture[0], picture[1], picture[2]
    h = hashlib.sha256(f"v1\nview {view}\ndict {d} {dict_id}\nentry {key}\nlab {lab}\n".encode())
    for p in sorted(style):
        h.update(f"{style[p]} {p}\n".encode())
    return h.hexdigest()


def dict_ids(m):
    corpus = os.environ.get("XDICT_RENDER_CORPUS") or os.path.expanduser("~/xdict-corpus/the24")
    out = {}
    if not os.path.isdir(corpus):
        print(f"render: no corpus at {corpus}: no picture can be keyed, so none is carried", file=sys.stderr)
        return {d: None for d in m.dicts}
    for d in m.dicts:
        folder = os.path.join(corpus, d)
        r = subprocess.run([sys.executable, "-I", os.path.join(TOOLS, "gate-cache.py"), "corpus-id", folder],
                           capture_output=True, text=True) if os.path.isdir(folder) else None
        if r is None or r.returncode != 0:
            print(f"render: {d} is not readable in {corpus}: its pictures are not carried", file=sys.stderr)
            out[d] = None
        else:
            out[d] = r.stdout.strip()
    return out


def read_passes(path):
    """key -> date; empty, and said, when the record is absent or has one malformed line."""
    if not os.path.exists(path):
        return {}
    out = {}
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except (OSError, UnicodeDecodeError) as error:
        print(f"render: the record {path} is unreadable ({error}): nothing is carried", file=sys.stderr)
        return {}
    for number, line in enumerate(lines, 1):
        if not LINE.match(line):
            print(f"render: the record {path} is corrupt at line {number}: nothing is carried", file=sys.stderr)
            return {}
        _, key, _, date = line.split("\t")
        out[key] = date
    return out


def append_passes(path, keyed):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(path, "a", encoding="utf-8") as out:
        for key, p in keyed:
            if "\t" in p[1] or "\n" in p[1]:
                continue
            out.write(f"v1\t{key}\t{p[0]}:{p[1]}@{p[2]}\t{now}\n")


def passed_rows(report):
    """(dict, key, view) of each row whose checks passed; nothing when a failure names no row (it may be any)."""
    rows = [(r["dict"], r["key"], r["mode"]) for r in report.get("rows", [])]
    failed = set()
    for f in report.get("failures", []):
        hit = False
        for d, key, mode in rows:
            light = "dark" if mode.endswith("dark") else "light"
            if f.startswith((f"{d} {mode} {key}:", f"{d} {light}:", f"{d}:")):
                failed.add((d, key, mode))
                hit = True
        if not hit:
            print(f"render: a failure names no picture, so none is recorded: {f[:120]}", file=sys.stderr)
            return []
    return [r for r in rows if r not in failed]


# --- The command ----------------------------------------------------------------------------------------------------------

def gallery_keys(m):
    path = os.environ.get("XDICT_GALLERY_KEYS")
    if not path:
        common = subprocess.run(["git", "-C", REPO, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                capture_output=True, text=True).stdout.strip()
        main = os.path.dirname(common) if common else REPO
        path = os.path.join(main, "dev-docs/artifacts/reading-frame/report-core.json")
    try:
        report = json.load(open(path, encoding="utf-8"))
    except (OSError, ValueError) as error:
        die(f"no gallery keys at {path} ({error}): XDICT_GALLERY_KEYS names a gallery report")
    keys = {}
    for row in report.get("rows", []):
        d, kind, key = row.get("dict"), row.get("kind"), row.get("key")
        if d in m.dicts and kind and key and kind not in [k for k, _ in keys.get(d, [])]:
            keys.setdefault(d, []).append((kind, key))
    return keys


def git(*args):
    return subprocess.run(["git", "-C", REPO, *args], check=True, capture_output=True, text=True).stdout


def hunk_lines(diff):
    lines = set()
    for found in re.finditer(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", diff, re.MULTILINE):
        start, count = int(found.group(1)), int(found.group(2) or 1)
        lines |= set(range(start, start + count)) if count else {max(start, 1), start + 1}
    return lines


def short(commit):
    return commit[:12]


def start():
    """(commit, why) pending counts from: the last fully rendered commit in this history, else the anchor."""
    if subprocess.run(["git", "-C", REPO, "rev-parse", "--verify", "-q", "HEAD"], capture_output=True).returncode:
        raise CannotCompute(f"no git history at {REPO} (land's snapshot has none; land says it on the Air)")

    def ancestor(commit):
        return subprocess.run(["git", "-C", REPO, "merge-base", "--is-ancestor", commit, "HEAD"],
                              capture_output=True).returncode == 0

    clean = []
    if os.path.exists(CLEAN):
        for number, line in enumerate(open(CLEAN, encoding="utf-8").read().splitlines(), 1):
            f = line.split("\t")
            if len(f) != 3 or f[0] != "v1" or not re.fullmatch(r"[0-9a-f]{40,64}", f[1]):
                print(f"render: {CLEAN} is corrupt at line {number}: counting from the anchor", file=sys.stderr)
                clean = []
                break
            clean.append(f[1])
    for commit in reversed(clean):
        if ancestor(commit):
            return commit, f"since {short(commit)}, the last fully rendered commit"
    if not ancestor(ANCHOR):
        raise CannotCompute(f"the start commit {short(ANCHOR)} is not in the history at {REPO}")
    why = "no render has passed yet" if not clean else "no fully rendered commit is in this history"
    return ANCHOR, f"since {short(ANCHOR)}, where render selection landed ({why})"


def change(args):
    """(paths, hunks, profiles text, ledger text, full, since) from --base, --range, --paths, or the start."""
    full = "--full" in args or os.environ.get("FULL") == "1"
    args = [a for a in args if a != "--full"]
    text = lambda p: open(os.path.join(REPO, p), encoding="utf-8").read() if os.path.exists(os.path.join(REPO, p)) else ""
    if args[:1] == ["--paths"]:
        return args[1:], {}, text(PROFILES), text(LEDGER), full, ""
    if args[:1] == ["--range"] and len(args) == 2 and ".." in args[1]:
        a, b = args[1].split("..", 1)
        paths = git("diff", "--name-only", a, b).split()
        hunks = {p: hunk_lines(git("diff", "-U0", a, b, "--", p)) for p in (PROFILES, LEDGER) if p in paths}
        show = lambda p: subprocess.run(["git", "-C", REPO, "show", f"{b}:{p}"], capture_output=True, text=True).stdout
        return paths, hunks, show(PROFILES), show(LEDGER), full, f"in {args[1]}"
    if args[:1] == ["--base"] and len(args) == 2:
        if subprocess.run(["git", "-C", REPO, "rev-parse", "--verify", "-q", args[1]], capture_output=True).returncode:
            raise CannotCompute(f"no commit {args[1]} in the history at {REPO}")
        base, since = args[1], f"since {args[1]}"
    elif args:
        die("usage: [--base REF | --range A..B | --paths P...] [--full]")
    else:
        base, since = start()
    merge = git("merge-base", base, "HEAD").strip()
    paths = sorted(set(git("diff", "--name-only", merge, "--").split() +
                       git("ls-files", "--others", "--exclude-standard").split()))
    hunks = {p: hunk_lines(git("diff", "-U0", merge, "--", p)) for p in (PROFILES, LEDGER) if p in paths}
    return paths, hunks, text(PROFILES), text(LEDGER), full, since


def selection(args):
    m = read_map(MAP)
    ids = route_ids()
    paths, hunks, ptext, ltext, full, since = change(args)
    try:
        check_map(m, ids, ptext)
    except MapError as error:
        die(str(error))
    keys = gallery_keys(m)
    s = select(paths, m, keys, ledger_repros(os.path.join(REPO, LEDGER)), ids, hunks, ptext, full=full, ledger_text=ltext)
    s.since = since
    carried = {}
    if s.routes and not full:
        done = read_route_passes(ROUTE_PASSES).get(tree_id(listing()), set())
        for r in list(s.routes):
            if r in done:
                del s.routes[r]
    if s.pictures and not full:
        files = listing()
        lab, ids_ = lab_id(files), dict_ids(m)
        record = read_passes(PASSES)
        for p in s.pictures:
            k = picture_key(p, style_manifest(files, m, p[2]), lab, ids_[p[0]])
            if k in record:
                carried[p] = record[k]
    return m, s, carried, paths


def tree_id(files):
    h = hashlib.sha256()
    for p in sorted(files):
        h.update(f"{files[p]} {p}\n".encode())
    return h.hexdigest()


def read_route_passes(path):
    """tree -> routes that passed on it; empty, and said, when the record has a malformed line."""
    out = {}
    if not os.path.exists(path):
        return out
    for number, line in enumerate(open(path, encoding="utf-8").read().splitlines(), 1):
        f = line.split("\t")
        if len(f) != 4 or f[0] != "v1":
            print(f"render: the record {path} is corrupt at line {number}: no route is carried", file=sys.stderr)
            return {}
        out.setdefault(f[1], set()).add(f[2])
    return out


def advance():
    """File HEAD as fully rendered when the working copy is HEAD's and nothing since the start is pending."""
    if git("status", "--porcelain", "--untracked-files=no").strip():
        return
    _, s, carried, _ = selection([])
    if all(p in carried for p in s.pictures) and not s.routes:
        head = git("rev-parse", "HEAD").strip()
        now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        os.makedirs(CACHE, exist_ok=True)
        with open(CLEAN, "a", encoding="utf-8") as out:
            out.write(f"v1\t{head}\t{now}\n")
        print(f"render: {short(head)} is fully rendered; pending now counts from it")


def try_advance():
    try:
        advance()
    except (CannotCompute, subprocess.CalledProcessError) as error:
        print(f"render: the fully rendered commit was not moved: {error}", file=sys.stderr)


def pending_line(s, carried):
    need = [p for p in s.pictures if p not in carried]
    since = getattr(s, "since", "")
    if not need and not s.routes:
        return ("Render: nothing pending" + (f" {since}" if since else "")
                + (f" ({len(carried)} carried)" if carried else ""))
    why = sorted({w for p in need for w in s.pictures[p]} | {w for r in s.routes for w in s.routes[r]})
    shown = ", ".join(why[:4]) + (f" and {len(why) - 4} more" if len(why) > 4 else "")
    line = (f"Render needed (not run): {len(need)} picture{'s' if len(need) != 1 else ''}"
            f"{f' ({len(carried)} carried)' if carried else ''}, {len(s.routes)} routes — {shown}")
    return line + (f"; {s.hint}" if s.hint else "") + (f" ({since})" if since else "")


def main():
    if len(sys.argv) < 2:
        die("usage: select | pending | plan | keys | record | record-routes | lab-id")
    command, args = sys.argv[1], sys.argv[2:]
    if command == "pending":
        # One line, always: a start that cannot be found is said loudly, never read as nothing pending.
        try:
            _, s, carried, _ = selection(args)
        except CannotCompute as error:
            print(f"Render: cannot compute: {error}")
            sys.exit(2)
        except SystemExit:
            print(f"Render: cannot compute: {LAST_DIE[-1] if LAST_DIE else 'see the messages above'}")
            sys.exit(2)
        except (OSError, subprocess.CalledProcessError) as error:
            print(f"Render: cannot compute: {error}")
            sys.exit(2)
        print(pending_line(s, carried))
    elif command in ("select", "plan"):
        try:
            m, s, carried, _ = selection(args)
        except CannotCompute as error:
            die(f"cannot compute: {error}")
        if command == "select":
            for p in sorted(s.pictures):
                state = f"carried {carried[p]}" if p in carried else "run"
                print(f"  {p[0]}:{p[1]}:{s.kinds[(p[0], p[1])]}  {p[2]}  {state}  — {'; '.join(sorted(s.pictures[p]))}")
            for r in sorted(s.routes):
                print(f"  route {r}  — {'; '.join(sorted(s.routes[r]))}")
            for path in s.unmatched:
                print(f"  {path}: no rule: nothing")
            print(pending_line(s, carried))
        else:
            groups = {}
            for p in s.pictures:
                if p not in carried:
                    groups.setdefault((p[0], p[1]), set()).add(p[2])
            by_views = {}
            for (d, key), views in groups.items():
                ordered = ",".join(v for v in m.viewsets["all"] if v in views)
                by_views.setdefault(ordered, []).append(f"{d}:{key}:{s.kinds[(d, key)]}")
            for views in sorted(by_views):   # one line an entry: a key may hold a space
                for e in sorted(by_views[views]):
                    print(f"views\t{views}\t{e}")
            if s.routes:
                print(f"routes\t{','.join(sorted(s.routes))}")
    elif command == "keys":
        lab, views, entries = None, None, []
        while args:
            a = args.pop(0)
            if a == "--lab-id" and args:
                lab = args.pop(0)
            elif a == "--views" and args:
                views = args.pop(0).split(",")
            else:
                entries.append(a)
        if not lab:
            die("keys: --lab-id names the lab the pictures are rendered with")
        m = read_map(MAP)
        views = views or m.viewsets["all"]
        files, ids_ = listing(), dict_ids(m)
        for e in entries:
            part = e.split(":")
            if len(part) not in (2, 3) or not all(part):
                die(f"keys: {e!r} is not <dict>:<key>[:<kind>]")
            for v in views:
                p = (part[0], part[1], v)
                k = picture_key(p, style_manifest(files, m, v), lab, ids_.get(part[0]))
                if k:
                    print(f"{p[0]}:{p[1]}@{v}\t{k}")
    elif command == "record":
        if len(args) != 4 or args[0] not in ("--keys", "--lab-id") or args[2] != "--report":
            die("usage: record --keys <keys.tsv> | --lab-id <id>  --report <report.json>")
        rows = passed_rows(json.load(open(args[3], encoding="utf-8")))
        if args[0] == "--keys":
            keyed = dict(line.split("\t", 1) for line in open(args[1], encoding="utf-8").read().splitlines()
                         if "\t" in line)
        else:   # run.sh: the kit's lab, of this tree, with the style bundled in it (this tree's)
            m = read_map(MAP)
            files, ids_ = listing(), dict_ids(m)
            keyed = {}
            for d, k, v in rows:
                key = picture_key((d, k, v), style_manifest(files, m, v), args[1], ids_.get(d))
                if key and v in m.viewsets["all"]:
                    keyed[f"{d}:{k}@{v}"] = key
        found = [(keyed[f"{d}:{k}@{v}"], (d, k, v)) for d, k, v in rows if f"{d}:{k}@{v}" in keyed]
        append_passes(PASSES, found)
        print(f"render: recorded {len(found)} passes in {PASSES}")
        try_advance()
    elif command == "record-routes":
        ids = route_ids()
        wanted = [r for a in args for r in a.split(",") if r]
        for r in wanted:
            if r not in ids:
                die(f"record-routes: no route {r}")
        if not wanted:
            die("record-routes: name the routes that passed")
        tree = tree_id(listing())
        os.makedirs(CACHE, exist_ok=True)
        now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with open(ROUTE_PASSES, "a", encoding="utf-8") as out:
            out.writelines(f"v1\t{tree}\t{r}\t{now}\n" for r in wanted)
        print(f"render: recorded {len(wanted)} route passes in {ROUTE_PASSES}")
        try_advance()
    elif command == "lab-id":
        print(lab_id(listing()))
    else:
        die(f"no command {command}")


if __name__ == "__main__":
    main()
