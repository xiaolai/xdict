#!/usr/bin/env python3
"""A person's hands on the battery's `reader` entry (plan-macos-v1 WI-4; ADR-0009 refutation, item 8): real pointer
events (`pointer`, posted into the HID stream) on a production entry view in the lab, asked through its command
directory (`Sources/XDictEntryLab/Reader.swift`).

    python3 -I reader.py <kit> <commands-dir> <steps.json>

Hover; plain, command-, option- and shift-clicks on links; clicks on a download link and on a resource download; the
context menu on a link and on images; a click on a remote image's placeholder; drags of a link and of images out of the
view into a drop target. Every remote question is answered "Cancel" with a real click on the native button, except the
placeholder's, answered "Open in Browser": the one URL the lab's opener may record. What the observers saw is the
analysis's to say (`analyze.py reader`); this writes what was done, and what the view recorded during each step.
"""
import json
import os
import subprocess
import sys
import time

kit, commands, out = sys.argv[1:4]
pointer = os.path.join(kit, "pointer")
lab_app = os.path.join(kit, "XDictEntryLab.app")
sequence = 0
# How long a hand waits for the lab to have the front before it gives up and says why (see `hold`).
DEADLINE = 6.0


def ask(op):
    global sequence
    sequence += 1
    path = os.path.join(commands, f"{sequence:03d}.json")
    with open(path + ".tmp", "w") as f:
        json.dump({"op": op}, f)
    os.replace(path + ".tmp", path)
    answer = os.path.join(commands, f"{sequence:03d}.out.json")
    for _ in range(300):
        if os.path.exists(answer):
            try:
                return json.load(open(answer))
            except ValueError:
                pass
        time.sleep(0.1)
    raise SystemExit(f"reader: the lab did not answer {op}")


def hand(*args):
    done = subprocess.run([pointer, *map(str, args)], capture_output=True, text=True)
    if done.returncode != 0:
        raise SystemExit(f"reader: pointer {' '.join(map(str, args))} failed: {done.stderr.strip()}")


def screen(*points):
    """What a hand would meet at each point (`pointer screen`): the session, the display, the frontmost application and
    the windows over the point. A step that went wrong says from this, and the lab's own focus, why."""
    flat = [str(v) for p in points for v in p]
    done = subprocess.run([pointer, "screen", *flat], capture_output=True, text=True)
    try:
        return json.loads(done.stdout)
    except ValueError:
        return {"error": f"pointer screen exited {done.returncode}: {done.stderr.strip()[:200]}"}


def scene(*points):
    return {"lab": ask("focus"), "screen": screen(*points)}


ready = os.path.join(commands, "ready.json")
for _ in range(600):
    if os.path.exists(ready):
        break
    time.sleep(0.1)
else:
    raise SystemExit("reader: the lab never became ready")
access = subprocess.run([pointer, "access"], capture_output=True, text=True).stdout.strip()
first = json.load(open(ready))
targets, drop = first.get("targets", {}), first.get("drop", [])
need = ["link-remote", "link-ip", "link-download", "link-resource-download", "link-entry", "img-remote", "img-local",
        "img-data", "img-raster", "link-image", "text"]
missing = [t for t in need if t not in targets]
if missing or len(drop) != 2:
    raise SystemExit(f"reader: no position for {missing or 'the drop target'}: {first}")

steps = []
lab_pid = ask("state").get("pid")


def abort(why):
    """Stops the run, loudly, keeping what was done so far for reading. The analysis never sees a partial run."""
    with open(out + ".tmp", "w") as f:
        json.dump({"access": access, "targets": targets, "drop": drop, "steps": steps, "aborted": why}, f, indent=1)
    os.replace(out + ".tmp", out.replace(".json", ".aborted.json"))
    raise SystemExit(f"reader: {why}")


def obstacles(seen, points, key):
    """What stands between a hand and the lab at these points; empty when nothing does. `key` is "reader" when the
    reader window must be key, "any" when any of the lab's windows may be (the prompt's sheet, an open context menu)."""
    lab, scr = seen["lab"], seen["screen"]
    found = [scr["error"]] if "error" in scr else []
    if scr.get("locked"):
        found.append("the screen is locked")
    if not scr.get("onConsole", True):
        found.append("the session is not on the console")
    if scr.get("displayAsleep"):
        found.append("the display is asleep")
    front = scr.get("frontmost", {})
    if not lab.get("active") or front.get("pid") != lab_pid:
        found.append(f"{front.get('name')!r} (pid {front.get('pid')}) is the frontmost application, not the lab "
                     f"(pid {lab_pid})")
    if key == "reader" and not lab.get("key"):
        found.append(f"the reader window is not key (the key window is {lab.get('keyWindow')!r})")
    for point, windows in zip(points, scr.get("at", [])):
        # The first window at an ordinary level (normal to modal panel, below the Dock's 20) takes the click; the
        # system's transparent overlays above it (Notification Center's, 21) let events through.
        top = next((w for w in windows if 0 <= w.get("layer", 0) < 20), {})
        if top.get("pid") != lab_pid:
            found.append(f"{top.get('owner', 'no window')!r} (pid {top.get('pid')}) is over {point}")
    return found


def hold(name, points, key="reader"):
    """**The precondition of every action of the hand**: the lab is the frontmost application, its reader window is key,
    and no other application's window is over the points the action uses. Another application can take the E2E Mac's
    front at any moment (2026-10-14: an Accessibility prompt, System Settings and a person's applications took it about
    75 times during one reader run, and the clicks that followed only activated the lab or landed on another window).

    A hand brings the window forward before it clicks; so does this: the lab orders its windows front and asks to be
    active, LaunchServices is asked as `open` asks it when the lab's own asking is declined, and a sleeping display is
    woken. Then it waits, until `DEADLINE`, and stops the run naming what stood in the way. Returns the scene before
    the action and what had to be put right (None when nothing did)."""
    seen = scene(*points)
    found = obstacles(seen, points, key)
    if not found:
        return seen, None
    first, deadline, asked_launchservices = found, time.time() + DEADLINE, False
    ask("front")
    while True:
        if seen["screen"].get("displayAsleep"):
            subprocess.run(["caffeinate", "-u", "-t", "1"], capture_output=True)
        time.sleep(0.25)
        seen = scene(*points)
        found = obstacles(seen, points, key)
        if not found:
            return seen, {"found": first, "launchServices": asked_launchservices,
                          "took": round(DEADLINE - (deadline - time.time()), 2)}
        if time.time() >= deadline:
            abort(f"before {name!r} the lab could not have the E2E Mac's front within {DEADLINE:g} s: "
                  f"{'; '.join(found)} (at first: {'; '.join(first)})")
        if not asked_launchservices and not seen["lab"].get("active") and time.time() >= deadline - DEADLINE / 2:
            asked_launchservices = True
            subprocess.run(["open", lab_app], capture_output=True)
            ask("front")


def delivered(name, timeline, press, points, started, ended):
    """**The action reached the lab, and nothing took the front while it ran.** Its press (`press`: the button event the
    lab's monitor sees, or None for a hover or a key) must have reached the lab while the lab was active and the
    event's window key; and no other application may have been activated, nor the lab have stopped being active,
    between the action's start and its end. Otherwise its events may have gone to another window, or only activated
    the lab (a web view takes no first click on a link): the step measured nothing, and the run stops naming why,
    rather than reading as the entry view's failure. An application activated after the action ended is met by the
    next `hold`."""
    during = [e for e in timeline if started - 0.05 <= e.get("t", 0) <= ended + 0.3]
    others = [e for e in during if e.get("what") == "activated" and e.get("appPid") != lab_pid]
    if others or any(e.get("what") == "app DidResignActive" for e in during):
        who = ", ".join(f"{e.get('app')!r} (pid {e.get('appPid')})" for e in others) or "another application"
        abort(f"while {name!r} ran, {who} took the E2E Mac's front from the lab: the step measured nothing")
    if press is None:
        return
    got = [e for e in timeline if e.get("what") == press]
    if not any(e.get("active") and e.get("key") for e in got):
        now = scene(*points)
        front = now["screen"].get("frontmost", {})
        how = (f"reached it only while it was {'not active' if not got[0].get('active') else 'not key'}" if got
               else "never reached it")
        over = [[w.get("owner") for w in at][:3] for at in now["screen"].get("at", [])]
        abort(f"{name!r}: its {press} {how}; the frontmost application is {front.get('name')!r} (pid "
              f"{front.get('pid')}), over the points: {over}")


def act(name, action, points, press, key="reader", settle=0.0):
    """One action of the hand outside a step (an answer, a key, a click that brings the window back): held, done, and
    seen delivered."""
    hold(name, points, key)
    seen = len(ask("state").get("timeline", []))
    started = time.time()
    action()
    ended = time.time()
    time.sleep(settle)
    delivered(name, ask("state").get("timeline", [])[seen:], press, points, started, ended)


def step(name, action, points, press, settle=1.5):
    """One step: held (the lab has the front), the action, the settle, what the view and the lab's focus log recorded,
    and the action seen delivered (it reached the lab, and nothing took the front meanwhile)."""
    ahead, fixed = hold(name, points)
    first = ask("state")
    before, seen = len(first.get("events", [])), len(first.get("timeline", []))
    started = time.time()
    action()
    ended = time.time()
    time.sleep(settle)
    state = ask("state")
    prompt = ask("prompt")
    steps.append({"step": name, "t0": started, "t1": time.time(), "events": state.get("events", [])[before:],
                  "prompt": prompt.get("presented", False), "promptMessage": prompt.get("message"),
                  "opened": state.get("opened", []), "drops": len(state.get("drops", [])),
                  "before": ahead, "refocused": fixed, "after": state.get("focus"),
                  "received": state.get("timeline", [])[seen:]})
    delivered(name, steps[-1]["received"], press, points, started, ended)
    return prompt


def answer(prompt, button):
    """Clicks a button of the consent prompt, as a reader would; returns whether there was one to click."""
    if not prompt.get("presented"):
        return False
    point = prompt["buttons"][button]
    act(f"{steps[-1]['step']}: {button}", lambda: hand("click", *point), [point], "leftMouseDown", key="any",
        settle=1.0)
    return True


def at(name):
    return targets[name]


for name in ["link-remote", "link-ip", "link-download", "img-remote", "img-local", "link-image"]:
    step(f"hover {name}", lambda name=name: hand("move", *at(name)), [at(name)], None, settle=0.8)

for name, mods in [("link-remote", "none"), ("link-remote", "cmd"), ("link-ip", "shift"), ("link-ip", "opt"),
                   ("link-remote", "cmd+shift"), ("link-image", "none")]:
    p = step(f"click {name} {mods}", lambda name=name, mods=mods: hand("click", *at(name), mods), [at(name)],
             "leftMouseDown")
    steps[-1]["answered"] = "cancel" if answer(p, "cancel") else None

for name in ["link-download", "link-resource-download"]:
    p = step(f"click {name}", lambda name=name: hand("click", *at(name)), [at(name)], "leftMouseDown")
    steps[-1]["answered"] = "cancel" if answer(p, "cancel") else None

for name in ["link-remote", "img-remote", "img-local", "link-image"]:
    step(f"context menu {name}", lambda name=name: hand("click", *at(name), "none", "right"), [at(name)],
         "rightMouseDown", settle=1.0)
    # The menu's own tracking takes the key, so the lab's monitor never sees it: held and watched, not seen delivered.
    act(f"context menu {name}: escape", lambda: hand("key", "escape"), [], None, key="any", settle=0.5)

step("click link-entry", lambda: hand("click", *at("link-entry")), [at("link-entry")], "leftMouseDown")
p = step("click img-remote placeholder", lambda: hand("click", *at("img-remote")), [at("img-remote")], "leftMouseDown")
steps[-1]["answered"] = "open" if answer(p, "open") else None
steps[-1]["openedAfter"] = ask("state").get("opened", [])

for name in ["img-data", "img-raster", "img-local", "img-remote", "link-image", "link-remote"]:
    # The reader's window first, as a hand would come back to it after dropping elsewhere: a click on plain text.
    act(f"drag {name}: back to the reader", lambda: hand("click", *at("text")), [at("text")], "leftMouseDown",
        settle=0.5)
    before = len(ask("deselect").get("drops", []))
    step(f"drag {name}", lambda name=name: hand("drag", *at(name), *drop), [at(name), drop], "leftMouseDown",
         settle=2.0)
    dropped = ask("state").get("drops", [])[before:]
    steps[-1]["dropped"] = [{k: d.get(k) for k in ("types", "url", "string", "promises", "promised")} for d in dropped]

final = ask("state")
with open(out + ".tmp", "w") as f:
    json.dump({"access": access, "targets": targets, "drop": drop, "steps": steps, "final": final}, f, indent=1)
os.replace(out + ".tmp", out)
ask("quit")
print(f"reader: {len(steps)} steps")
