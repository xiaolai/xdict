"""Compares one binding's style report with the core's, field by field (style-report-parity.sh).

Usage: compare.py <binding name> <core expected.json> <binding output.json> [plant]
`plant` alters the binding's output before comparing (its size count raised by one): the check's positive control.
Prints every differing field by its path; exits 1 when any differs, 0 when all agree.
"""
import json
import sys


def differences(core, got, path):
    if isinstance(core, dict) and isinstance(got, dict):
        for key in sorted(set(core) | set(got)):
            if key not in got:
                yield f"{path}.{key}: missing from the binding"
            elif key not in core:
                yield f"{path}.{key}: not in the core's report"
            else:
                yield from differences(core[key], got[key], f"{path}.{key}")
    elif isinstance(core, list) and isinstance(got, list):
        if len(core) != len(got):
            yield f"{path}: {len(core)} items in the core's, {len(got)} in the binding's"
        for i, (a, b) in enumerate(zip(core, got)):
            yield from differences(a, b, f"{path}[{i}]")
    elif type(core) in (int, float) and type(got) in (int, float) and not isinstance(core, bool):
        if float(core) != float(got):
            yield f"{path}: core {core!r}, binding {got!r}"
    elif core != got:
        yield f"{path}: core {core!r}, binding {got!r}"


def main():
    name, expected, output = sys.argv[1:4]
    plant = len(sys.argv) > 4 and sys.argv[4] == "plant"
    with open(expected, encoding="utf-8") as f:
        core = json.load(f)
    with open(output, encoding="utf-8") as f:
        got = json.load(f)
    if plant:
        got["changes"]["size"] += 1
    found = list(differences(core, got, "readingStyle"))
    fields = sum(1 for _ in leaves(core))
    for line in found:
        print(f"{name}: {line}")
    if found:
        print(f"{name}: FAIL, {len(found)} of {fields} fields differ")
        sys.exit(1)
    print(f"{name}: pass, {fields} fields identical to the core's")


def leaves(value):
    if isinstance(value, dict):
        for v in value.values():
            yield from leaves(v)
    elif isinstance(value, list):
        for v in value:
            yield from leaves(v)
    else:
        yield value


main()
