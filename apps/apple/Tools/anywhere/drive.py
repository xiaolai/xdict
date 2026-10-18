#!/usr/bin/env python3
"""Lookup from anywhere, driven as a reader drives it (plan-macos-v1 WI-8), for the E2E `anywhere` sub-stages: real
selections in TextEdit, Notes, Safari and Chrome, real keys, clicks, scrolls and context menus (`hands`, posted into the
HID stream and read through the Accessibility API), against the real app started with `--anywhere`, which says what it
did (`<work>/events.jsonl`) and what it holds (its command directory, `Sources/XDict/AnywhereReport.swift`).

    python3 -I drive.py <kit> <work> <app> <fixtures/lookup> <out.json> <sub-stage>...

**Fresh app state, not a fresh account**: XDict's preferences are deleted and the pasteboard server's Services cache is
flushed and rebuilt for this bundle before the first launch; the user account, its other apps and System Settings are
left as they are, and nothing here touches System Settings. Each host app's result for the Service is recorded: in the
selection's context menu itself, under its Services item, or absent.

Writes `Findings` (checks and facts) to <out.json>; every check the asked sub-stages own is reported, passed or failed.
"""
import json
import os
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import front  # noqa: E402
import hostcondition  # noqa: E402
import selection  # noqa: E402

kit, work, app, fixtures, out = sys.argv[1:6]
asked = set(sys.argv[6:])
hands = os.path.join(kit, "anywhere", "hands")
keys = os.path.join(kit, "lookup", "keys")
commands = os.path.join(work, "commands")
exe = os.path.join(app, "Contents", "MacOS", "XDict")
SERVICE = "Look Up in XDict"
DEFAULT, REBOUND, HELD = "ctrl+opt+d", "ctrl+opt+l", "ctrl+opt+k"
# Carbon: controlKey 4096 | optionKey 2048; kVK_ANSI_D 2, L 37, K 40.
CODES = {DEFAULT: (2, 6144), REBOUND: (37, 6144), HELD: (40, 6144)}
DEADLINE = 1.0
BASELINE = 0.13  # XiaolaiDict's measured panel time: recorded beside each measurement, never the gate
TEXT = "The abbé took off at noon. abbé\nhop2 and hop3 are tall.\ncrème brûlée 煎饼\n"
HOSTS = {"textedit": "com.apple.TextEdit", "notes": "com.apple.Notes", "safari": "com.apple.Safari",
         "chrome": "com.google.Chrome"}

checks, facts = [], {"freshState": "fresh app state, not fresh account", "baselineSeconds": BASELINE,
                     "deadlineSeconds": DEADLINE, "panelSeconds": {}, "service": {}}
sequence = 0
pid = None


def write_out():
    with open(out + ".tmp", "w") as f:
        json.dump({"checks": checks, "facts": facts}, f, indent=1, sort_keys=True, ensure_ascii=False)
    os.replace(out + ".tmp", out)


def check(name, ok, detail):
    checks.append({"name": name, "pass": bool(ok), "detail": str(detail)[:1500]})
    print(f"{'PASS' if ok else 'FAIL'}  {name}: {str(detail)[:300]}", flush=True)
    write_out()


def run(*args, timeout=60):
    done = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    return done.returncode, done.stdout.strip(), done.stderr.strip()


def answer_of(status, stdout, stderr):
    if status != 0:
        return {"error": stderr or f"exit {status}"}
    try:
        return json.loads(stdout.splitlines()[-1])
    except (ValueError, IndexError):
        return {"error": f"no JSON: {stdout[:200]}"}


def front_now():
    try:
        return answer_of(*run(hands, "front", timeout=10))
    except subprocess.TimeoutExpired:
        return {"name": "unknown (hands front timed out)"}


def xctests():
    try:
        return run("pgrep", "-fl", "xctest", timeout=10)[1].splitlines()
    except subprocess.TimeoutExpired:
        return []


def tool(*args, timeout=60):
    """A `hands` action, with the front held to account (`front.guarded`): a timeout or a host that would not come
    forward stops the driver naming who has the front."""
    what = "hands " + " ".join(str(a) for a in args[:2])
    return front.guarded(what, lambda: answer_of(*run(hands, *args, timeout=timeout)),
                         front=front_now, processes=xctests)


def ask(op, wait=20, **extra):
    global sequence
    sequence += 1
    path = os.path.join(commands, f"{sequence:03d}.json")
    with open(path + ".tmp", "w") as f:
        json.dump({"op": op, **extra}, f)
    os.replace(path + ".tmp", path)
    answer = os.path.join(commands, f"{sequence:03d}.out.json")
    for _ in range(int(wait * 20)):
        if os.path.exists(answer):
            try:
                return json.load(open(answer))
            except ValueError:
                pass
        time.sleep(0.05)
    return {"error": f"the app did not answer {op}"}


def events():
    try:
        return [json.loads(line) for line in open(os.path.join(work, "events.jsonl")) if line.strip()]
    except (OSError, ValueError):
        return []


def wait_for(condition, seconds=5.0):
    end = time.time() + seconds
    while time.time() < end:
        value = condition()
        if value:
            return value
        time.sleep(0.05)
    return None


def panel_state():
    state = ask("state")
    return state.get("panel", {}), state.get("panelModel", {}), state


def close_panel():
    tool("press", "escape")
    wait_for(lambda: not panel_state()[0].get("shown"), 3)


# ---------------------------------------------------------------------------------------------------------------------
# Fresh app state and the launch

def quit_app():
    run("pkill", "-x", "-f", exe)
    wait_for(lambda: run("pgrep", "-f", exe)[0] != 0, 5)


def launch():
    global pid, sequence
    # A relaunched app would answer every command still in the directory — the last launch's `quit` among them.
    for name in os.listdir(commands) if os.path.isdir(commands) else []:
        try:
            os.remove(os.path.join(commands, name))
        except OSError:
            pass
    status, _, stderr = run("open", "-n", "--stdout", os.path.join(work, "app.out"), "--stderr",
                            os.path.join(work, "app.err"), app, "--args", "-ApplePersistenceIgnoreState", "YES",
                            "--anywhere", work, "--fixtures", fixtures)
    if status != 0:
        return {"error": f"open: {stderr}"}
    ready = wait_for(lambda: json.load(open(os.path.join(commands, "ready.json")))
                     if os.path.exists(os.path.join(commands, "ready.json")) else None, 180)
    if not ready:
        return {"error": "the app never said it was ready"}
    pid = ready.get("pid")
    return ready


def fresh_state():
    quit_app()
    run("defaults", "delete", "ai.xdict.app")
    run("/System/Library/CoreServices/pbs", "-flush")
    run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
        "-f", app)
    run("/System/Library/CoreServices/pbs", "-update")


# ---------------------------------------------------------------------------------------------------------------------
# The host apps' documents: TextEdit and the browsers open a file of this run's; Notes gets a note typed into it.

def open_hosts():
    os.makedirs(os.path.join(work, "hosts"), exist_ok=True)
    text_file = os.path.join(work, "hosts", "anywhere.txt")
    html_file = os.path.join(work, "hosts", "anywhere.html")
    with open(text_file, "w") as f:
        f.write(TEXT)
    with open(html_file, "w") as f:
        body = "".join(f"<p>{line}</p>" for line in TEXT.strip().split("\n"))
        f.write(f"<!doctype html><meta charset=utf-8><title>XDict anywhere</title><body style='font-size:20px'>{body}")
    opened = {}
    opened["textedit"] = run("open", "-a", "TextEdit", text_file)[0] == 0
    opened["safari"] = run("open", "-a", "Safari", html_file)[0] == 0
    opened["chrome"] = run("open", "-a", "Google Chrome", html_file)[0] == 0
    run("open", "-a", "Notes")
    time.sleep(6)  # four apps launching trade the front until they settle
    opened["notes"] = False
    if tool("activate", HOSTS["notes"]).get("front"):
        tool("press", "cmd+n")
        time.sleep(1.0)
        run(keys, "type", TEXT.replace("\n", " "), timeout=120)
        time.sleep(0.5)
        opened["notes"] = True
    facts["hostsOpened"] = opened
    return opened


def close_hosts(opened):
    if opened.get("notes") and tool("activate", HOSTS["notes"]).get("front"):
        tool("press", "cmd+delete")  # the note this run typed, to Recently Deleted
        time.sleep(0.5)
    for host in ("textedit", "safari", "chrome"):
        if opened.get(host) and tool("activate", HOSTS[host]).get("front"):
            tool("press", "cmd+w")
            time.sleep(0.3)


def not_selected(host, raw, what):
    """A failed selection's detail: the host's own condition when it is one, else what XDict's check could not do."""
    said = hostcondition.of(host, raw)
    return hostcondition.detail(host, said) if said else f"could not select {what} in {host}: {raw}"


def select(host, needle):
    answer = tool("select", HOSTS[host], needle)
    if "error" in answer:
        return None, answer
    # Anything but the needle itself is a failed selection with its own reason, never handed on as the needle.
    wrong = selection.refused(needle, answer)
    return (None, {"error": wrong, "box": answer.get("box")}) if wrong else (answer, answer)


def shortcut_panel(combo=DEFAULT):
    """The shortcut pressed, and the seconds until XDict's panel was on screen, measured from outside the app."""
    answer = tool("panel", pid, combo, 3)
    return answer.get("seconds"), answer


def near(word, frame):
    """Whether the panel (AppKit, y up) sits by the word (Accessibility, y down): not over it, its edge within 12 pt."""
    if not word or not frame:
        return False, "no box"
    height = facts.get("screenHeight") or 0
    top, bottom = height - (frame["y"] + frame["height"]), height - frame["y"]
    overlaps = not (bottom <= word["y"] or top >= word["y"] + word["height"])
    gap = min(abs(top - (word["y"] + word["height"])), abs(word["y"] - bottom))
    return (not overlaps and gap <= 12), f"panel y-down {top:.0f}–{bottom:.0f}, word {word['y']:.0f}+{word['height']:.0f}"


# ---------------------------------------------------------------------------------------------------------------------

def selection_hosts():
    for host in ("textedit", "safari", "notes"):
        name = f"selection.{host}"
        selected, raw = select(host, "abbé")
        if not selected:
            check(name, False, not_selected(host, raw, "the word"))
            continue
        seconds, measured = shortcut_panel()
        shown = wait_for(lambda: (lambda p, m, _: p.get("shown") and m.get("query") == "abbé" and (p, m))(*panel_state()), 5)
        facts["panelSeconds"][host] = seconds
        placed, where = near(selected.get("box"), shown[0].get("frame") if shown else None)
        check(name, bool(shown) and placed,
              f"{host}: selected {selected.get('selected')!r} ({selected.get('dialect')}); panel in {seconds} s; "
              f"query {shown[1].get('query') if shown else panel_state()}; by the selection: {where}")
        close_panel()


def services_menu():
    phrase = "crème brûlée 煎饼"
    delivered_all = True
    for host in ("textedit", "notes", "safari", "chrome"):
        name = f"services.{host}"
        selected, raw = select(host, phrase)
        if not selected or not selected.get("box"):
            facts["service"][host] = "not measured"
            check(name, False, not_selected(host, raw, "the phrase"))
            delivered_all = False
            continue
        box = selected["box"]
        before = len(events())
        answer = tool("context", HOSTS[host], box["x"] + box["width"] / 2, box["y"] + box["height"] / 2, SERVICE,
                      "choose")
        placed = answer.get("placed", "absent")
        facts["service"][host] = placed
        service = wait_for(lambda: [e for e in events()[before:] if e.get("event") == "service"], 5)
        shown = wait_for(lambda: (lambda p, m, _: p.get("shown") and m.get("query") and (p, m))(*panel_state()), 5)
        text = service[0].get("text") if service else None
        query = shown[1].get("query") if shown else None
        delivered = query == phrase
        delivered_all = delivered_all and delivered
        by_click, where = near(box, shown[0].get("frame") if shown else None)
        check(name, placed != "absent" and delivered and by_click,
              f"{host}: “{SERVICE}” {placed} (menu: {answer.get('items', [])[-6:]}; services: {answer.get('services')}); "
              f"handed {text!r}; panel query {query!r}; by the selection: {by_click} ({where}); selected {selected}")
        close_panel()
    check("services.unicodeDelivered", delivered_all,
          f"“{phrase}” delivered verbatim to the panel from every host: {delivered_all} ({facts['service']})")


def scroll_panel():
    frame = panel_state()[0].get("frame")
    if not frame:
        return None
    height = facts.get("screenHeight") or 0
    tool("scroll", frame["x"] + frame["width"] / 2, height - (frame["y"] + frame["height"] / 2), -12)
    return wait_for(lambda: (panel_state()[1].get("scroll") or 0) > 20 and panel_state()[1], 5)


def expansion(name, word, by):
    selected, raw = select("textedit", word)
    if not selected:
        check(name, False, f"could not select {word}: {raw}")
        return
    shortcut_panel()
    model = wait_for(lambda: (lambda p, m, _: p.get("shown") and m.get("key") == word and m)(*panel_state()), 8)
    scrolled = scroll_panel() if model else None
    if not scrolled:
        check(name, False, f"the panel for {word} never showed it scrolled: {panel_state()[1]}")
        close_panel()
        return
    if by == "pointer":
        button = tool("element", pid, "panel.expand").get("frame")
        if not button:
            check(name, False, "no Open in XDict button in the panel")
            close_panel()
            return
        tool("click", button["x"] + button["width"] / 2, button["y"] + button["height"] / 2)
    else:
        tool("press", DEFAULT)  # the shortcut again, the selection unchanged: the panel's keyboard route
    main = wait_for(lambda: (lambda s: s.get("main", {}).get("key") == word and s.get("main", {}).get("visible")
                             and s)(ask("state")), 8)
    if not main:
        check(name, False, f"the main window never showed {word}: {ask('state')}")
        return
    time.sleep(0.8)  # the entry lands at its offset once WebKit has laid it out
    main = ask("state")
    m = main.get("main", {})
    same = (m.get("query") == scrolled.get("query") and m.get("dictionary") == scrolled.get("dictionary")
            and abs((m.get("scroll") or 0) - (scrolled.get("scroll") or 0)) <= 2)
    check(name, same and not main["panel"]["shown"],
          f"by {by}: panel {scrolled.get('query')}/{scrolled.get('dictionary')}/{scrolled.get('key')} at "
          f"{scrolled.get('scroll')} → main {m.get('query')}/{m.get('dictionary')}/{m.get('key')} at {m.get('scroll')}; "
          f"panel closed: {not main['panel']['shown']}")


def next_key_lands(name, dismiss):
    selected, raw = select("textedit", "abbé")
    if not selected:
        check(name, False, f"could not select: {raw}")
        return
    shortcut_panel()
    if not wait_for(lambda: panel_state()[0].get("shown"), 5):
        check(name, False, "no panel")
        return
    dismiss(selected)
    gone = wait_for(lambda: not panel_state()[0].get("shown"), 3)
    front = tool("front")
    before = tool("value", HOSTS["textedit"]).get("value") or ""
    tool("press", "q")
    time.sleep(0.4)
    after = tool("value", HOSTS["textedit"]).get("value") or ""
    landed = after != before and "q" in after
    tool("press", "cmd+z")
    time.sleep(0.3)
    check(name, bool(gone) and front.get("bundle") == HOSTS["textedit"] and landed,
          f"panel gone {bool(gone)}; front {front.get('bundle')}; the next key reached TextEdit: {landed}")


def deadline():
    times = {k: v for k, v in facts["panelSeconds"].items() if v is not None}
    selected, raw = select("textedit", "abbé")
    if selected:
        seconds, _ = shortcut_panel()
        times["textedit.again"] = seconds
        close_panel()
    ok = bool(times) and all(v is not None and v <= DEADLINE for v in times.values())
    check("panel.deadline.appears", ok, f"from the key to the panel on screen: {times} s; gate {DEADLINE} s; "
                                        f"XiaolaiDict's baseline {BASELINE} s, for comparison")
    # The dictionary service hung: the panel still comes, saying it is looking up, within the deadline.
    status, found, _ = run("pgrep", "-f", "XDictService")
    services = [int(p) for p in found.split()] if status == 0 else []
    if not services:
        check("panel.deadline.serviceHung", False, "no dictionary service to suspend: the test did not happen")
        return
    selected, raw = select("textedit", "hop3")
    try:
        for p in services:
            os.kill(p, signal.SIGSTOP)
        seconds, measured = shortcut_panel()
        shown = wait_for(lambda: panel_state()[0].get("shown"), 2)
    finally:
        for p in services:
            os.kill(p, signal.SIGCONT)
    facts["panelSeconds"]["serviceHung"] = seconds
    check("panel.deadline.serviceHung", seconds is not None and seconds <= DEADLINE and bool(shown),
          f"service {services} stopped: the panel in {seconds} s ({measured}); gate {DEADLINE} s")
    close_panel()


def menubar():
    item = tool("menubar", pid)
    items = item.get("items", [])
    check("menubar.present", item.get("item") and any(t.startswith("Look Up Selection") for t in items)
          and "Open XDict" in items and "Quit XDict" in items, f"{item}")
    selected, raw = select("textedit", "abbé")
    before = len(events())
    chosen = tool("menubar", pid, "Look Up Selection")
    shown = wait_for(lambda: (lambda p, m, _: p.get("shown") and m.get("query") == "abbé" and m)(*panel_state()), 5)
    check("menubar.looksUp", chosen.get("chosen") and bool(shown),
          f"chosen {chosen.get('chosen')}; events {[e.get('event') for e in events()[before:]]}; panel {panel_state()[1]}")
    close_panel()


def shortcut():
    code, mods = CODES[REBOUND]
    said = ask("rebind", keyCode=code, modifiers=mods)
    ask("quit", wait=3)
    quit_app()
    ready = launch()
    state = ask("state")
    persisted = state.get("shortcut", {})
    select("textedit", "abbé")
    new_seconds, _ = shortcut_panel(REBOUND)
    close_panel()
    select("textedit", "abbé")
    old_seconds, _ = shortcut_panel(DEFAULT)
    close_panel()
    check("shortcut.rebindPersists", said.get("problem") is None and persisted.get("label") == "⌃⌥L"
          and persisted.get("registered") and new_seconds is not None and old_seconds is None,
          f"rebound: {said}; after a relaunch {persisted}; ⌃⌥L opened the panel in {new_seconds} s; ⌃⌥D: {old_seconds}"
          f"; ready {ready.get('settled')}")
    # A clash: another process holds ⌃⌥K; choosing it is refused, said so, and ⌃⌥L still answers.
    holder = subprocess.Popen([hands, "hold", HELD, "40"], stdout=subprocess.PIPE, text=True)
    held = holder.stdout.readline().strip()
    code, mods = CODES[HELD]
    clash = ask("rebind", keyCode=code, modifiers=mods)
    after = ask("state").get("shortcut", {})
    select("textedit", "abbé")
    kept_seconds, _ = shortcut_panel(REBOUND)
    close_panel()
    holder.terminate()
    check("shortcut.clashRestores", "takenByAnotherApp" in str(clash.get("problem")) and "⌃⌥L" in str(clash.get("sentence"))
          and after.get("label") == "⌃⌥L" and after.get("registered") and kept_seconds is not None,
          f"holder {held}; refused: {clash}; now {after}; ⌃⌥L still opens the panel in {kept_seconds} s")
    code, mods = CODES[DEFAULT]
    back = ask("rebind", keyCode=code, modifiers=mods)
    facts["shortcutRestored"] = back


def main():
    access = tool("access") if os.path.exists(hands) else {"error": "no hands"}
    if not (access.get("accessibility") and access.get("postEvents")):
        check("anywhere.access", False, f"this SSH session may not post events or read windows ({access}): grant "
                                        "Accessibility to sshd-keygen-wrapper on the E2E Mac; nothing was driven")
        return
    check("anywhere.access", True, f"this session may post events and read windows ({access})")
    fresh_state()
    os.makedirs(commands, exist_ok=True)
    ready = launch()
    ready_ok = ready.get("settled") and ready.get("trusted") and set(ready.get("dictionaries", [])) >= {"Alpha", "Beta"}
    check("anywhere.setup", ready_ok, f"{ready}" + ("" if ready.get("trusted") else
          " — XDict.app itself is not trusted for Accessibility on the E2E Mac: grant it once in System Settings › "
          "Privacy & Security › Accessibility (the selection is XDict's to read)"))
    if not ready_ok:
        return
    state = ask("state")
    facts["screenHeight"] = state.get("screenHeight") or 0
    opened = open_hosts()
    try:
        if "selection.hosts" in asked:
            selection_hosts()
        if "services.menu" in asked:
            services_menu()
        if "panel.expand" in asked:
            expansion("panel.expand.pointer", "hop2", "pointer")
            expansion("panel.expand.keyboard", "hop3", "keyboard")
        if "panel.dismiss" in asked:
            next_key_lands("panel.escape.nextKeyLands", lambda s: tool("press", "escape"))
            next_key_lands("panel.clickAway.nextKeyLands",
                           lambda s: tool("click", s["box"]["x"] + s["box"]["width"] / 2,
                                          s["box"]["y"] + s["box"]["height"] / 2))
        if "panel.deadline" in asked:
            deadline()
        if "menubar.item" in asked:
            menubar()
        if "shortcut.rebind" in asked:
            shortcut()
    finally:
        close_hosts(opened)
        ask("quit", wait=3)
        quit_app()
        write_out()


if __name__ == "__main__":
    try:
        main()
    except front.Stopped as stopped:
        write_out()
        raise SystemExit(f"drive: {stopped}") from None
    finally:
        write_out()
