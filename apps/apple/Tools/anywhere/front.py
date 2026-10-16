"""The E2E Mac's front, held for each host-app action of the anywhere driver (`drive.py`), as the lookup driver holds it
for its keys (`Tools/lookup/typing_check.py`).

The Mac is shared: another project's GUI tests (an XCTest run) take the front at any moment. A host action that times
out, or whose host would not come forward, is not XDict's failure and not a reason to leave every later check
unreported: the driver stops with `Stopped`, one sentence naming the front app and what it is doing, and `e2e.sh`
fails the checks it never reached once, under that sentence.
"""
import subprocess


class Stopped(Exception):
    pass


def who(front, processes):
    """The front app, and an XCTest run on the Mac if one is active (what takes the front from a GUI stage)."""
    name = front.get("name") or front.get("bundle") or "no app"
    sentence = f"the front is {name} ({front.get('bundle') or '?'}, pid {front.get('pid')})"
    runs = [p for p in processes if "xctest" in p.lower()]
    if runs:
        sentence += f", and an XCTest run is active on this Mac ({runs[0].strip()[:120]}): its tests hold the front"
    return sentence


def guarded(what, act, *, front, processes):
    """`act()`'s answer, unless it timed out or its host would not come forward: then `Stopped`, naming who has the
    front. `front()` is `hands front`'s answer; `processes()` the Mac's XCTest command lines."""
    try:
        answer = act()
    except subprocess.TimeoutExpired as late:
        raise Stopped(f"{what} timed out after {late.timeout:g} s; {who(front(), processes())}") from None
    if isinstance(answer, dict) and "would not come to the front" in str(answer.get("error", "")):
        raise Stopped(f"{what}: the host would not come forward; {who(front(), processes())}")
    return answer
