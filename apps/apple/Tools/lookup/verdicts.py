#!/usr/bin/env python3
"""The hostile suite's production rules, held to the run through the app's own window (plan-macos-v1 WI-4's stamp,
re-measured at WI-6): the rules `Tools/hostile/analyze.py suite` holds the lab's `production` run to, over the summary
`analyze.py run` wrote for the app's run (`run-app-hostile.sh`).

    python3 -I verdicts.py hostile <run-dir>    one PASS or FAIL line per rule; exit 1 on any FAIL
"""
import json
import os
import sys


def hostile(d):
    path = os.path.join(d, "summary.json")
    if not os.path.exists(path):
        print("FAIL  app: no summary: the run did not happen")
        return 1
    s = json.load(open(path))
    report = json.load(open(os.path.join(d, "report.json")))
    verdicts = []

    def rule(ok, text):
        verdicts.append(("PASS" if ok else "FAIL", text))

    c = s["controls"]
    rule(c["http"] >= 1 and c["tcp"] >= 1 and c["udp"] >= 1 and c["dns"] >= 1 and c["dnsOracle"] == "ok",
         f"app: every observer caught its deliberate attempt (http={c['http']} tcp={c['tcp']} udp={c['udp']} "
         f"dns={c['dns']} oracle={'ok' if c['dnsOracle'] == 'ok' else c['dnsOracle']})")
    rule(not s["notReported"] and not s["notLoaded"],
         f"app: every case ran in the app's window and reported loaded ({len(s['cases'])} cases; not reported "
         f"{s['notReported'][:5] or 'none'}; not loaded {s['notLoaded'][:8] or 'none'})")
    shown = [cid for cid, v in report.get("cases", {}).items() if v.get("shown") is not True]
    rule(not shown, f"app: every case was reached by its key typed into the window's search and shown "
                    f"({len(report.get('cases', {})) - len(shown)} of {len(report.get('cases', {}))}; not: {shown[:8]})")
    rule(not s["stray"], f"app: no observer event outside the battery's ports ({len(s['stray'])})")
    rule(s["opened"] == [], f"app: nothing was opened in a browser ({s['opened']})")
    left = {cid: v["leaks"] for cid, v in s["cases"].items() if v["left"]}
    rule(not left, f"app: nothing left, on any observer, from any of {len(s['cases'])} cases "
                   f"({left if left else 'zero http, tcp, udp, dns, mdns'})")
    rule(not s["webkitOtherLookups"], f"app: no other lookup by the app's WebKit ({s['webkitOtherLookups'][:3]})")
    rule((s["confinement"] or {}).get("production") is True and not s["disabled"],
         "app: the confinement is the production one, nothing off")
    rule(s["switchesReadBack"] == {"LinkPreconnect": False, "PeerConnectionEnabled": False},
         f"app: both switches read back off ({s['switchesReadBack']})")
    for cid in ("ok-xdict", "ok-placeholder", "ok-link-nav"):
        broken = s["cases"].get(cid, {}).get("broken")
        rule(broken == [], f"app: allowed content works: {cid} (missing {broken})")
    for verdict, text in verdicts:
        print(f"{verdict}  {text}")
    return 0 if all(v == "PASS" for v, _ in verdicts) else 1


def main():
    if len(sys.argv) != 3 or sys.argv[1] != "hostile":
        print(__doc__, file=sys.stderr)
        return 2
    return hostile(sys.argv[2])


if __name__ == "__main__":
    sys.exit(main())
