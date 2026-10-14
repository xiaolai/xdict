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
sequence = 0


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


def step(name, action, settle=1.5):
    before = len(ask("state").get("events", []))
    started = time.time()
    action()
    time.sleep(settle)
    state = ask("state")
    prompt = ask("prompt")
    steps.append({"step": name, "t0": started, "t1": time.time(), "events": state.get("events", [])[before:],
                  "prompt": prompt.get("presented", False), "promptMessage": prompt.get("message"),
                  "opened": state.get("opened", []), "drops": len(state.get("drops", []))})
    return prompt


def answer(prompt, button):
    """Clicks a button of the consent prompt, as a reader would; returns whether there was one to click."""
    if not prompt.get("presented"):
        return False
    hand("click", *prompt["buttons"][button])
    time.sleep(1.0)
    return True


def at(name):
    return targets[name]


for name in ["link-remote", "link-ip", "link-download", "img-remote", "img-local", "link-image"]:
    step(f"hover {name}", lambda name=name: hand("move", *at(name)), settle=0.8)

for name, mods in [("link-remote", "none"), ("link-remote", "cmd"), ("link-ip", "shift"), ("link-ip", "opt"),
                   ("link-remote", "cmd+shift"), ("link-image", "none")]:
    p = step(f"click {name} {mods}", lambda name=name, mods=mods: hand("click", *at(name), mods))
    steps[-1]["answered"] = "cancel" if answer(p, "cancel") else None

for name in ["link-download", "link-resource-download"]:
    p = step(f"click {name}", lambda name=name: hand("click", *at(name)))
    steps[-1]["answered"] = "cancel" if answer(p, "cancel") else None

for name in ["link-remote", "img-remote", "img-local", "link-image"]:
    step(f"context menu {name}", lambda name=name: hand("click", *at(name), "none", "right"), settle=1.0)
    hand("key", "escape")
    time.sleep(0.5)

step("click link-entry", lambda: hand("click", *at("link-entry")))
p = step("click img-remote placeholder", lambda: hand("click", *at("img-remote")))
steps[-1]["answered"] = "open" if answer(p, "open") else None
steps[-1]["openedAfter"] = ask("state").get("opened", [])

for name in ["img-data", "img-raster", "img-local", "img-remote", "link-image", "link-remote"]:
    # The reader's window first, as a hand would come back to it after dropping elsewhere: a click on plain text.
    hand("click", *at("text"))
    time.sleep(0.5)
    before = len(ask("deselect").get("drops", []))
    step(f"drag {name}", lambda name=name: hand("drag", *at(name), *drop), settle=2.0)
    dropped = ask("state").get("drops", [])[before:]
    steps[-1]["dropped"] = [{k: d.get(k) for k in ("types", "url", "string", "promises", "promised")} for d in dropped]

final = ask("state")
with open(out + ".tmp", "w") as f:
    json.dump({"access": access, "targets": targets, "drop": drop, "steps": steps, "final": final}, f, indent=1)
os.replace(out + ".tmp", out)
ask("quit")
print(f"reader: {len(steps)} steps")
