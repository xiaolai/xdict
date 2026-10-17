#!/usr/bin/env python3
"""The WI-10 measurement (plan-macos-v1 WI-10, "Measurement protocol"), the E2E `measure` sub-stage: the real app
(`XDict --measure`) over the 24, driven by real key events (`keys`, posted into the HID stream).

    python3 -I drive.py <kit> <work> <app> <corpus> <driver.json>

1. Warm: one launch; once its library has settled, ten warm-up lookups, then 200 timed ones, each a different word:
   the search field asked for the keyboard, ⌘A, the word typed, Return. The app times Return to the entry's first paint.
2. Memory with the 24 open: the physical footprint (`vmmap --summary`) of the app and of its dictionary service.
3. Selection key to panel: 20 times, a word selected in TextEdit, the lookup shortcut pressed, the seconds until
   XDict's floating panel is in the window list (`hands panel`, polled every 2 ms: a bound, not subtracted), Escape.
4. Cold: 20 times, the app quit and its service killed, `sudo -n purge` when allowed (recorded either way), the app
   started again, one timed lookup of a word not yet asked.

Writes `Findings` to <driver.json>: `measure.warm`, `measure.cold`, `measure.panel`, `measure.memory`, and every number
in `facts`. Nothing here decides a release by itself; the owner reads the report.
"""
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stats  # noqa: E402

kit, work, app, corpus, out = sys.argv[1:6]
keys = os.path.join(kit, "lookup", "keys")
hands = os.path.join(kit, "anywhere", "hands")
commands = os.path.join(work, "commands")
samples_file = os.path.join(work, "samples.jsonl")
SERVICE = "ai.xdict.app.DictionaryService.xpc/Contents/MacOS/"
SHORTCUT = "ctrl+opt+d"
SAMPLE_WAIT = 10.0
# 10 warm-up + 200 warm + 20 cold, all different, all common English headwords the 24 hold.
WORDS = """
time year people way day man thing woman life child world school state family student group country problem hand part
place case week company system program question work government number night point home water room mother area money
story fact month lot right study book eye job word business issue side kind head house service friend father power hour
game line end member law car city community name president team minute idea kid body information back parent face others
level office door health person art war history party result change morning reason research girl guy moment air teacher
force education foot boy age policy music market sense nation plan college interest death experience effect use class
control care field development role effort rate heart drug show leader light voice wife police mind price report decision
son view relationship town road arm difference value building action model season society tax director position player
record paper space ground form event official matter center couple site project activity star table need court oil
situation cost industry figure street image phone data picture practice piece land product doctor wall patient worker
news test movie north love support technology step baby computer type attention film tree source organization hair
window evidence population truth fire stock bank trial rock garden river bread salt horse bridge island
apple chair cloud dream engine forest glass honey journey kitchen ladder mountain needle ocean pencil quiet silver
""".split()
WORDS = list(dict.fromkeys(WORDS))
assert len(WORDS) >= stats.WARMUP + stats.WARM + stats.COLD, "too few distinct words for the protocol"
checks, facts = [], {"protocol": {"warmup": stats.WARMUP, "warm": stats.WARM, "cold": stats.COLD, "panel": stats.PANEL,
                                  "warmP95GateSeconds": stats.WARM_P95_GATE, "percentile": "nearest rank"}}
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


def abort(why):
    write_out()
    raise SystemExit(f"drive: {why}")


def run(*args, timeout=60):
    done = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    return done.returncode, done.stdout, done.stderr


def tool(*args):
    status, said, err = run(keys, *args)
    if status != 0:
        abort(f"keys {' '.join(map(str, args))} failed: {err.strip()}")


def ask(op, wait=15):
    global sequence
    sequence += 1
    path = os.path.join(commands, f"{sequence:03d}.json")
    with open(path + ".tmp", "w") as f:
        json.dump({"op": op}, f)
    os.replace(path + ".tmp", path)
    answer = path.replace(".json", ".out.json")
    end = time.time() + wait
    while time.time() < end:
        if os.path.exists(answer):
            try:
                return json.load(open(answer))
            except ValueError:
                pass
        time.sleep(0.05)
    abort(f"the app did not answer {op}")


def samples():
    if not os.path.exists(samples_file):
        return []
    with open(samples_file) as f:
        return [json.loads(line) for line in f if line.strip()]


def service_pids():
    _, said, _ = run("pgrep", "-f", SERVICE)
    return [int(p) for p in said.split()]


def launch():
    """The app started by LaunchServices, its library settled; sets `pid`. Commands restart at 1 for each launch."""
    global pid, sequence
    sequence = 0
    if os.path.isdir(commands):
        for name in os.listdir(commands):
            os.remove(os.path.join(commands, name))
    status, _, err = run("open", "-n", "--stdout", os.path.join(work, "app.out"), "--stderr",
                         os.path.join(work, "app.err"), app, "--args", "-ApplePersistenceIgnoreState", "YES",
                         "--measure", work, "--corpus", corpus)
    if status != 0:
        abort(f"the app could not be started: {err.strip()}")
    ready = os.path.join(commands, "ready.json")
    end = time.time() + 900
    while time.time() < end and not os.path.exists(ready):
        time.sleep(0.2)
    if not os.path.exists(ready):
        abort("the app's library never settled (no ready.json in 900 s)")
    time.sleep(0.2)
    said = json.load(open(ready))
    pid = said["pid"]
    return said


def quit_app():
    ask("quit", wait=5)
    for _ in range(100):
        if run("kill", "-0", pid)[0] != 0:
            break
        time.sleep(0.1)
    for service in service_pids():
        run("kill", "-KILL", service)


def lookup(word):
    """One typed lookup; its sample, or None when the app wrote none in time."""
    before = len(samples())
    ask("front")
    time.sleep(0.15)
    tool("press", "cmd+a")
    tool("type", word)
    time.sleep(0.05)
    tool("press", "return")
    end = time.time() + SAMPLE_WAIT
    while time.time() < end:
        got = samples()
        if len(got) > before:
            return got[-1]
        time.sleep(0.05)
    return None


def timed(words):
    got, missing = [], []
    for word in words:
        s = lookup(word)
        if s is None:
            missing.append(word)
        else:
            got.append(s)
            if s.get("key", "").lower() != word.lower():
                facts.setdefault("answers", []).append(f"{word!r} showed {s.get('key')!r} in {s.get('dictionary')}")
    return got, missing


def footprint(target):
    _, said, _ = run("vmmap", "--summary", target, timeout=120)
    found = re.search(r"Physical footprint:\s+([\d.]+)([KMG])", said)
    if not found:
        return None
    return round(float(found[1]) * {"K": 1 / 1024, "M": 1, "G": 1024}[found[2]], 1)


def panel_samples():
    note = os.path.join(work, "selection.txt")
    with open(note, "w") as f:
        f.write("Look up the word bridge in XDict.\n")
    run("open", "-a", "TextEdit", note)
    time.sleep(3)
    seconds = []
    for _ in range(stats.PANEL):
        status, said, err = run(hands, "select", "com.apple.TextEdit", "bridge", timeout=30)
        if status != 0:
            facts.setdefault("panelErrors", []).append(err.strip()[:200])
            continue
        status, said, _ = run(hands, "panel", pid, SHORTCUT, 3, timeout=30)
        answer = json.loads(said.strip().splitlines()[-1]) if status == 0 and said.strip() else {}
        if answer.get("seconds") is not None:
            seconds.append(answer["seconds"])
        tool("press", "escape")
        time.sleep(0.5)
    run("osascript", "-e", 'tell application "TextEdit" to quit saving no')
    return seconds


def main():
    os.makedirs(commands, exist_ok=True)
    if os.path.exists(samples_file):
        os.remove(samples_file)
    words = iter(WORDS)

    def take(n):
        return [next(words) for _ in range(n)]

    said = launch()
    facts["dictionaries"] = len(said.get("dictionaries", []))
    if not said.get("settled") or facts["dictionaries"] < 24:
        check("measure.warm", False, f"the library holds {facts['dictionaries']} dictionaries, settled {said.get('settled')}")
    timed(take(stats.WARMUP))
    warm_samples, warm_missing = timed(take(stats.WARM))
    warm, warm_raw, warm_invalid = stats.corrected(warm_samples)
    facts["memoryMiB"] = {"app": footprint(pid), "service": [footprint(p) for p in service_pids()]}
    seconds = panel_samples() if os.path.exists(hands) else []
    quit_app()
    cold_samples, cold_missing, purged = [], [], []
    for word in take(stats.COLD):
        purged.append(run("sudo", "-n", "purge")[0] == 0)
        launch()
        s = lookup(word)
        (cold_samples.append(s) if s else cold_missing.append(word))
        quit_app()
    cold, cold_raw, cold_invalid = stats.corrected(cold_samples)
    overhead = [s.get("overheadSeconds", 0.0) for s in warm_samples]
    w, c, p = stats.summary(warm), stats.summary(cold), stats.summary(seconds)
    facts.update({"warm": w, "warmUncorrected": stats.summary(warm_raw), "cold": c,
                  "coldUncorrected": stats.summary(cold_raw), "panel": p,
                  "overheadP50Seconds": stats.percentile(overhead, 50) if overhead else None,
                  "invalid": warm_invalid + cold_invalid, "missing": warm_missing + cold_missing,
                  "coldPurged": f"{sum(purged)} of {len(purged)} (sudo -n purge)",
                  "table": stats.report([("typed lookup, warm", w, facts.get("overheadP50Seconds")),
                                         ("typed lookup, cold", c, None), ("selection key to panel", p, None)])})
    _, why = stats.lookup_verdict(w, c)
    check("measure.warm", w["n"] == stats.WARM and w["p95"] is not None and w["p95"] <= stats.WARM_P95_GATE,
          f"warm p50 {stats.ms(w['p50'])}, p95 {stats.ms(w['p95'])} of {w['n']} (gate {stats.WARM_P95_GATE} s); {why}")
    check("measure.cold", c["n"] == stats.COLD,
          f"cold p50 {stats.ms(c['p50'])}, p95 {stats.ms(c['p95'])} of {c['n']}; purged {facts['coldPurged']}")
    check("measure.panel", p["n"] == stats.PANEL,
          f"selection key to panel p50 {stats.ms(p['p50'])}, p95 {stats.ms(p['p95'])} of {p['n']}")
    memory = facts["memoryMiB"]
    check("measure.memory", memory["app"] is not None and bool(memory["service"]) and None not in memory["service"],
          f"with the 24 open: app {memory['app']} MiB, service {memory['service']} MiB (physical footprint)")
    print(facts["table"], flush=True)


main()
