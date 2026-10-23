#!/usr/bin/env python3
"""Hover, driven through the capture lab (plan-capture WI-5), for the E2E `hover.*` sub-stages. Each check asks the
lab (`kit/XDictCaptureLab.app/Contents/MacOS/XDictCaptureLab --read-point X Y`) what it reads at one point of a fixture
window this driver opens, and holds the answer to what the fixture holds.

    python3 -I drive.py <kit> <work> <out.json> <sub-stage>...

`hover.accessibility`: the lab's own grants (`--access`), then a word TextEdit and a Safari page hold — which
Accessibility shares — read at its box's centre: the term, the acquisition that is not recognition, the measured box
and the sentence around it. `hover.exclusions`: a point of Passwords, whose app the shipped policy excludes, stays quiet
and never reaches recognition.

Not written yet, and reported as such by their absence from `Findings` (a sub-stage that asks for them fails by the
missing check's name, never silently): `hover.ocr` (an image of words, which only the pixels hold), and
`hover.permission` and `hover.popover` — with `hover.ax.ownWindowRead`, which moved there because hover reads XDict's
own window through the view's own reading, and only the running app has that.

Writes `Findings` (checks and facts) to <out.json>; every check of the asked sub-stages this driver implements is
reported, passed or failed.
"""
import json
import os
import subprocess
import sys
import time

kit, work, out = sys.argv[1:4]
asked = set(sys.argv[4:])
lab = os.path.join(kit, "XDictCaptureLab.app", "Contents", "MacOS", "XDictCaptureLab")
hands = os.path.join(kit, "anywhere", "hands")

TEXT = "The hôtel stands by the harbour.\nA quiet barge waits for the tide.\n"
WORD = "hôtel"
SENTENCE = "stands by the harbour"
HOSTS = {"textedit": "com.apple.TextEdit", "safari": "com.apple.Safari"}

checks, facts = [], {"word": WORD, "sentence": SENTENCE}


def write_out():
    with open(out + ".tmp", "w") as f:
        json.dump({"checks": checks, "facts": facts}, f, indent=1, sort_keys=True, ensure_ascii=False)
    os.replace(out + ".tmp", out)


def check(name, ok, detail):
    checks.append({"name": name, "pass": bool(ok), "detail": str(detail)[:1500]})
    print(f"{'PASS' if ok else 'FAIL'}  {name}: {str(detail)[:300]}", flush=True)
    write_out()


def run(*args, timeout=120):
    try:
        done = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout)
        return done.returncode, done.stdout.strip(), done.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", f"no answer in {timeout} s"


def last_json(status, stdout, stderr):
    if status != 0:
        return {"error": stderr or f"exit {status}"}
    try:
        return json.loads(stdout.splitlines()[-1])
    except (ValueError, IndexError):
        return {"error": f"no JSON: {stdout[:200]}"}


def lab_answer(arguments, timeout=90):
    """The lab's report, or its refusal in one line — the lab prints one line either way."""
    return last_json(*run(lab, *arguments, timeout=timeout))


def hands_answer(*arguments, timeout=60):
    return last_json(*run(hands, *arguments, timeout=timeout))


def access():
    return lab_answer(["--access"])


# ---------------------------------------------------------------------------------------------------------------------
# The fixture windows: TextEdit's document and a Safari page with the same two lines, the word in the first.

def open_hosts():
    hosts = os.path.join(work, "hosts")
    os.makedirs(hosts, exist_ok=True)
    text_file = os.path.join(hosts, "hover.txt")
    html_file = os.path.join(hosts, "hover.html")
    with open(text_file, "w") as f:
        f.write(TEXT)
    body = "".join(f"<p>{line}</p>" for line in TEXT.strip().split("\n"))
    with open(html_file, "w") as f:
        f.write("<!doctype html><meta charset=utf-8><title>XDict hover</title>"
                f"<body style='font-size:22px'>{body}")
    running = {"textedit": run("open", "-a", "TextEdit", text_file)[0] == 0,
               "safari": run("open", "-a", "Safari", html_file)[0] == 0}
    time.sleep(6)   # two apps launching trade the front until they settle
    facts["hostsOpened"] = running
    return running


def close_hosts(running):
    for host in ("textedit", "safari"):
        if running.get(host) and hands_answer("activate", HOSTS[host]).get("front"):
            hands_answer("press", "cmd+w")
            time.sleep(0.3)


def selected_box(host):
    """The word's box in the host, through Accessibility — the point the lab is asked about."""
    answer = hands_answer("select", HOSTS[host], WORD)
    return (answer.get("box"), answer) if "error" not in answer else (None, answer)


def centre(box):
    return box["x"] + box["width"] / 2, box["y"] + box["height"] / 2


def read_at(point):
    return lab_answer(["--read-point", f"{point[0]:.1f}", f"{point[1]:.1f}"])


# ---------------------------------------------------------------------------------------------------------------------
# hover.accessibility

def accessibility():
    grant = access()
    check("hover.access", grant.get("accessibility") is True,
          f"XDictCaptureLab Accessibility {grant.get('accessibility')}, Screen Recording "
          f"{grant.get('screenRecording')}; {grant.get('error', '')}".strip())
    running = open_hosts()
    read = {}
    for host in ("textedit", "safari"):
        if not running.get(host):
            check(f"hover.ax.{host}", False, f"{HOSTS[host]} did not open")
            continue
        box, raw = selected_box(host)
        if not box:
            check(f"hover.ax.{host}", False, f"no Accessibility box for {WORD!r} in {host}: {raw}")
            continue
        point = centre(box)
        report = read_at(point)
        term = report.get("term") or ""
        acquisition = report.get("acquisition") or ""
        right = term.lower() == WORD.lower() and acquisition not in ("", "recognition")
        check(f"hover.ax.{host}", right,
              f"term {term!r} by {acquisition or 'nothing'} at ({point[0]:.0f}, {point[1]:.0f}), Accessibility's box "
              f"{box}; {report.get('error', '')}".strip())
        read[host] = (box, report, term, acquisition)
    facts["ax"] = {host: {"box": box, "term": term, "acquisition": acquisition}
                   for host, (box, _, term, acquisition) in read.items()}
    # **The box the lab measures is the box Accessibility gave** — not a click placement and not some other word's.
    box, report, _, _ = read.get("textedit", (None, {}, "", ""))
    measured = report.get("bounds")
    near = measured is not None and abs(measured.get("x", 1e9) - box["x"]) <= 6 \
        and abs(measured.get("width", 0) - box["width"]) <= 10
    check("hover.ax.boxMeasured", near, f"the lab measured {measured}; Accessibility's box is {box}")
    sentence = (report.get("context") or {}).get("sentence") or ""
    check("hover.ax.sentence", SENTENCE in sentence, f"the sentence around the word was {sentence!r}")
    close_hosts(running)


# ---------------------------------------------------------------------------------------------------------------------
# hover.exclusions

def exclusions():
    run("open", "-a", "Passwords")
    time.sleep(5)
    frame = hands_answer("window", "com.apple.Passwords").get("frame")
    if not frame:
        check("hover.exclusions.passwords", False, "Passwords showed no window to point at")
        check("hover.exclusions.noPixels", False, "nothing was asked of the lab")
        return
    point = (frame["x"] + frame["width"] / 2, frame["y"] + frame["height"] / 2)
    answer = read_at(point)
    said = answer.get("error") or ""
    quiet = "excludedApp" in said
    check("hover.exclusions.passwords", quiet, f"at ({point[0]:.0f}, {point[1]:.0f}) the lab said {said!r}")
    # No pixels were read: the refusal is the policy's own, decided before any capture.
    check("hover.exclusions.noPixels", quiet, f"the refusal names the exclusion, not a capture: {said!r}")
    hands_answer("activate", "com.apple.Passwords")
    hands_answer("press", "cmd+q")
    facts["excludedApp"] = said


# ---------------------------------------------------------------------------------------------------------------------

def main():
    if not os.path.exists(lab):
        print("drive: the kit holds no XDictCaptureLab.app", flush=True)
        return 1
    write_out()
    if "hover.accessibility" in asked:
        accessibility()
    if "hover.exclusions" in asked:
        exclusions()
    return 0


if __name__ == "__main__":
    sys.exit(main())
