#!/usr/bin/env python3
"""A reader's keyboard on the main window, and VoiceOver's reading of it (plan-macos-v1 WI-6, R10), for the E2E
`lookup` stage: real key events (`keys`, posted into the HID stream) on the real app started with `--lookup-window`,
asked through its command directory (`Sources/XDict/LookupWindow.swift`).

    python3 -I drive.py <kit> <work> <app> <driver.json>

The whole flow with key events alone: the search field has the keyboard at launch; a word typed and Return; ↓ into the
results and through them; Tab into the entry and to its first link, Return to follow it; Back, Forward and Return to
Original Word by their shortcuts; Search (⌥⌘F); a dictionary's scope (⌥⌘2) and every dictionary (⌥⌘0); a suggestion
chosen with ↓ and Return. After each, the app says what it holds and what the keyboard reached. Then the app's scenario
runs (`LookupScenario`); at each of its checkpoints the window is read through the Accessibility API, as VoiceOver
reads it, against what the app says it must show. Writes `Findings` (checks and facts) to <driver.json>.

**The app must have the front for every key** (as `Tools/hostile/reader.py`'s `hold`): another application can take
the E2E Mac's front at any moment. Before each key the app is asked to come forward, then LaunchServices; a key that
did not reach the app while it was active and its main window key stops the run naming who held the front, so a key
that went elsewhere never reads as the app's failure.
"""
import json
import os
import subprocess
import sys
import time

kit, work, app, out = sys.argv[1:5]
keys = os.path.join(kit, "lookup", "keys")
commands = os.path.join(work, "commands")
DEADLINE = 6.0
sequence = 0
checks = []
facts = {}


def write_out():
    with open(out + ".tmp", "w") as f:
        json.dump({"checks": checks, "facts": facts}, f, indent=1, sort_keys=True)
    os.replace(out + ".tmp", out)


def check(name, ok, detail):
    checks.append({"name": name, "pass": bool(ok), "detail": str(detail)[:1500]})
    print(f"{'PASS' if ok else 'FAIL'}  {name}: {str(detail)[:300]}", flush=True)


def abort(why):
    check("driver.ran", False, why)
    write_out()
    try:
        ask("quit", wait=3)
    except SystemExit:
        pass
    raise SystemExit(f"drive: {why}")


def ask(op, wait=30):
    global sequence
    sequence += 1
    path = os.path.join(commands, f"{sequence:03d}.json")
    with open(path + ".tmp", "w") as f:
        json.dump({"op": op}, f)
    os.replace(path + ".tmp", path)
    answer = os.path.join(commands, f"{sequence:03d}.out.json")
    for _ in range(int(wait * 20)):
        if os.path.exists(answer):
            try:
                return json.load(open(answer))
            except ValueError:
                pass
        time.sleep(0.05)
    raise SystemExit(f"drive: the app did not answer {op}")


def tool(*args):
    done = subprocess.run([keys, *map(str, args)], capture_output=True, text=True, timeout=60)
    if done.returncode != 0:
        abort(f"keys {' '.join(map(str, args))} failed: {done.stderr.strip()}")
    return json.loads(done.stdout) if done.stdout.strip().startswith("{") else None


def hold(name):
    """The app frontmost and its main window key, before `name`; else, within DEADLINE, the run stops naming why."""
    deadline = time.time() + DEADLINE
    asked_launchservices = False
    while True:
        front = tool("front")
        state = ask("state")
        if front.get("pid") == pid and state.get("active") and state.get("mainIsKey"):
            return state
        if front.get("displayAsleep"):
            subprocess.run(["caffeinate", "-u", "-t", "1"], capture_output=True)
        if time.time() > deadline:
            abort(f"before {name!r} the app could not have the E2E Mac's front within {DEADLINE:g} s: "
                  f"{front.get('name')!r} (pid {front.get('pid')}) has it; the app is "
                  f"{'active' if state.get('active') else 'not active'}, its main window "
                  f"{'key' if state.get('mainIsKey') else 'not key'}")
        ask("front")
        if not asked_launchservices and time.time() > deadline - DEADLINE / 2:
            asked_launchservices = True
            subprocess.run(["open", app], capture_output=True)
        time.sleep(0.3)


def press(combo, settle=0.8, name=None):
    """One key, held to the app; answers the app's state after it, once it has seen the key arrive."""
    name = name or combo
    before = hold(name)
    seen = len(before.get("keys", []))
    tool("press", combo)
    time.sleep(settle)
    after = ask("state")
    arrived = after.get("keys", [])[seen:]
    if not arrived or not all(k.get("active") and k.get("key") for k in arrived):
        front = tool("front")
        abort(f"{name!r} did not reach the app's main window while it was active ({arrived}); the front is "
              f"{front.get('name')!r} (pid {front.get('pid')})")
    return after


def type_text(text, settle=0.8):
    before = hold(f"type {text}")
    seen = len(before.get("keys", []))
    tool("type", text)
    time.sleep(settle)
    after = ask("state")
    arrived = after.get("keys", [])[seen:]
    if len(arrived) < len(text) or not all(k.get("active") and k.get("key") for k in arrived):
        abort(f"typing {text!r}: only {len(arrived)} of {len(text)} keys reached the app's main window while it was "
              f"active")
    return after


def until(predicate, seconds=10.0):
    end = time.time() + seconds
    state = ask("state")
    while not predicate(state) and time.time() < end:
        time.sleep(0.2)
        state = ask("state")
    return state


def shown(state):
    s = state.get("shown") or {}
    return f"{s.get('dictionary')}/{s.get('key')}" if s else "nothing"


def sections(state):
    return [(s["name"], s["status"]) for s in state.get("sections", [])]


def ax_nodes():
    tree = tool("ax", pid) or {}
    return tree.get("nodes", []), tree


def judge(name, expect, nodes):
    """Holds the window, as read, to what the app said it must show."""
    texts = [(n.get("id", ""), n.get("texts", [])) for n in nodes]

    def where(item):
        if item.startswith("#") and ":" in item:
            ident, text = item[1:].split(":", 1)
            return next((i for i, (nid, ts) in enumerate(texts) if nid == ident and text in ts), None)
        return next((i for i, (_, ts) in enumerate(texts) if item in ts), None)

    missing = [p for p in expect.get("present", []) if where(p) is None]
    found = [a for a in expect.get("absent", []) if where(a) is not None]
    order = [where(o) for o in expect.get("ordered", [])]
    in_order = all(i is not None for i in order) and order == sorted(order)
    ok = bool(nodes) and not missing and not found and in_order
    detail = (f"{len(nodes)} elements; missing {missing}; present though absent {found}; order "
              f"{list(zip(expect.get('ordered', []), order))}")
    return {"name": f"ax.{name}", "pass": ok, "detail": detail}


def results_read(nodes, names, own_labels):
    """VoiceOver's reading of the results (R10, R11): at least two, each an element of a known role (one whose role is
    unknown VoiceOver may pass over), each naming one of the window's dictionaries, the first two as the app labels
    them."""
    results = [n for n in nodes if n.get("id") == "result"]
    labels = [" ".join(n.get("texts", [])) for n in results]
    named = [label for label in labels if any(d in label for d in names)]
    roles = sorted({n.get("role", "") for n in results})
    own = own_labels[:2]
    read = all(any(label in n.get("texts", []) for n in results) for label in own)
    known = bool(roles) and "AXUnknown" not in roles and "" not in roles
    ok = len(results) >= 2 and len(named) == len(labels) and len(own) == 2 and read and known
    return ok, (f"{len(results)} results read, as {roles}: {labels[:6]}; the app's own labels {own_labels[:4]}")


def link_focus(web, text):
    """VoiceOver's reading of the entry once Tab has reached a link (R10): the link `text` is in the entry's tree and
    alone has the keyboard, and the app's focused element, read after the entry (as VoiceOver reads it), is that link."""
    links = (web.get("web") or {}).get("links", [])
    focused = web.get("focused") or {}
    on = [link for link in links if link.get("focused")]
    ok = (len(on) == 1 and text in on[0].get("texts", []) + on[0].get("inner", [])
          and focused.get("role") == "AXLink" and text in focused.get("texts", []))
    detail = (f"{(web.get('web') or {}).get('elements', 0)} elements in the entry; links "
              f"{[(link.get('texts'), link.get('focused')) for link in links][:6]}; the app's focused element "
              f"{focused.get('role')} {focused.get('texts')}")
    return ok, detail


# ---------------------------------------------------------------------------------------------------------------------
ready_path = os.path.join(commands, "ready.json")
for _ in range(9000):
    if os.path.exists(ready_path):
        break
    time.sleep(0.1)
else:
    raise SystemExit("drive: the app never became ready")
time.sleep(0.2)
ready = json.load(open(ready_path))
pid = ready["pid"]
access = tool("access")
facts["access"] = json.dumps(access)
if not (access.get("accessibility") and access.get("postEvents")):
    abort(f"this session may not post events or read the window ({access})")
if not ready.get("setup"):
    abort(f"the app's library was not set up: {ready.get('detail')}")

# The search field has the keyboard at launch, with nothing pressed yet (I1).
state = until(lambda s: s.get("responder") == "search", 5)
focused = tool("focused", pid) or {}
f = focused.get("focused") or {}
check("launch.searchFocused", state.get("responder") == "search" and f.get("id") == "search-field",
      f"the window's first responder: {state.get('responder')}; the focused element as VoiceOver finds it: "
      f"{f.get('role')} #{f.get('id')} {f.get('texts')}")

# The first query, with no pointer: typed, Return.
state = type_text("apple")
check("keyboard.typed", state.get("text") == "apple", f"the field holds {state.get('text')!r}; suggestions "
      f"{state.get('suggestions')}")
press("return", settle=0.2)
state = until(lambda s: s.get("query") == "apple" and s.get("shown") and all(st != "searching" for _, st in sections(s)))
check("keyboard.firstQueryNoPointer",
      state.get("query") == "apple" and shown(state) == "Alpha/apple" and state.get("responder") == "search"
      and ("Alpha", "results") in sections(state) and ("Beta", "results") in sections(state),
      f"looked up {state.get('query')!r}: {sections(state)}; shown {shown(state)}; the keyboard stays in "
      f"{state.get('responder')}")

# VoiceOver reads each result with its dictionary (R10, R11).
nodes, _ = ax_nodes()
names = state.get("dictionaries", [])
read_ok, read_detail = results_read(nodes, names, state.get("resultLabels", []))
check("voiceover.resultsNameTheirDictionary", read_ok, read_detail)

# Down into the results, and through them.
state = press("down")
into = state.get("responder")
state = press("down")
moved = shown(state)
state = press("up")
check("keyboard.results", into == "results" and moved == "Beta/apple" and shown(state) == "Alpha/apple",
      f"↓ from the field: the keyboard in {into}; ↓ again shows {moved}; ↑ shows {shown(state)}")

# Tab into the entry, which lands on its first link (WebKit focuses the first element Tab reaches when the keyboard
# enters a page; `tabFocusesLinks` makes links such elements); Return follows it in link mode (I7). Should the page
# itself take the keyboard with no element in it, one more Tab must reach the link: the link must have it before
# Return. Which element has the keyboard is the page's own answer (`pageFocus`); what VoiceOver finds focused is kept
# beside it.
def focus_now():
    page = ask("pageFocus")
    ax = tool("focused", pid) or {}
    f = ax.get("focused") or {}
    seen = (f"page {page.get('tag') or 'nothing'} {page.get('text', '')!r} (has focus {page.get('hasFocus')}); "
            f"AX {f.get('role')} {f.get('texts')} in {ax.get('ancestors', [])[:4]}")
    return page, f, seen


state = press("tab")
entry = state.get("responder")
page, ax_on, seen = focus_now()
steps = [f"Tab 1: {entry}, {seen}"]
if page.get("tag") != "A":
    state = press("tab")
    page, ax_on, seen = focus_now()
    steps.append(f"Tab 2: {state.get('responder')}, {seen}")
on_link = page.get("tag") == "A" and page.get("href") is True and "banana" in page.get("text", "")
# The entry as VoiceOver reads it: its links, the one with the keyboard, and the app's focused element read after.
web = tool("web", pid) or {}
facts["linkFocus"] = json.dumps({"page": page, "ax": ax_on, "web": web})
state = press("return", settle=0.2)
state = until(lambda s: s.get("query") == "banana" and s.get("shown"))
check("keyboard.entry", entry == "entry", f"Tab from the results: the keyboard in {entry}")
check("keyboard.linkFollowed", on_link and state.get("query") == "banana"
      and state.get("mode") == "link" and shown(state) == "Alpha/banana",
      f"{'; '.join(steps)}; Return: {state.get('query')!r} in {state.get('mode')} mode, "
      f"shown {shown(state)}; routed {state.get('routed', [])[-2:]}")
read_ok, read_detail = link_focus(web, "banana")
check("voiceover.linkFocused", on_link and read_ok, read_detail)

# Back, Forward, Return to Original Word (I8), by their shortcuts.
press("cmd+[", settle=0.2)
state = until(lambda s: s.get("query") == "apple" and s.get("shown"))
back = (state.get("query"), shown(state))
press("cmd+]", settle=0.2)
state = until(lambda s: s.get("query") == "banana" and s.get("shown"))
forward = (state.get("query"), shown(state))
press("cmd+opt+[", settle=0.2)
state = until(lambda s: s.get("query") == "apple" and s.get("shown"))
check("keyboard.back", back == ("apple", "Alpha/apple"), f"⌘[ returned to {back}")
check("keyboard.forwardAndOrigin", forward == ("banana", "Alpha/banana") and shown(state) == "Alpha/apple"
      and state.get("mode") == "reader", f"⌘] went to {forward}; ⌥⌘[ returned to {state.get('query')!r} "
      f"({state.get('mode')}), shown {shown(state)}")

# Search (⌥⌘F) gives the field the keyboard from anywhere.
press("tab")
state = press("cmd+opt+f")
check("keyboard.searchCommand", state.get("responder") == "search", f"⌥⌘F: the keyboard in {state.get('responder')}")

# The scope, from the keyboard, and in sight (Q1).
state = press("cmd+opt+2", settle=0.3)
state = until(lambda s: all(st != "searching" for _, st in sections(s)), 5)
second = names[1] if len(names) > 1 else "?"
scoped = (state.get("scope"), [n for n, _ in sections(state)])
nodes, _ = ax_nodes()
scope_texts = [n.get("texts") for n in nodes if n.get("id") == "scope"]
check("keyboard.scope", scoped == (second, [second]), f"⌥⌘2: scope {scoped[0]!r}, sections {scoped[1]}")
check("voiceover.scopeVisible", any(second in ts for ts in scope_texts),
      f"the toolbar's scope, as read: {scope_texts}")
state = press("cmd+opt+0", settle=0.3)
check("keyboard.scopeAll", state.get("scope") == "all", f"⌥⌘0: scope {state.get('scope')!r}")

# A suggestion, chosen with the keyboard (Q6).
state = press("cmd+opt+f")
press("cmd+a", settle=0.2)
state = type_text("take o", settle=1.0)
offered = state.get("suggestions", [])
press("down", settle=0.3)
state = press("return", settle=0.2)
state = until(lambda s: s.get("query") == "take off" and s.get("shown"))
check("keyboard.suggestion", "take off" in offered and state.get("query") == "take off"
      and shown(state) == "Alpha/take off", f"typing 'take o' offered {offered}; ↓ and Return looked up "
      f"{state.get('query')!r}, shown {shown(state)}")
facts["keys"] = json.dumps(state.get("keys", [])[-40:])

# The scenario, through the window; each checkpoint read as VoiceOver reads it.
ask("run")
done_names = set()
findings_path = os.path.join(work, "findings.json")
end = time.time() + 1800
while time.time() < end:
    for name in sorted(os.listdir(commands)):
        if (not name.startswith("checkpoint-") or not name.endswith(".json") or name.endswith(".done.json")
                or name in done_names):
            continue
        try:
            point = json.load(open(os.path.join(commands, name)))
        except ValueError:
            continue
        done_names.add(name)
        nodes, tree = ax_nodes()
        # The verdict goes back to the app, whose findings carry it: the stage reads it there, once.
        verdict = judge(point["name"], point.get("expect", {}), nodes)
        print(f"{'PASS' if verdict['pass'] else 'FAIL'}  {verdict['name']}: {verdict['detail'][:300]}", flush=True)
        with open(os.path.join(commands, f"ax-{point['name']}.json"), "w") as f:
            json.dump(tree, f)
        done = os.path.join(commands, name.replace(".json", ".done.json"))
        with open(done + ".tmp", "w") as f:
            json.dump({"checks": [verdict], "facts": {}}, f)
        os.replace(done + ".tmp", done)
    if os.path.exists(findings_path):
        break
    time.sleep(0.1)
check("driver.ran", os.path.exists(findings_path),
      f"the scenario {'wrote its findings' if os.path.exists(findings_path) else 'never finished'}; "
      f"{len(done_names)} checkpoints read")
write_out()
ask("quit", wait=5)
