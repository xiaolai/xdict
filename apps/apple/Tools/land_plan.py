#!/usr/bin/env python3
"""Places each landing gate on a fit host and splits a host's gates into its two lanes.

    python3 -I Tools/land_plan.py <todo> <hosts> <e2e-build-host>

`todo` is one gate name a line; `hosts` is `host<TAB>capability,...` from the probe. The output is
`gates<TAB>host<TAB>lane` lines, `host` `-` for a gate no host fits.

Each gate goes to the most constrained fit host, the E2E bundle's build Mac last, so the rare capabilities
stay free. A host runs two lanes in copies of their own: `make test` beside the cargo gates, which run in turn
(they share one target folder, whose cargo lock would only queue them). **The lookup corpus reads the biggest
dictionary (OED, 706k keys), and beside `make test` its memory pressure had macOS kill the WebKit lab's
processes mid-suite** (2026-10-24: 75 failures that all pass alone): where a host runs both, the corpus goes
into the Swift lane after `make test`, so the two never overlap.

The tests are `Tools/tests/land_plan_test.py` (in `make test-tools`).
"""

import sys


def main() -> int:
    if len(sys.argv) != 4:
        print(f"usage: {sys.argv[0]} <todo> <hosts> <e2e-build-host>", file=sys.stderr)
        return 2
    todo = [line.split("\t")[0] for line in open(sys.argv[1], encoding="utf-8").read().splitlines() if line]
    hosts = {}
    for line in open(sys.argv[2], encoding="utf-8").read().splitlines():
        host, caps = line.split("\t")
        hosts[host] = set(cap.split("=")[0] for cap in caps.split(","))
    e2e_build = sys.argv[3]
    need = {
        "core": {"rust"},
        "apple-test": {"rust", "xcode"},
        "entries": {"rust", "corpus"},
        "lookup-corpus": {"rust", "corpus"},
        "mdx-v3": {"rust"},
        "bindings": {"rust", "run1"},
        "memory": {"rust", "run1"},
    }
    unknown = sorted(set(todo) - set(need))
    if unknown:
        print(f"land_plan: no rule for {', '.join(unknown)}: a new gate needs its capabilities named here", file=sys.stderr)
        return 1
    fit = {gate: [host for host in hosts if need[gate] <= hosts[host]] for gate in todo}
    jobs = {}
    for gate in sorted(todo, key=lambda gate: len(fit[gate])):
        if not fit[gate]:
            print(f"{gate}\t-")
            continue
        # Prefer a free host with the fewest capabilities, so the rare ones stay free; the E2E build Mac last.
        free = sorted(fit[gate], key=lambda host: (len(jobs.get(host, [])), host == e2e_build, len(hosts[host])))
        jobs.setdefault(free[0], []).append(gate)
    for host, gates in jobs.items():
        swift = [gate for gate in gates if gate == "apple-test"]
        cargo = [gate for gate in gates if gate != "apple-test"]
        if "lookup-corpus" in cargo and swift:
            cargo.remove("lookup-corpus")
            swift.append("lookup-corpus")
        for lane, part in (("swift", swift), ("cargo", cargo)):
            if part:
                print(f"{' '.join(part)}\t{host}\t{lane}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
