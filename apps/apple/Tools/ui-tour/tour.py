#!/usr/bin/env python3
"""The UI tour (owner's request, 2026-10-17): every route of `routes.py` walked on the real app, each state captured for
review. Runs on the E2E Mac, started by `run.sh` from the Air; not an E2E stage, and writes nothing to the E2E ledger.

    python3 -I tour.py <e2e-home> <out> [--only id,id] [--variants light-en,light-zh,light-pseudo] [--reader]

The app is the installed bundle, started with `--lookup-window <work>`: the production main window, menus and Settings
over **a library of its own** (`<work>/store`, the lookup fixtures, or none), its dictionary service its own. The
instrument's scenario is never asked to run, so the window is the reader's. XDict's own preferences (`ai.xdict.app`)
are exported first, deleted before each launch (a fresh reader's state) and imported back at the end, whatever happens.

Per variant and route: `<out>/<variant>/<route>.png` (the window the route is about; more windows as `.2.png` ...),
`<route>.ax.json` (every window's accessibility tree and what `checks()` found in it) and a line in
`<out>/results.json`. Appearance is XDict's alone, by the instrument's `--appearance dark|light` (which sets
`NSApp.appearance`; refused in a reader's launch); language is XDict's alone (`-AppleLanguages`). Nothing of the Mac's
own settings is changed. The `pseudo` language (`light-pseudo`, not in the default variants) is English made ~40% longer
and accented (`pseudo.py`), compiled into a copy of the installed app beside it (`XDict-pseudo/XDict.app`) and never
into XDict.app: what clips in a longer language shows. **Each route has a launch of its own** (2026-10-17): scope, the find bar, zoom, the last
entry and open windows never leak from one route into the next (the review's "leftovers").
"""
import json
import os
import plistlib
import signal
import shutil
import subprocess
import sys
import tempfile
import time

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
import aim  # noqa: E402
import demo
import visibility  # noqa: E402
from ledger_sandbox import RegistrySandbox, stop_owned_service  # noqa: E402
from axcheck import checks, dictionaries_table  # noqa: E402
import parity  # noqa: E402
from pseudo import pseudo  # noqa: E402
from routes import NOT_DRIVEN_WHY, ROUTES, defaults_commands, not_in_appearance, prefs  # noqa: E402

home, out = sys.argv[1:3]
options = dict(zip([a for a in sys.argv[3:] if a != "--reader"][0::2], [a for a in sys.argv[3:] if a != "--reader"][1::2]))
only = set(filter(None, options.get("--only", "").split(",")))
LABEL = options.get("--label", "")
VARIANTS = options.get("--variants", "light-en,light-zh,dark-en,dark-zh").split(",")
app = os.path.join(home, "XDict.app")
exe = os.path.join(app, "Contents", "MacOS", "XDict")
kit = os.path.join(home, "kit")
keys = os.path.join(kit, "lookup", "keys")
pointer = os.path.join(kit, "pointer")
dragsource = os.path.join(kit, "dragsource")
fixtures = os.path.join(home, "fixtures")
ax_tool = os.path.join(out, ".bin", "ax")
DOMAIN = "ai.xdict.app"
DEADLINE = 6.0
LEDGER_SANDBOX = None

zh = {}
strings = os.path.join(app, "Contents", "Resources", "zh-Hans.lproj", "Localizable.strings")
if os.path.exists(strings):
    with open(strings, "rb") as f:
        zh = plistlib.load(f)


class Failed(Exception):
    pass


def run(*args, check=True, wait=60):
    done = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=wait)
    if check and done.returncode != 0:
        raise Failed(f"{os.path.basename(str(args[0]))} {' '.join(map(str, args[1:]))}: "
                     f"{(done.stderr or done.stdout).strip()[:300]}")
    return done


def as_json(done):
    try:
        return json.loads(done.stdout)
    except ValueError:
        return {}


def matching(executable=exe):
    """The processes whose command line holds `executable` — empty when the bundle is not running."""
    found = subprocess.run(["pgrep", "-f", executable], capture_output=True, text=True).stdout.split()
    return found


def running(executable=exe):
    return bool(matching(executable))


def translated(title, lang):
    # Only a catalog key is translated; an identifier or a menu index ("#0") is matched as written.
    if lang == "pseudo":
        keys = zh_keys()
        base = title if title in keys else title.rstrip("…")
        return f"{pseudo(base)}|{title}" if base in keys else title
    return f"{zh[title]}|{title}" if lang == "zh" and title in zh else title


def zh_keys():
    """The catalog's keys (the kit's copy), which the pseudo language translates."""
    with open(os.path.join(here, "Localizable.xcstrings"), encoding="utf-8") as f:
        return json.load(f)["strings"].keys()


PSEUDO_APP = os.path.join(home, "XDict-pseudo", "XDict.app")


def pseudo_app():
    """A copy of the installed app whose English is the pseudo language, made once per tour from the catalog the kit
    carries (`run.sh` copies Strings/Localizable.xcstrings beside this file). The copy only: XDict.app is never changed.
    Its signature no longer seals its resources, which a local launch does not check; the executables are untouched."""
    catalog = os.path.join(here, "Localizable.xcstrings")
    if not os.path.exists(catalog):
        raise SystemExit("tour: the kit carries no Localizable.xcstrings; run.sh copies it")
    shutil.rmtree(os.path.dirname(PSEUDO_APP), ignore_errors=True)
    os.makedirs(os.path.dirname(PSEUDO_APP))
    run("ditto", app, PSEUDO_APP)
    scratch = tempfile.mkdtemp(prefix="xdict-pseudo-")
    try:
        source = os.path.join(scratch, "Localizable.xcstrings")
        run("/usr/bin/python3", "-I", os.path.join(here, "pseudo.py"), catalog, source)
        run("xcrun", "xcstringstool", "compile", source, "--output-directory", scratch)
        english = os.path.join(PSEUDO_APP, "Contents", "Resources", "en.lproj")
        for table in ("Localizable.strings", "Localizable.stringsdict"):
            built = os.path.join(scratch, "en.lproj", table)
            if not os.path.exists(built):
                raise SystemExit(f"tour: the pseudo catalog compiled no {table}")
            shutil.copyfile(built, os.path.join(english, table))
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


class Session:
    """One launch of the app over its own library; asked through `<work>/commands` (LookupWindow.swift)."""

    def __init__(self, variant, library, preferences=()):
        if LEDGER_SANDBOX is not None:
            LEDGER_SANDBOX.reset()
        self.variant, self.library = variant, library
        self.appearance, self.lang = variant.split("-")
        self.app = PSEUDO_APP if self.lang == "pseudo" else app
        self.exe = os.path.join(self.app, "Contents", "MacOS", "XDict")
        self.work = tempfile.mkdtemp(prefix="xdict-tour-")
        self.commands = os.path.join(self.work, "commands")
        self.sequence = 0
        source = os.path.join(fixtures, "lookup")
        if library == "empty":
            source = os.path.join(self.work, "nothing")
            os.makedirs(source)
        run("defaults", "delete", DOMAIN, check=False)
        # The route's own preferences (`("pref", key, value)`, routes.prefs), stored as a reader's choice would be.
        for argv in defaults_commands(DOMAIN, preferences):
            run(*argv)
        args = ["-ApplePersistenceIgnoreState", "YES", "--lookup-window", self.work, "--fixtures", source]
        # `-AppleInterfaceStyle` does not reach AppKit for one app on macOS 27, and the Mac's own appearance is never
        # changed for a tour: the instrument sets XDict's (`--appearance`, XDictUI's InstrumentAppearance).
        if self.appearance not in ("light", "dark"):
            raise Failed(f"no appearance {self.appearance!r}: light or dark")
        args += ["--appearance", self.appearance]
        if self.lang == "zh":
            args += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        elif self.lang == "pseudo":
            args += ["-AppleLanguages", "(en)"]
        elif self.lang != "en":
            raise Failed(f"no language {self.lang!r}: en, zh or pseudo")
        run("open", "-n", "--stdout", os.path.join(self.work, "app.out"), "--stderr",
            os.path.join(self.work, "app.err"), self.app, "--args", *args)
        ready = os.path.join(self.commands, "ready.json")
        for _ in range(900):
            if os.path.exists(ready):
                break
            time.sleep(0.1)
        else:
            raise Failed(f"the app never became ready ({self.stderr()})")
        time.sleep(0.3)
        self.ready = json.load(open(ready))
        self.pid = self.ready["pid"]

    def stderr(self):
        try:
            return open(os.path.join(self.work, "app.err")).read()[-300:]
        except OSError:
            return ""

    def ask(self, op, wait=20, fields=None):
        self.sequence += 1
        path = os.path.join(self.commands, f"{self.sequence:03d}.json")
        with open(path + ".tmp", "w") as f:
            json.dump(dict(fields or {}, op=op), f)
        os.replace(path + ".tmp", path)
        answer = os.path.join(self.commands, f"{self.sequence:03d}.out.json")
        for _ in range(int(wait * 20)):
            if os.path.exists(answer):
                try:
                    return json.load(open(answer))
                except ValueError:
                    pass
            time.sleep(0.05)
        raise Failed(f"the app did not answer {op!r}")

    def hold(self, why):
        """The app frontmost before `why`; otherwise the route fails naming who has the front (reader.py's `hold`)."""
        deadline = time.time() + DEADLINE
        while True:
            front = as_json(run(keys, "front", check=False))
            if front.get("pid") == self.pid:
                return
            if front.get("displayAsleep"):
                run("caffeinate", "-u", "-t", "1", check=False)
            # **A user's activation, not a program's** (2026-10-30: XDict has been an accessory app since the menu-bar
            # home, and `NSApp.activate()` from its own instrument is refused while another app holds the front — Apple's
            # rule, not a bug to route around inside the app). The Apple Event is the same activation a click gives it.
            run("osascript", "-e", 'tell application id "ai.xdict.app" to activate', check=False)
            if time.time() > deadline:
                raise Failed(f"before {why!r} XDict could not have the front: {front.get('name')!r} "
                             f"(pid {front.get('pid')}) holds it")
            self.ask("front")
            time.sleep(0.3)

    def ax(self, *args):
        return as_json(run(ax_tool, args[0], self.pid, *args[1:]))

    def step(self, step):
        kind = step[0]
        if kind == "wait":
            time.sleep(step[1])
            return
        if kind != "extra":
            self.hold(" ".join(map(str, step)))
        if kind == "key":
            run(ax_tool, "key", step[1])
            time.sleep(0.4)
        elif kind == "type":
            run(keys, "press", "cmd+a")
            run(keys, "type", step[1])
            time.sleep(0.6)
        elif kind == "menu":
            self.ax("menu", step[1], *[translated(t, self.lang) for t in step[2:]])
            time.sleep(1.0)
        elif kind == "menuopen":
            self.ax("menu", step[1])
            time.sleep(0.8)
        elif kind in ("press", "click"):
            names = [n for t in step[1:] for n in translated(t, self.lang).split("|")]
            self.ax(kind, *dict.fromkeys(names))
            time.sleep(0.5)
        elif kind == "visible":
            deadline = time.monotonic() + 5
            while not visibility.visible(self.ax("tree"), step[1], step[2] if len(step) > 2 else None):
                if time.monotonic() >= deadline:
                    raise Failed("requested control is not visible: " + step[1])
                time.sleep(0.1)
        elif kind == "fills":
            if not visibility.fills_container(self.ax("tree"), step[1]):
                raise Failed("pane does not fill its native column: " + step[1])
        elif kind == "windowSize":
            windows = self.ax("tree").get("windows", [])
            main = next((w for w in windows if w.get("identifier", "").startswith("main-")), None)
            frame = main.get("frame") if main else None
            if not frame or abs(frame[2] - step[1]) > 1 or abs(frame[3] - step[2]) > 1:
                raise Failed("main window changed size: " + str(frame) + "; expected " + str(step[1:]))
        elif kind == "size":
            self.ax("size", step[1], step[2])
            time.sleep(0.6)
        elif kind == "extra":
            # A primary click on the menu-bar item: the reading history.
            self.ax("extra")
            time.sleep(0.8)
        elif kind == "extraMenu":
            # A real secondary click on it: only an owned status item can route that (plan-history-and-learning §4).
            self.ax("extraMenu")
            time.sleep(0.8)
        elif kind == "drop":
            self.drop(os.path.join(fixtures, "library", step[1]))
        elif kind == "demo":
            if step[1] == "meaning":
                with demo.answer_server() as endpoint:
                    prepared = self.ask(demo.operation(step[1]), fields={"endpoint": endpoint})
            else:
                prepared = self.ask(demo.operation(step[1]))
            if not prepared.get("prepared"):
                raise Failed("synthetic demonstration could not be prepared: " + str(prepared))
            time.sleep(0.6)
        else:
            raise Failed(f"unknown step {step}")

    def drop(self, file):
        """A file dragged in from another window (Tools/library/dragsource) onto the window in front (Settings ▸
        Dictionaries, ADR-0012)."""
        # The table's own centre (aim.py), not the window's, which the strip or problem box can push off the table.
        try:
            tx, ty = aim.drop_target(self.ax("tree"))
        except aim.NoTarget as missing:
            raise Failed(f"nothing to drop onto: {missing}")
        ready = os.path.join(self.work, "drag.ready")
        source = subprocess.Popen([dragsource, file, "40", "80", ready])
        try:
            for _ in range(100):
                if os.path.exists(ready) and open(ready).read().strip():
                    break
                time.sleep(0.1)
            else:
                raise Failed("the drag source window never came up")
            cx, cy = open(ready).read().split()
            run(pointer, "drag", cx, cy, tx, ty)
            source.wait(timeout=10)
            if source.returncode != 0:
                there = self.ax("at", tx, ty).get("element") or {}
                raise Failed(f"the drag ended without a drop (dragsource exited {source.returncode}); aimed at the "
                             f"table's centre ({tx}, {ty}), where AX has {there.get('role')!r} "
                             f"{there.get('identifier') or there.get('description') or there.get('title')!r}")
        finally:
            if source.poll() is None:
                source.kill()

    def quit(self):
        try:
            self.ask("quit", wait=5)
        except Failed:
            pass
        for _ in range(50):
            if not running(self.exe):
                break
            time.sleep(0.1)
        if running(self.exe):
            run("pkill", "-f", self.exe, check=False)
        shutil.rmtree(self.work, ignore_errors=True)


def relative(tree):
    """Each element's frame also in its window's points (`wframe`, origin the window's top left)."""
    def walk(node, origin):
        if node.get("frame"):
            node["wframe"] = [node["frame"][0] - origin[0], node["frame"][1] - origin[1]] + node["frame"][2:]
        for kid in node.get("children", []):
            walk(kid, origin)

    for window in tree.get("windows", []):
        walk(window, (window.get("frame") or [0, 0])[:2])


def park_pointer(session):
    """The pointer moved off XDict's windows before a capture: a pointer left over a control (the last route's click)
    draws its rollover look, which reads as a second selected scope (P6, 2026-10-18)."""
    frames = [w["frame"] for w in session.ax("windows")["windows"] if w.get("layer") == 0]
    if not frames:
        return
    x, y, w, h = frames[0]
    target = (x - 40, y + h / 2) if x > 60 else (x + w + 40, y + h / 2)
    run(pointer, "move", int(target[0]), int(target[1]), check=False)
    time.sleep(0.4)


def capture(session, route, folder):
    if not any(step and step[0] in ("menu", "menuopen", "extra") for step in getattr(session, "steps", [])):
        park_pointer(session)
    shots = []
    windows = [w for w in session.ax("windows")["windows"]
               if w["alpha"] > 0 and w["frame"][2] > 40 and w["frame"][3] > 20]
    # Menus and panels first (higher layers), then the frontmost normal window; the window list is front to back.
    windows.sort(key=lambda w: -w["layer"])
    for index, window in enumerate(windows[:4]):
        name = f"{route}.png" if index == 0 else f"{route}.{index + 1}.png"
        path = os.path.join(folder, name)
        run("screencapture", "-o", "-x", "-l", window["id"], path)
        run("sips", "-Z", "1600", path, check=False)
        shots.append(name)
    tree = session.ax("tree")
    relative(tree)
    findings = checks(tree)
    if route == "settings.dictionaries":
        findings += [dict(f, parity="P39") for f in dictionaries_table(tree)]
    menubar = session.ax("menubar")
    # The Apple Dictionary parity checks (parity.py) read English titles: English variants only.
    session.parity = parity.checks(route, tree, menubar) if session.lang == "en" else []
    with open(os.path.join(folder, f"{route}.ax.json"), "w") as f:
        json.dump({"windows": session.ax("windows")["windows"], "tree": tree, "menubar": menubar, "findings": findings,
                   "parity": session.parity}, f)
    return shots, findings


def walk(variant, name, library, route, steps, folder):
    """One route over a launch of its own, captured; the app quit after, whatever happened."""
    record = {"variant": name, "route": route}
    try:
        session = Session(variant, library, prefs(steps))
        session.steps = steps
    except Failed as why:
        record["failure"] = f"launch: {why}"
        print(f"{name} {route}: {record['failure']}", flush=True)
        return record
    try:
        try:
            for step in steps:
                if step[0] not in ("after", "pref"):
                    session.step(step)
            record["shots"], record["findings"] = capture(session, route, folder)
            # What the route leaves open is closed after its capture, before the app quits (the print panel's Cancel).
            for step in steps:
                if step[0] == "after":
                    session.step(tuple(step[1:]))
            record["parity"] = getattr(session, "parity", [])
            if not record["shots"]:
                record["failure"] = "no window of XDict on screen"
        except (Failed, subprocess.TimeoutExpired, KeyError) as why:
            record["failure"] = str(why)
            try:
                record["shots"], record["findings"] = capture(session, route, folder)
            except (Failed, subprocess.TimeoutExpired, KeyError):
                pass
        if not running(session.exe):
            record["failure"] = (record.get("failure", "") + " — XDict quit: " + session.stderr()).strip()
    finally:
        # Keep the native exception reason before the isolated session removes its scratch directory.
        error_log = os.path.join(session.work, "app.err")
        if record.get("failure") and os.path.isfile(error_log):
            shutil.copyfile(error_log, os.path.join(folder, f"{route}.stderr.txt"))
        session.quit()
    print(f"{name} {route}: {record.get('failure', 'ok')}", flush=True)
    for check in record.get("parity", []):
        print(f"{name} {route}: parity {check['id']} {'ok' if check['ok'] else 'NOT APPLE: ' + check['why']}",
              flush=True)
    return record


def tour():
    results = []
    if any(v.endswith("-pseudo") for v in VARIANTS):
        pseudo_app()
    for variant in VARIANTS:
        name = f"{variant}-{LABEL}" if LABEL else variant
        folder = os.path.join(out, name)
        os.makedirs(folder, exist_ok=True)
        for library in ("full", "empty"):
            routes = [r for r in ROUTES if r[1] == library and r[4] is not None and (not only or r[0] in only)]
            if not routes:
                continue
            appearance = variant.split("-")[0]
            for route, _, _, _, steps in routes:
                why = not_in_appearance(route, appearance)
                if why:
                    results.append({"variant": name, "route": route, "notCaptured": why})
                    continue
                results.append(walk(variant, name, library, route, steps, folder))
    for route, library, _, _, steps in ROUTES:
        if steps is None and (not only or route in only):
            results.append({"variant": "-", "route": route, "notDriven": NOT_DRIVEN_WHY.get(route, "")})
    return results


class ReaderSession(Session):
    """XDict started as a reader starts it (no instrument), over a fresh account's state: its preferences deleted and
    its library (`~/Library/Application Support/ai.xdict.app`) moved aside, both put back by `main`."""

    def __init__(self):
        self.variant, self.lang, self.work = "light-en", "en", tempfile.mkdtemp(prefix="xdict-tour-")
        self.app, self.exe = app, exe
        run("defaults", "delete", DOMAIN, check=False)
        run("open", "-n", app)
        for _ in range(150):
            found = subprocess.run(["pgrep", "-f", exe], capture_output=True, text=True).stdout.split()
            if found:
                self.pid = int(found[0])
                break
            time.sleep(0.1)
        else:
            raise Failed("XDict did not start")
        time.sleep(5)

    def stderr(self):
        return ""

    def quit(self):
        run("osascript", "-e", f'tell application id "{DOMAIN}" to quit', check=False)
        for _ in range(100):
            if not running():
                break
            time.sleep(0.1)
        shutil.rmtree(self.work, ignore_errors=True)


def reader():
    """One real first launch, captured as it comes up: Settings opening on Setup by itself, the first window."""
    library = os.path.expanduser(f"~/Library/Application Support/{DOMAIN}")
    aside = library + ".ui-tour-aside"
    if os.path.exists(aside):
        raise SystemExit(f"tour: {aside} exists from an earlier run; put it back by hand before a reader launch")
    moved = os.path.exists(library)
    if moved:
        os.rename(library, aside)
    record = {"variant": "light-en", "route": "reader.firstLaunch"}
    folder = os.path.join(out, "light-en")
    os.makedirs(folder, exist_ok=True)
    try:
        session = ReaderSession()
        try:
            record["shots"], record["findings"] = capture(session, "reader.firstLaunch", folder)
        finally:
            session.quit()
    except (Failed, subprocess.TimeoutExpired, KeyError) as why:
        record["failure"] = str(why)
    finally:
        if running():
            record["failure"] = record.get("failure", "") + " XDict did not quit; its library was not put back"
        else:
            shutil.rmtree(library, ignore_errors=True)
            if moved:
                os.rename(aside, library)
    print(f"light-en reader.firstLaunch: {record.get('failure', 'ok')}", flush=True)
    return [record]


def main():
    # Two tours share this kit's output folder, XDict's preferences backup and the one bundle: the second would wipe
    # the first's captures and lose the reader's preferences (it happened on 2026-10-17).
    others = subprocess.run(["pgrep", "-f", "ui-tour-kit/tour.py"], capture_output=True, text=True).stdout.split()
    if [p for p in others if int(p) != os.getpid()]:
        raise SystemExit("tour: another UI tour is running on this Mac; wait for it")
    if running():
        # **Which process, by number and command line**: a refused start that cannot say what it saw sends the next reader
        # hunting (2026-10-30: it refused on a Mac where nothing seemed to run).
        pids = matching()
        lines = subprocess.run(["ps", "-o", "pid=,command=", "-p", ",".join(pids)], capture_output=True, text=True).stdout
        raise SystemExit(f"tour: XDict is already running; the tour does not quit a reader's XDict:\n{lines}")
    if subprocess.run(["pgrep", "-f", "xctest"], capture_output=True).returncode == 0:
        raise SystemExit("tour: an xctest run holds this Mac; wait for it")
    if subprocess.run(["pgrep", "-f", "XDictEntryLab.app/"], capture_output=True).returncode == 0:
        raise SystemExit("tour: another XDict run (XDictEntryLab: a gallery or E2E stage) holds this Mac; wait for it")
    access = as_json(run(keys, "access", check=False))
    if not access.get("accessibility") or not access.get("postEvents"):
        raise SystemExit(f"tour: this session may not drive the window ({access})")
    os.makedirs(os.path.dirname(ax_tool), exist_ok=True)
    run("swiftc", "-O", "-o", ax_tool, os.path.join(here, "ax.swift"), wait=300)
    global LEDGER_SANDBOX
    registry = os.path.join(os.path.expanduser("~"), "Library", "Containers", DOMAIN + ".DictionaryService",
                            "Data", "Library", "Application Support", "registry")
    def interrupted(*_):
        raise SystemExit("tour: interrupted; restoring owned state")
    signal.signal(signal.SIGTERM, interrupted)
    with RegistrySandbox(registry, os.path.join(home, "ui-tour-state"), lambda: stop_owned_service(app)) as sandbox:
        LEDGER_SANDBOX = sandbox
        backup = os.path.join(out, ".prefs-backup.plist")
        had = run("defaults", "export", DOMAIN, backup, check=False).returncode == 0
        try:
            results = reader() if "--reader" in sys.argv else tour()
        finally:
            run("defaults", "delete", DOMAIN, check=False)
            if had:
                run("defaults", "import", DOMAIN, backup)
                os.remove(backup)
            restored = run("defaults", "export", DOMAIN, "-", check=False).stdout
            print(f"tour: XDict's preferences {'restored' if had else 'removed (none existed before)'}"
                  f" ({len(restored)} bytes now)", flush=True)
        LEDGER_SANDBOX = None
    path = os.path.join(out, "results.json")
    if "--reader" in sys.argv and os.path.exists(path):
        results = [r for r in json.load(open(path)) if r["route"] != "reader.firstLaunch"] + results
    with open(path, "w") as f:
        json.dump(results, f, indent=1)
    failed = [r for r in results if r.get("failure")]
    print(f"tour: {len(results)} route captures, {len(failed)} failures", flush=True)


main()
