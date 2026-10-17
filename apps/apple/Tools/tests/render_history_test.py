#!/usr/bin/env python3
"""Tests of Tools/gallery/render_affected.py's history: what is pending is the reach of every change since the last tree
whose selected pictures and routes all passed, never only the diff against a branch.

A merged change whose pictures were never rendered stays pending across later commits; a passing render clears exactly
its pictures; once everything selected has passed, that commit becomes the new start; with no git history the tool
says so loudly, in one line, and never "nothing". Built in a scratch repository; renders nothing, reaches no host.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
APPLE = os.path.dirname(os.path.dirname(HERE))
REPO = os.path.dirname(os.path.dirname(APPLE))
TOOL = os.path.join(APPLE, "Tools", "gallery", "render_affected.py")
STYLE = "apps/apple/Sources/XDictEntryView/Style/"
POPOVER = "apps/apple/Sources/XDictUI/LookupPopover.swift"
failures = 0


def check(name, condition, detail=""):
    global failures
    print(f"ok    {name}" if condition else f"FAIL  {name}: {detail}")
    failures += 0 if condition else 1


scratch = tempfile.mkdtemp()
try:
    repo = os.path.join(scratch, "repo")
    for path in ("core/xdict-entry/src/roles/profiles.rs", "apps/apple/Tools/gallery/style-ledger.tsv"):
        os.makedirs(os.path.dirname(os.path.join(repo, path)), exist_ok=True)
        shutil.copy(os.path.join(REPO, path), os.path.join(repo, path))
    for path in (STYLE + "type.css", STYLE + "colour-core.js", POPOVER, "dev-docs/notes.md"):
        os.makedirs(os.path.dirname(os.path.join(repo, path)), exist_ok=True)
        open(os.path.join(repo, path), "w").write("a\n")

    def git(*args):
        return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=True).stdout.strip()

    def commit(path, text):
        open(os.path.join(repo, path), "a").write(text)
        git("add", "-A")
        git("-c", "core.hooksPath=/dev/null", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", path)
        return git("rev-parse", "HEAD")

    git("init", "-q")
    anchor = commit("dev-docs/notes.md", "start\n")
    m_dicts = [l.split()[1:] for l in open(os.path.join(APPLE, "Tools/gallery/render-affected.map")) if l.startswith("dicts ")][0]
    keys_file = os.path.join(scratch, "keys.json")
    json.dump({"rows": [{"dict": d, "kind": k, "key": f"{d}-{k}"} for d in m_dicts for k in ("short", "long", "media")]},
              open(keys_file, "w"))
    corpus = os.path.join(scratch, "corpus")
    for d in m_dicts:
        os.makedirs(os.path.join(corpus, d))
        open(os.path.join(corpus, d, "a.mdx"), "w").write(d)
    cache = os.path.join(scratch, "cache")
    env = dict(os.environ, XDICT_RENDER_REPO=repo, XDICT_GATE_REPO=repo, XDICT_GALLERY_KEYS=keys_file,
               XDICT_RENDER_CORPUS=corpus, XDICT_RENDER_CACHE=cache, XDICT_RENDER_LAB_ID="lab-test",
               XDICT_RENDER_ANCHOR=anchor, XDICT_GATE_CACHE=os.path.join(scratch, "gates"))
    env.pop("CLAUDECODE", None)
    env.pop("FULL", None)

    def run(*args, environment=None):
        r = subprocess.run([sys.executable, "-I", TOOL, *args], capture_output=True, text=True, env=environment or env)
        return r.returncode, r.stdout.strip(), r.stderr

    def record_all(skip=0):
        _, plan, _ = run("plan")
        entries = [l.split("\t") for l in plan.splitlines() if l.startswith("views\t")]
        rows = [{"dict": e[2].split(":")[0], "key": e[2].split(":")[1], "kind": e[2].split(":")[2], "mode": v}
                for e in entries for v in e[1].split(",")][skip:]
        _, keyed, _ = run("keys", "--lab-id", "lab-test", "--views", "core-light,core-dark",
                          *[e[2] for e in entries])
        open(os.path.join(scratch, "k.tsv"), "w").write(keyed + "\n")
        json.dump({"rows": rows, "failures": []}, open(os.path.join(scratch, "r.json"), "w"))
        return run("record", "--keys", os.path.join(scratch, "k.tsv"), "--report", os.path.join(scratch, "r.json"))

    code, out, err = run("pending")
    check("nothing changed since the anchor: nothing pending", code == 0 and out.startswith("Render: nothing pending"), out + err)
    commit(STYLE + "type.css", "b\n")
    code, out, err = run("pending")
    check("a shared-style change: 24 pictures, since the anchor, said",
          out.startswith("Render needed (not run): 24 pictures") and anchor[:12] in out and "no render has passed" in out,
          out + err)
    commit("dev-docs/notes.md", "later\n")
    code, out, err = run("pending")
    check("merged but never rendered: still pending after a later commit",
          out.startswith("Render needed (not run): 24 pictures"), out + err)

    code, out, err = record_all(skip=1)
    check("a render with one picture short records the rest", code == 0 and "recorded 23" in out, out + err)
    code, out, err = run("pending")
    check("a passing render clears exactly its pictures: 1 left", out.startswith("Render needed (not run): 1 picture"),
          out + err)
    code, out, err = record_all()
    code, out, err = run("pending")
    check("all passed: nothing pending", out.startswith("Render: nothing pending"), out + err)
    head = git("rev-parse", "HEAD")
    commit(STYLE + "colour-core.js", "c\n")
    code, out, err = run("pending")
    check("the next change counts from the last fully rendered commit, not the anchor",
          out.startswith("Render needed (not run): 24 pictures") and head[:12] in out and anchor[:12] not in out, out + err)

    commit(POPOVER, "d\n")
    code, out, err = run("pending")
    check("a popover change adds its routes", "routes" in out and " 0 routes" not in out, out)
    _, plan, _ = run("plan")
    routes = [l.split("\t")[1] for l in plan.splitlines() if l.startswith("routes\t")]
    code, out, err = run("record-routes", routes[0] if routes else "")
    check("record-routes files the tour's pass", code == 0 and "recorded" in out, out + err)
    code, out, err = run("pending")
    check("routes passed, pictures not: only the pictures pending",
          out.startswith("Render needed (not run): 24 pictures, 0 routes"), out + err)
    record_all()
    code, out, err = run("pending")
    check("everything passed: nothing pending", out.startswith("Render: nothing pending"), out + err)

    # No history: one loud line, a non-zero exit, no traceback, never "nothing".
    bare = os.path.join(scratch, "bare")
    shutil.copytree(repo, bare, ignore=shutil.ignore_patterns(".git"))
    code, out, err = run("pending", environment=dict(env, XDICT_RENDER_REPO=bare, XDICT_GATE_REPO=bare))
    check("no git history: says it cannot compute", code != 0 and out.startswith("Render: cannot compute: no git history")
          and len(out.splitlines()) == 1 and "Traceback" not in err, (code, out, err[-300:]))
    # A start commit that is not in this history (a shallow or foreign copy): loud too.
    code, out, err = run("pending", environment=dict(env, XDICT_RENDER_ANCHOR="0" * 40,
                                                       XDICT_RENDER_CACHE=os.path.join(scratch, "empty")))
    check("a missing start commit: says it cannot compute", code != 0 and out.startswith("Render: cannot compute"),
          (code, out, err[-300:]))
finally:
    shutil.rmtree(scratch)
print(f"render-history: {failures} failure(s)")
sys.exit(1 if failures else 0)
