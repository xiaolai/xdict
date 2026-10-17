#!/bin/bash
# **Renders are off by default for agents** (owner, 2026-10-18: "改点什么，这就跑一遍，太耽误时间了"). The gallery
# (Tools/gallery/hot.sh, run.sh) and the UI tour (Tools/ui-tour/run.sh) open windows on the E2E Mac; from an agent's
# shell (CLAUDECODE=1) they need XDICT_RENDER_REQUESTED=1, which the orchestrator sets once per landing batch, never an
# implementation agent. Agents prove a change with tests. The owner's own terminal is never stopped. Sourced first by
# those scripts; run alone by Tools/tests/render-requested-test.sh.
if [ "${CLAUDECODE:-}" = 1 ] && [ "${XDICT_RENDER_REQUESTED:-}" != 1 ]; then
    echo "render: renders are off by default; agents prove a change with tests, and the orchestrator renders once per" >&2
    echo "render: landing batch (XDICT_RENDER_REQUESTED=1)." >&2
    exit 2
fi
