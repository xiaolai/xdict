#!/usr/bin/env python3
"""The UI tour can prepare only its named synthetic demonstrations, never arbitrary commands."""
import pathlib
import sys
import json
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "ui-tour"))
import demo  # noqa: E402
from routes import ROUTES  # noqa: E402

for name in ("meaning", "history", "review", "clean", "senseSelected"):
    assert demo.operation(name) == "uiDemo." + name
for invalid in ("run", "quit", "", "meaning;quit", "uiDemo.meaning", "../history"):
    try:
        demo.operation(invalid)
    except ValueError:
        pass
    else:
        raise AssertionError("unknown demo was accepted: " + invalid)

routes = {route[0]: route for route in ROUTES}
for route, command in (("main.meaningAnswer", "meaning"), ("history.populated", "history"),
                       ("review.populated", "review")):
    assert route in routes, "missing populated native capture route: " + route
    assert routes[route][1] == "full", "demonstrations require their isolated fixture library"
    assert ("demo", command) in routes[route][4]
with demo.answer_server() as endpoint:
    assert endpoint.startswith("http://127.0.0.1:")
    response = urllib.request.urlopen(urllib.request.Request(endpoint + "/chat/completions", data=b"{}"), timeout=2)
    outer = json.load(response)
    answer = json.loads(outer["choices"][0]["message"]["content"])
    assert answer["outcome"] == "matched" and answer["quotes"] == ["A round fruit"]
    assert outer["choices"][0]["finish_reason"] == "stop"
print("ui_demo_test: named synthetic routes and command refusal PASS")
