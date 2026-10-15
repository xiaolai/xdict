#!/usr/bin/env python3
"""The hostile stage's analysis (plan-macos-v1 WI-4), adapted from spike 3's: joins what the observers saw with what
the lab's entry view saw, per case and per run, and holds the runs to the suite's rules.

    python3 -I analyze.py run <run-dir>             summary.json on stdout
    python3 -I analyze.py suite <results-dir>       one PASS or FAIL line per rule, then the matrix; exit 1 on any FAIL
    python3 -I analyze.py reader <run-dir>          the reader-driven run's facts, as JSON
    python3 -I analyze.py verdicts <run-dir>        the reader-driven run's PASS and FAIL lines
    python3 -I analyze.py faults <results-dir>      the fail-closed runs' PASS and FAIL lines
    python3 -I analyze.py binding <results-dir>     the binding run's PASS and FAIL lines
    python3 -I analyze.py entries <results-dir>     the real dictionaries' PASS and FAIL lines
    python3 -I analyze.py runs <cases.json>         the run labels, in order
    python3 -I analyze.py off <cases.json> <label>  the layers a run turns off, comma-separated

"Left" means an observer counted it: an HTTP request, a TCP connection, a UDP datagram on the case's own port, a lookup
of one of the case's own names by any process but the oracle, or an mDNSResponder request from the lab's WebKit
processes during the case. A run directory holds `cases.json`, `report.json` (the lab's), `observed.jsonl`,
`dns.ndjson`, `oracle.json`, `lab.started` and `lab.ended`.
"""
import datetime
import json
import os
import re
import sys

HASH = re.compile(r"(?:qname|hostname|name hash): <private> <dn:([^>]+)>|name hash: <dn:([^>]+)>")
CLIENT = re.compile(r"client pid: (\d+) \(([^)]*)\)|PID\[(\d+)\]\(([^)]*)\)")
DELEGATOR = re.compile(r"delegator pid: (\d+) \(([^)]*)\)")


def load_jsonl(path):
    out = []
    if not os.path.exists(path):
        return out
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if line.startswith("{"):
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    return out


def dns_lines(path):
    """mDNSResponder's START lines: (epoch seconds, hash, client pid, client name, delegator pid, message)."""
    out = []
    for e in load_jsonl(path):
        msg = e.get("eventMessage", "")
        if "START" not in msg and " start " not in msg:
            continue
        h = HASH.search(msg) or re.search(r"name: <private> <dn:([^>]+)>()", msg)
        c = CLIENT.search(msg)
        if not c:
            continue
        if not h:
            # A connection a process opens to mDNSResponder for its own records (a WebRTC host candidate's .local
            # name is registered over one): no name, so kept under a placeholder hash.
            if "DNSServiceCreateConnection START" not in msg:
                continue
            h = re.match(r"()(-)", "-")
        ts = datetime.datetime.strptime(e["timestamp"], "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
        dg = DELEGATOR.search(msg)
        out.append((ts, h.group(1) or h.group(2), int(c.group(1) or c.group(3)), c.group(2) or c.group(4),
                    int(dg.group(1)) if dg else None, msg[:240]))
    return out


def summarize(d):
    listed = json.load(open(os.path.join(d, "cases.json")))
    lab = json.load(open(os.path.join(d, "report.json")))
    observed = load_jsonl(os.path.join(d, "observed.jsonl"))
    oracle = json.load(open(os.path.join(d, "oracle.json")))
    started = int(open(os.path.join(d, "lab.started")).read())
    ended = int(open(os.path.join(d, "lab.ended")).read())
    token, ctl = listed["token"], listed["control"]
    lines = dns_lines(os.path.join(d, "dns.ndjson"))

    name_hash, oracle_problems = {}, [] if oracle["asked"] else ["the oracle asked nothing"]
    for q in oracle["asked"]:
        hs = {h for (ts, h, pid, _, _, _) in lines
              if pid == oracle["pid"] and h != "-" and q["t0"] - 0.05 <= ts <= q["t1"] + 0.25}
        if len(hs) != 1:
            oracle_problems.append({"name": q["name"], "hashes": sorted(hs)})
        if hs:
            name_hash[q["name"]] = hs
    our_hashes = set().union(*name_hash.values()) if name_hash else set()

    def lookups(name, lo, hi):
        hs = name_hash.get(name, set())
        return [(ts, pid, who) for (ts, h, pid, who, _, _) in lines
                if h in hs and pid != oracle["pid"] and lo <= ts <= hi]

    controls = {
        "http": sum(1 for e in observed if e.get("kind") == "http" and e.get("port") == ctl["http"]),
        "tcp": sum(1 for e in observed if e.get("kind") == "tcp-accept" and e.get("port") == ctl["tcp"]),
        "udp": sum(1 for e in observed if e.get("kind") == "udp" and e.get("port") == ctl["udp"]),
        "dns": len(lookups(listed["selftestName"], started - 60, started + 1)),
        "dnsOracle": "ok" if not oracle_problems else oracle_problems,
    }

    cases = {}
    labcases = lab.get("cases", {})
    for c in listed["cases"]:
        cid = c["id"]
        ev = [e for e in observed if e.get("port") in (c["tcp"], c["udp"]) and e.get("case") == cid]
        http = [f'{e["method"]} {e["path"].replace("/" + token + "/" + cid + "/", "")}' for e in ev if e["kind"] == "http"]
        tcp_accept = sum(1 for e in ev if e["kind"] == "tcp-accept")
        tcp_idle = sum(1 for e in ev if e["kind"] == "tcp-idle")
        udp = [e["proto"] for e in ev if e["kind"] == "udp"]
        dns = {n: len(lookups(n, started - 1, ended + 10)) for n in c["names"]}
        dns_who = sorted({who for n in c["names"] for (_, _, who) in lookups(n, started - 1, ended + 10)})
        shell = labcases.get(cid, {})
        page = shell.get("page", [])
        events = [e.get("event", "") for e in shell.get("events", [])]
        leaks = []
        if http:
            leaks.append(f"http×{len(http)}")
        if tcp_accept:
            leaks.append(f"tcp×{tcp_accept}" + (f" (idle {tcp_idle})" if tcp_idle else ""))
        if udp:
            leaks.append(f"udp×{len(udp)} {sorted(set(udp))}")
        if sum(dns.values()):
            leaks.append(f"dns×{sum(dns.values())} {dns_who}")
        broken = None
        oks = {p[1] for p in page if len(p) == 2 and p[0] == "ok"}
        if cid == "ok-xdict":
            need = {"script", "inline", "eval", "function", "data-img", "img", "css", "audio"}
            broken = sorted(need - oks)
        elif cid == "ok-placeholder":
            broken = [] if any(str(o).startswith("placeholder ") and not str(o).endswith(" 0") for o in oks) \
                else ["placeholder"]
        elif cid == "ok-link-nav":
            broken = [] if any("linkRouted" in e and '"lookup"' in e for e in events) else ["routed lookup"]
        cases[cid] = {
            "payload": c["payload"], "context": c["context"], "group": c["group"],
            "loaded": bool(shell.get("loaded")), "left": bool(leaks), "leaks": leaks, "broken": broken,
            "http": http, "tcpAccept": tcp_accept, "tcpIdle": tcp_idle, "udp": udp, "dns": dns, "dnsClients": dns_who,
            "liveInEntry": shell.get("entryHoldsLiveTarget"), "liveInResource": shell.get("resourceHoldsLiveTarget"),
            "refusal": shell.get("refusal"), "page": [": ".join(str(x) for x in p) for p in page][:40],
            "events": events[:60],
        }

    known_ports = {c["tcp"] for c in listed["cases"]} | {c["udp"] for c in listed["cases"]} | set(ctl.values())
    known_ports |= {listed["reader"]["tcp"], listed["reader"]["udp"]}
    stray = [e for e in observed if e.get("port") is not None and e.get("port") not in known_ports]
    # Every other mDNSResponder request of the lab's WebKit: lookups naming the lab as delegator, and anything (a .local
    # registration carries no delegator) from the WebKit processes the lab reported serving its cases.
    lab_pid = lab.get("pid")
    procs = {v.get(k) for v in labcases.values() for k in ("networkPid", "webPid") if isinstance(v.get(k), int)}
    other = sorted({(round(ts, 1), who, h, msg.split(" -- ")[0].split("] ")[-1])
                    for (ts, h, pid, who, dg, msg) in lines
                    if (dg == lab_pid or pid == lab_pid or pid in procs) and h not in our_hashes
                    and started - 1 <= ts <= ended + 10})
    windows = {cid: (labcases.get(cid, {}).get("start", 0), labcases.get(cid, {}).get("end", 0)) for cid in cases}
    exclusive = {c["id"] for c in listed["cases"] if c.get("exclusive")}
    for (ts, who, h, what) in other:
        hit = [cid for cid, (lo, hi) in windows.items() if lo - 0.2 <= ts <= hi + 1.0]
        hit = [cid for cid in hit if cid in exclusive] or hit
        if hit and all(cid in exclusive for cid in hit):
            hit = [max(hit, key=lambda cid: windows[cid][0] if windows[cid][0] <= ts else -1)]
        for cid in hit:
            cases[cid]["leaks"].append(f"mdns:{what}")
            cases[cid]["left"] = True
    return {
        "label": os.path.basename(d.rstrip("/")), "disabled": lab.get("disabled"), "confinement": lab.get("confinement"),
        "switchesReadBack": lab.get("switchesReadBack"), "opened": lab.get("opened"), "os": lab.get("os"),
        "webkit": lab.get("webkit"), "controls": controls, "cases": cases,
        "notLoaded": sorted(cid for cid, v in cases.items() if not v["loaded"]),
        "notReported": sorted(set(cases) - set(labcases)),
        "stray": stray, "webkitOtherLookups": [f"{ts} {w} {h} {what}" for (ts, w, h, what) in other],
    }


def reader(d):
    """The reader-driven run: nothing on the reader entry's own ports and names, the pointer's events seen to arrive,
    each remote question raised and answered by a real click, and the one consented URL the only one opened."""
    listed = json.load(open(os.path.join(d, "cases.json")))
    lab = json.load(open(os.path.join(d, "report.json")))
    driven = json.load(open(os.path.join(d, "steps.json")))
    observed = load_jsonl(os.path.join(d, "observed.jsonl"))
    oracle = json.load(open(os.path.join(d, "oracle.json")))
    started = int(open(os.path.join(d, "lab.started")).read())
    ended = int(open(os.path.join(d, "lab.ended")).read())
    ctl, ports = listed["control"], {listed["reader"]["tcp"], listed["reader"]["udp"]}
    lines = dns_lines(os.path.join(d, "dns.ndjson"))
    name_hash = {}
    for q in oracle["asked"]:
        hs = {h for (ts, h, pid, _, _, _) in lines
              if pid == oracle["pid"] and h != "-" and q["t0"] - 0.05 <= ts <= q["t1"] + 0.25}
        if hs:
            name_hash[q["name"]] = hs
    lookups = {n: [(ts, who) for (ts, h, pid, who, _, _) in lines
                   if h in name_hash.get(n, set()) and pid != oracle["pid"] and started - 1 <= ts <= ended + 10]
               for n in listed["reader"]["names"]}
    lab_pid = lab.get("pid")
    procs = {lab.get(k) for k in ("networkPid", "webPid") if isinstance(lab.get(k), int)}
    ours = set().union(*name_hash.values()) if name_hash else set()
    other = sorted({(round(ts, 1), who, msg.split(" -- ")[0].split("] ")[-1]) for (ts, h, pid, who, dg, msg) in lines
                    if (dg == lab_pid or pid == lab_pid or pid in procs) and h not in ours
                    and started - 1 <= ts <= ended + 10})
    steps = driven["steps"]

    def find(name):
        return next((s for s in steps if s["step"] == name), {})

    def said(s, text):
        return any(text in e.get("event", "") for e in s.get("events", []))

    placeholder = find("click img-remote placeholder")
    checks = {
        "observer controls": {
            "http": sum(1 for e in observed if e.get("kind") == "http" and e.get("port") == ctl["http"]),
            "tcp": sum(1 for e in observed if e.get("kind") == "tcp-accept" and e.get("port") == ctl["tcp"]),
            "udp": sum(1 for e in observed if e.get("kind") == "udp" and e.get("port") == ctl["udp"]),
            "dns": sum(1 for (ts, h, pid, who, _, _) in lines if h in name_hash.get(listed["selftestName"], set())
                       and pid != oracle["pid"])},
        "egress": [e for e in observed if e.get("port") in ports],
        "lookups": {n: v for n, v in lookups.items() if v},
        "otherWebKitLookups": [f"{ts} {who} {what}" for (ts, who, what) in other],
        "the plain click raised the question": find("click link-remote none").get("prompt") is True,
        "it was answered by a click on Cancel": said(find("click link-remote none"), "consent: false")
                                                or find("click link-remote none").get("answered") == "cancel",
        "nothing opened before the one yes": all(s.get("opened") == [] for s in steps[:steps.index(placeholder)])
                                             if placeholder in steps else False,
        "the placeholder's yes opened its URL alone": len(placeholder.get("openedAfter", [])) == 1
                                                       and listed["reader"]["names"][1] in placeholder["openedAfter"][0],
        "opened at the end": lab.get("opened", []),
        "the link to an entry was routed as a lookup": said(find("click link-entry"), '"lookup"'),
        "the context menu was filtered": all(said(find(f"context menu {n}"), "menuFiltered")
                                             for n in ["link-remote", "img-remote", "img-local", "link-image"]),
        "downloads": {s["step"]: [e["event"][:160] for e in s["events"] if "download" in e["event"].lower()
                                  or "refuse" in e["event"]] for s in steps if "download" in s["step"]},
        "drops": lab.get("drops", []),
        # A drag that delivered nothing would read as "nothing left" for a drag that never happened.
        "each drag delivered a drop": {s["step"]: len(s.get("dropped", [])) for s in steps
                                       if s["step"].startswith("drag ")},
        "access": driven.get("access"),
        # Where the lab had lost the front between steps and was brought back before the hand moved (`reader.py`'s
        # `hold`), and what had stood in the way: shown, never silent.
        "refocused": {s["step"]: s["refocused"] for s in steps if s.get("refocused")},
    }
    # WebKit drags no SVG image out of a web view (measured 2026-10-14): those drags are made, watched, and not expected
    # to deliver; a raster image, a link and an image in a link must.
    must = {"drag img-data", "drag img-raster", "drag link-image", "drag link-remote"}
    delivered = checks["each drag delivered a drop"]
    checks["every drag delivered a drop"] = must <= set(delivered) and all(delivered[s] > 0 for s in must)
    # A failed assertion carries the scene of the step it rests on, so a run that went wrong says why.
    rests_on = [("the plain click raised the question", "click link-remote none"),
                ("it was answered by a click on Cancel", "click link-remote none"),
                ("the placeholder's yes opened its URL alone", "click img-remote placeholder"),
                ("the link to an entry was routed as a lookup", "click link-entry")]
    checks["why"] = {k: scene(find(n)) for k, n in rests_on if checks[k] is not True}
    failed = [n for n in ["link-remote", "img-remote", "img-local", "link-image"]
              if not said(find(f"context menu {n}"), "menuFiltered")]
    if failed:
        checks["why"]["the context menu was filtered"] = "; ".join(f"{n}: {scene(find(f'context menu {n}'))}"
                                                                   for n in failed)
    checks["why"]["drags"] = {n: scene(find(n)) for n in sorted(must) if delivered.get(n, 0) == 0}
    c = checks["observer controls"]
    checks["pass"] = (min(c.values()) >= 1 and not checks["egress"] and not checks["lookups"]
                      and not checks["otherWebKitLookups"] and checks["the plain click raised the question"]
                      and checks["it was answered by a click on Cancel"] and checks["nothing opened before the one yes"]
                      and checks["the placeholder's yes opened its URL alone"]
                      and checks["the link to an entry was routed as a lookup"] and checks["the context menu was filtered"])
    return checks


def say(ok, text):
    print(f"{'PASS' if ok else 'FAIL'}  {text}")
    return ok


def scene(s):
    """Why a step's event may not have landed, from what `reader.py` recorded around it: the lab's focus before and
    after, the session and display, the frontmost application, the windows over the point, and the button and key events
    and activations the lab saw while the step ran."""
    if not s:
        return "the step never ran"
    if "before" not in s:
        return "the step recorded no scene"
    lab, scr = s["before"].get("lab", {}), s["before"].get("screen", {})
    after = s.get("after") or {}
    front = scr.get("frontmost", {})
    over = [[f"{w.get('owner')}({w.get('pid')}) layer {w.get('layer')}" for w in at][:4] for at in scr.get("at") or []]
    got = [f"{e['what']}" + (f" in {e['window']} active={e.get('active')} key={e.get('key')}" if "active" in e
                             else f" {e.get('window') or e.get('app', '')}") for e in s.get("received", [])]
    return (f"before it: lab active {lab.get('active')}, reader key {lab.get('key')}, "
            f"unoccluded {lab.get('unoccluded')}, key window {lab.get('keyWindow')!r}; "
            f"frontmost {front.get('name')!r} pid {front.get('pid')}; locked {scr.get('locked')}, "
            f"display asleep {scr.get('displayAsleep')}; over each point {over}; "
            f"during it the lab saw {got or 'no button, key or focus event'}; "
            f"after it: lab active {after.get('active')}, reader key {after.get('key')}"
            + (f"; {scr['error']}" if "error" in scr else ""))


def reader_verdicts(d):
    s = json.load(open(os.path.join(d, "summary.json")))
    c = s["observer controls"]
    results = [say(min(c.values()) >= 1, f"every observer caught its deliberate attempt ({c})"),
               say(not s["egress"] and not s["lookups"] and not s["otherWebKitLookups"],
                   f"nothing left on any observer (egress {len(s['egress'])}, lookups {s['lookups']}, "
                   f"other WebKit lookups {s['otherWebKitLookups'][:3]})")]
    why = s.get("why", {})
    for key in ["the plain click raised the question", "it was answered by a click on Cancel",
                "nothing opened before the one yes", "the placeholder's yes opened its URL alone",
                "the link to an entry was routed as a lookup", "the context menu was filtered"]:
        results.append(say(s[key] is True, key + ("" if s[key] is True or key not in why else f" — {why[key]}")))
    drags = s.get("each drag delivered a drop")
    results.append(say(s.get("every drag delivered a drop") is True,
                       f"every drag of a link or a raster image out of the view delivered a drop ({drags})"
                       + "".join(f" — {n}: {w}" for n, w in why.get("drags", {}).items())))
    for name, fixed in s.get("refocused", {}).items():
        how = " (LaunchServices asked)" if fixed.get("launchServices") else ""
        print(f"NOTE  before {name!r} the lab was brought back to the front in {fixed.get('took')} s{how}: "
              f"{'; '.join(fixed.get('found', []))}")
    print(f"NOTE  opened at the end: {s['opened at the end']}")
    print(f"NOTE  downloads: {s['downloads']}")
    print(f"NOTE  drops: {[(d.get('types', [])[:3], d.get('url', '')[:80], d.get('promises')) for d in s['drops']]}")
    return 0 if all(results) else 1


def faults(res):
    names = ["missing-list", "missing-feature", "missing-setter", "missing-getter", "ineffective-setter"]

    def load(name):
        path = os.path.join(res, f"fault-{name}.json")
        return json.load(open(path)) if os.path.exists(path) else None

    results = []
    control = load("none")
    if control is None:
        results.append(say(False, "fail-closed control: the lab wrote no report"))
    else:
        results.append(say(control["webViewMade"] and control["loads"] > 0 and control["refusal"] is None
                           and control["shown"],
                           f"fail-closed control: the real switches render the entry (web view made: "
                           f"{control['webViewMade']}, loads: {control['loads']}, refusal: {control['refusal']})"))
    sentences = {}
    for fault in names:
        r = load(fault)
        if r is None:
            results.append(say(False, f"fault {fault}: the lab wrote no report"))
            continue
        sentences[fault] = r["sentence"]
        results.append(say(r["refusal"] is not None and not r["webViewMade"] and r["loads"] == 0 and not r["shown"]
                           and bool(r["sentence"]),
                           f"fault {fault}: refused, no web view, zero loads (refusal: {r['refusal']}; loads: "
                           f"{r['loads']}; “{r['sentence']}”)"))
    results.append(say(len(set(sentences.values())) == len(names),
                       f"the {len(names)} faults give {len(set(sentences.values()))} distinct sentences"))
    return 0 if all(results) else 1


def binding(res):
    path = os.path.join(res, "binding.json")
    if not os.path.exists(path):
        say(False, "binding: the lab wrote no report")
        return 1
    s = json.load(open(path))["steps"]
    results = [
        say(s.get("controlB") == '"B"' and s.get("controlA") == '"A"',
            f"binding: each twin alone shows its own marker (A {s.get('controlA')}, B {s.get('controlB')})"),
        say(not s.get("sameHandle") and s.get("aHeld", 0) >= 1,
            f"binding: A's marker request was held ({s.get('aHeld')}) on a handle of its own"),
        say(s.get("bBeforeRelease") == '"B"' and s.get("bAfterRelease") == '"B"',
            f"binding: B keeps B's marker when A's held answer is let go "
            f"({s.get('bBeforeRelease')} then {s.get('bAfterRelease')})"),
        say(s.get("servedFromAAfterSwitch") == [],
            f"binding: nothing of A's reached a view after the switch ({s.get('servedFromAAfterSwitch')})"),
    ]
    return 0 if all(results) else 1


def entries(res):
    """The owner's dictionaries through the production entry view (plan-macos-v1 WI-4, done-when)."""
    def load(name):
        path = os.path.join(res, name)
        return json.load(open(path)) if os.path.exists(path) else None

    results = []
    corpus = load("corpus.json")
    if corpus is None:
        results.append(say(False, "the corpus run wrote no report"))
    else:
        totals = {k: sum(v.get(k, 0) for v in corpus["dictionaries"].values())
                  for k in ("entries", "images", "sheets", "notLoaded", "outside")}
        results.append(say(corpus["rendered"] == corpus["sampled"] and not corpus["failures"],
                           f"{corpus['rendered']} of {corpus['sampled']} sampled entries of {len(corpus['dictionaries'])} "
                           f"dictionaries rendered, every image and stylesheet the core resolved loaded, nothing outside "
                           f"xdict: ({totals}; failures {corpus['failures'][:4]})"))
        for name in ("oald", "ldoce"):
            fold = corpus.get("folding", {}).get(name)
            results.append(say(isinstance(fold, dict) and fold.get("worked") is True,
                               f"{name}'s folding script opens a section (R5): {fold}"))
        long = corpus.get("long", {})
        results.append(say(long.get("finished") is True and long.get("seconds", 99) < 10,
                           f"LDOCE's hold finishes ({long.get('seconds', -1):.2f} s)"))
        for query in ("hold", "on", "the"):
            found = long.get(f"find {query}", {})
            results.append(say(found.get("visible", -1) == found.get("innerText", -2) and found.get("visible", 0) > 0,
                               f"find '{query}' in hold counts what the entry's text holds ({found})"))
        # The width the lab's window settled at, as measured: asked for 360 points, it stops at the view's minimum.
        narrow = long.get("narrow") or {}
        width = narrow.get("windowWidth")
        results.append(say(isinstance(width, (int, float)) and 0 < narrow.get("scrollWidth", 0)
                           <= narrow.get("clientWidth", 0) + 1,
                           f"hold in a window at its narrowest, "
                           f"{f'{width:g} points' if isinstance(width, (int, float)) else 'its width not reported'}, "
                           f"needs no horizontal scrolling ({narrow})"))
    wanted = {"oald": (1.5, "dark", "dark"), "ldoce": (0.8, "original", "light")}
    for stage in ("persistence-set.json", "persistence-check.json"):
        r = load(stage)
        if r is None:
            results.append(say(False, f"{stage}: the lab wrote no report"))
            continue
        for name, (zoom, theme, scheme) in wanted.items():
            got = r.get(name) if isinstance(r.get(name), dict) else {}
            results.append(say(abs(got.get("zoom", 0) - zoom) < 1e-6 and abs(got.get("pageZoom", 0) - zoom) < 1e-6
                               and got.get("theme") == theme and got.get("colorScheme") == scheme,
                               f"{stage.split('.')[0]}: {name} at zoom {zoom}, {theme}, drawn {scheme} ({got})"))
    return 0 if all(results) else 1


def suite(res):
    listed = json.load(open(os.path.join(res, "cases.json")))
    runs = {}
    for label in listed["runs"]:
        path = os.path.join(res, label, "summary.json")
        runs[label] = json.load(open(path)) if os.path.exists(path) else None
    verdicts = []

    def rule(ok, text):
        verdicts.append(("PASS" if ok else "FAIL", text))

    for label, s in runs.items():
        if s is None:
            rule(False, f"{label}: no summary: the run did not happen")
            continue
        c = s["controls"]
        rule(c["http"] >= 1 and c["tcp"] >= 1 and c["udp"] >= 1 and c["dns"] >= 1 and c["dnsOracle"] == "ok",
             f"{label}: every observer caught its deliberate attempt (http={c['http']} tcp={c['tcp']} udp={c['udp']} "
             f"dns={c['dns']} oracle={'ok' if c['dnsOracle'] == 'ok' else c['dnsOracle']})")
        rule(not s["notReported"] and not s["notLoaded"],
             f"{label}: every case ran and reported loaded ({len(s['cases'])} cases; not reported "
             f"{s['notReported'][:5] or 'none'}; not loaded {s['notLoaded'][:8] or 'none'})")
        rule(not s["stray"], f"{label}: no observer event outside the battery's ports ({len(s['stray'])})")
        wanted_off = sorted(set(listed["layers"]) - set(listed["runs"][label]))
        rule(sorted(s["disabled"] or []) == wanted_off, f"{label}: the lab ran with exactly {wanted_off or 'nothing'} off")
        rule(s["opened"] == [], f"{label}: nothing was opened in a browser ({s['opened']})")

    production = runs.get("production")
    if production:
        left = {cid: v["leaks"] for cid, v in production["cases"].items() if v["left"]}
        rule(not left, f"production: nothing left, on any observer, from any of {len(production['cases'])} cases "
                       f"({left if left else 'zero http, tcp, udp, dns, mdns'})")
        rule(not production["webkitOtherLookups"],
             f"production: no other lookup by the lab's WebKit ({production['webkitOtherLookups'][:3]})")
        rule((production["confinement"] or {}).get("production") is True, "production: the confinement is the app's")
        rule(production["switchesReadBack"] == {"LinkPreconnect": False, "PeerConnectionEnabled": False},
             f"production: both switches read back off ({production['switchesReadBack']})")
        for cid in ("ok-xdict", "ok-placeholder", "ok-link-nav"):
            broken = production["cases"].get(cid, {}).get("broken")
            rule(broken == [], f"production: allowed content works: {cid} (missing {broken})")

    baseline = runs.get("baseline")
    if baseline:
        caught = {k: sum(1 for v in baseline["cases"].values() if any(x.startswith(k) for x in v["leaks"]))
                  for k in ("http", "tcp", "udp", "dns")}
        rule(all(n > 0 for n in caught.values()),
             f"baseline: each observer caught WebKit itself with no layer on ({caught})")
        live = sum(1 for v in baseline["cases"].values() if v["liveInEntry"] or v["liveInResource"])
        rule(live > 0, f"baseline: {live} cases reached WebKit with a live target the rewriter did not see")

    for layer, probe in listed["probes"].items():
        on, off = runs.get(probe["run"]), runs.get(probe["against"])
        if not on or not off:
            rule(False, f"layer {layer}: run {probe['run']} or {probe['against']} missing")
            continue
        for cid in probe["cases"]:
            a, b = off["cases"][cid], on["cases"][cid]
            rule(a["left"] and not b["left"] and a["loaded"] and b["loaded"],
                 f"layer {layer}: {cid} leaves with it off ({probe['against']}: {'; '.join(a['leaks']) or 'nothing'}) "
                 f"and is refused with it on ({probe['run']}: {'; '.join(b['leaks']) or 'nothing'})")

    for verdict, text in verdicts:
        print(f"{verdict}  {text}")
    print()
    print(matrix(listed, runs))
    return 0 if all(v == "PASS" for v, _ in verdicts) else 1


def matrix(listed, runs):
    labels = [label for label in listed["runs"] if runs.get(label)]
    head = "| case | context | " + " | ".join(labels) + " |"
    rows = [head, "|" + "---|" * (len(labels) + 2)]
    for c in listed["cases"]:
        cells = []
        for label in labels:
            v = runs[label]["cases"].get(c["id"], {})
            cells.append("**LEFT** " + ",".join(sorted({x.split("×")[0].split(":")[0] for x in v["leaks"]}))
                         if v.get("left") else ("void" if not v.get("loaded") else "·"))
        rows.append(f"| {c['id']} | {c['context']} | " + " | ".join(cells) + " |")
    return "\n".join(rows)


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "runs" and len(sys.argv) == 3:
        print(" ".join(json.load(open(sys.argv[2]))["runs"]))
        return 0
    if command == "off" and len(sys.argv) == 4:
        listed = json.load(open(sys.argv[2]))
        print(",".join(layer for layer in listed["layers"] if layer not in listed["runs"][sys.argv[3]]))
        return 0
    if len(sys.argv) != 3 or command not in ("run", "suite", "reader", "verdicts", "faults", "binding", "entries"):
        print(__doc__, file=sys.stderr)
        return 2
    if command == "verdicts":
        return reader_verdicts(sys.argv[2])
    if command == "faults":
        return faults(sys.argv[2])
    if command == "binding":
        return binding(sys.argv[2])
    if command == "entries":
        return entries(sys.argv[2])
    if sys.argv[1] in ("run", "reader"):
        summary = (summarize if sys.argv[1] == "run" else reader)(sys.argv[2])
        print(json.dumps(summary, indent=1, ensure_ascii=False))
        return 0
    return suite(sys.argv[2])


if __name__ == "__main__":
    sys.exit(main())
