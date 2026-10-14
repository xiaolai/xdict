#!/usr/bin/env python3
"""The DNS observer's key (adapted from spike 3's, 2026-10-14). mDNSResponder logs every query rootlessly but redacts
the name to a hash (`<dn:XXXXXX>`), the same hash for the same name in any process (measured in spike 3). So after a
run this asks each of the battery's names once itself, and the analysis learns each name's hash from this process's
own log lines; any other process's line with that hash is a lookup of that name.

    python3 -I dns_oracle.py --cases cases.json  > oracle.json

The names end in `.invalid`: mDNSResponder answers them itself and sends nothing upstream (spike 3, measured).
"""
import argparse
import json
import os
import socket
import time

ap = argparse.ArgumentParser()
ap.add_argument("--cases", required=True)
a = ap.parse_args()
listed = json.load(open(a.cases, encoding="utf-8"))
names = [listed["selftestName"]] + [n for c in listed["cases"] for n in c["names"]] + listed["reader"]["names"]
asked = []
for name in names:
    t0 = time.time()
    try:
        socket.getaddrinfo(name, 80, proto=socket.IPPROTO_TCP)
        answer = "resolved"
    except socket.gaierror as e:
        answer = f"gaierror {e.errno}"
    asked.append({"name": name, "t0": t0, "t1": time.time(), "answer": answer})
    time.sleep(0.3)
print(json.dumps({"pid": os.getpid(), "asked": asked}, indent=1))
