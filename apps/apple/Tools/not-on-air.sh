#!/bin/bash
# **Nothing compiles or tests on the Air** (owner, 2026-10-15: the Air is where the owner works). Run first by every
# target that compiles or tests here (lint, core, test-swift, test-tools, strings); refuses, loudly, on a MacBook Air,
# whatever local.mk says or lacks: a worktree has no local.mk, and its empty BUILD_HOST once fell back to building and
# testing on the Air (2026-10-18). On the Air, `make app`, `make land` and the gallery send the work to BUILD_HOST.
# XDICT_HW_MODEL stands in for the model's name in Tools/tests/not-on-air-test.sh.
model=${XDICT_HW_MODEL:-$(system_profiler SPHardwareDataType 2>/dev/null | sed -n 's/^ *Model Name: //p')}
case $model in
    *MacBookAir* | *"MacBook Air"*)
        echo "not-on-air: this is an Air ($model): builds and tests run on BUILD_HOST (local.mk), never here" >&2
        exit 2 ;;
esac
