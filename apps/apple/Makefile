# XDict for macOS — the menu. Adapted from XiaolaiDict's Makefile. The core is built by cargo first (Tools/build-core.sh);
# code and tests live in SwiftPM; the bundle transaction lives in Tools/build-bundle.sh.
#
#   make / make app   the core, lint, swift test and the warnings gate, then .build/XDict.app built, signed with the
#                     login keychain's Developer ID and verified. Never launched here: the build Mac's screen is the
#                     owner's (2026-10-14), so the app runs, and its service answers the handshake, on the E2E Mac only
#   make test         the core, lint, swift test and the warnings gate
#   make core         libxdict_ffi.a and its Swift binding into Generated/ (untracked)
#   make lint         SwiftLint's correctness rules, --strict, at the pinned version
#   make strings      re-extract every localizable string into Strings/Localizable.xcstrings
#   make e2e          make app, then the end-to-end stages on the E2E Mac (E2E_HOST_MACOS in the repository's local.mk);
#                     `launch` asks the bundle's service for the handshake there; `service` runs the contract's
#                     instruments against the signed service there; `hostile`, `reader` and `entries` run the entry
#                     view (Tools/build-lab.sh's kit): the hostile-input suite, a person's hands on it, and the owner's
#                     dictionaries (E2E_CORPUS in local.mk); `library` imports the core's generated packages through
#                     the app's library, drops one on its window by real pointer events, and registers, moves and
#                     relaunches the owner's dictionaries; `lookup` drives the real app's main window by key events
#                     alone, reads it as VoiceOver does, and runs the main window's scenario through it (`hostile` and
#                     `entries` also run their checks through the app's own window); `sound` plays and speaks, at volume
#                     0, through a main window: a `.tts` link, the speak button, the accent, a Chinese dictionary, the
#                     notices for missing, Speex and undecodable recordings, and every format the 25 hold. T2: with no
#                     STAGES, every default sub-stage (Tools/e2e-substages.txt), the controls among them. STAGES="hostile lookup.paging"
#                     runs only those (a stage means its default sub-stages; `all` adds the extra ones);
#                     E2E_ONLY=<check>[,<check>] only the sub-stages owning those checks, and records nothing;
#                     E2E_FAILFAST=1 stops at the first failed sub-stage. A bundle built of this tree is not rebuilt,
#                     and is not copied again when the E2E Mac has it
#   make e2e-quick STAGES=<sub-stages>
#                     T0: those sub-stages, fail-fast
#   make e2e-affected T1: the same as `make e2e`, whose default is now only the sub-stages with no pass for their
#                     current key in the E2E ledger (Tools/e2e-run.sh); FULL=1 all of them, STAGES=… those, forced
#   make e2e RELEASE_NEEDED=1
#                     exactly the sub-stages `make release-plan` says must run
#   make release-plan what a release would carry from the ledger and what it must run, and why, with the minutes
#   make e2e-ledger [N=30] [STAGE=<sub-stage or stage>]
#                     what ran when: the ledger's last N rows (~/.local/share/xdict/e2e-ledger.tsv)
#   make land         every gate the tree needs, in parallel on the build Macs, cached (Tools/land.sh); ends with what
#                     E2E and renders are pending, running neither
#   make render-pending [BASE=<ref>] [FULL=1]
#                     the pictures and UI-tour routes the change since BASE needs, less those whose render key passed
#                     (Tools/gallery/render_affected.py, render-affected.map), rendering nothing
#   make render-affected [BASE=<ref>] [FULL=1]
#                     renders exactly that (an agent: only with XDICT_RENDER_REQUESTED=1, on the owner's yes)
#   make test-tools   the E2E plan's own tests: every check in one sub-stage, what a change selects (part of `test`);
#                     and the icon sets held to their source (Tools/tests/icons-test.sh), and the style ledger
#                     (Tools/gallery/style-ledger.tsv) held to its guards and commits by Tools/gallery/ledger.py check
#   make icons        every platform's icon set regenerated from Resources/XDict.icon into apps/*/icons/ (BUILD_HOST)
#   make affected-graph [PATHS=<path...>] [BASE=<ref>]
#                     the picture of what a change reaches (file -> crate/target -> gate/sub-stage), with PATHS or the
#                     change since BASE (default macos-v1) lit: dev-docs/artifacts/affected/index.html, opened
#   make affected-graph-update
#                     rewrite Tools/affected-graph.json from cargo metadata and Package.swift (a build Mac: needs cargo
#                     and swift); `make test` fails while it is stale
#   make e2e-status   the same as make e2e-ledger
#   make release BUILD_NUMBER=<n>
#                     a notarised, stapled DMG in .build/release, Gatekeeper-checked here and on the E2E Mac. Refuses
#                     unless the ledger carries every default sub-stage and RELEASE_EXTRAS by its key for this tree
#                     (passed last on that key, within E2E_EVIDENCE_MAX_DAYS, default 14), and unless the tree is
#                     committed; then runs RELEASE_SMOKE (Tools/e2e-status.sh) on the release-signed bundle whatever
#   make release-bootstrap BUILD_NUMBER=<n>
#                     the same, requiring evidence of the `launch` stage only (the skeleton's; plan-macos-v1 WI-2)
#   make clean        remove the bundle and its stage (not SwiftPM's or cargo's caches)
#   make clean-dev [APPLY=1] [ARGS="--air|--build-host --into <branch> --min-age-hours <n>"]
#                     what agents left on this Mac (merged git worktrees) and on BUILD_HOST (~/xdict-build copies):
#                     a dry run with a table of what and why; APPLY=1 removes it (Tools/clean-dev.sh)

.NOTPARALLEL:
.DEFAULT_GOAL := app
.PHONY: app remote-build test test-swift test-tools icons core lint strings e2e e2e-quick e2e-affected e2e-pending land render-pending render-affected affected-graph affected-graph-update e2e-status e2e-evidence \
	e2e-evidence-bootstrap e2e-ledger release-plan release release-bootstrap clean clean-dev

APPLE := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO := $(abspath $(APPLE)/../..)
# Machine-local settings, untracked: the E2E Mac's SSH name and the like. Absent is normal here; a missing host is loud
# where it is needed.
# A worktree has none of its own: the main checkout's is read, as Tools/ui-tour/run.sh and Tools/gallery/lab.sh read it.
# Without it `make app` in a worktree compiled and ran `swift test` on this Mac, windows and all (2026-10-18).
LOCAL_MK := $(firstword $(wildcard $(REPO)/local.mk) \
  $(wildcard $(abspath $(shell git -C $(REPO) rev-parse --git-common-dir 2>/dev/null)/..)/local.mk))
-include $(LOCAL_MK)

# Unset: the login keychain's Developer ID Application identity, which Tools/build-bundle.sh requires to be exactly one.
SIGN_ID ?=
# Empty for a development build, numbered from the clock. A release passes the release counter's value.
BUILD_NUMBER ?=
# The notarytool keychain profile: a name, never a credential (XiaolaiDict ADR-0026).
NOTARY_PROFILE ?= chase-notary
E2E_HOST ?= $(E2E_HOST_MACOS)
# Another Mac's SSH name to compile on; unset, this one compiles.
BUILD_HOST ?=
# The owner's dictionaries (the 24), for the corpus sub-stages; unset, they fail as not measured. Defaults to
# $HOME/xdict-corpus/the24 where that exists, an absolute path (a `~` in it once reached a host unexpanded).
E2E_CORPUS ?= $(wildcard $(HOME)/xdict-corpus/the24)

# Handed to the scripts through the environment, as data, never spliced into a shell command.
export XDICT_SIGN_ID := $(SIGN_ID)
export XDICT_BUILD_NUMBER := $(BUILD_NUMBER)
export XDICT_NOTARY_PROFILE := $(NOTARY_PROFILE)
export XDICT_E2E_HOST := $(E2E_HOST)
export XDICT_E2E_CORPUS := $(E2E_CORPUS)
# The E2E run's cargo work goes there too (Tools/core-on-host.sh), on its copy of the corpus.
BUILD_CORPUS ?=
export XDICT_BUILD_HOST := $(BUILD_HOST)
export XDICT_BUILD_CORPUS := $(BUILD_CORPUS)
ifneq ($(BUILD_HOST),)
export XDICT_REMOTE_PRODUCTS := $(APPLE)/.build/remote-products
endif

# BUILD_HOST (local.mk): the lint, tests and release build run there (Tools/remote-build.sh); this Mac assembles and
# signs what comes back. Unset: everything here, as before.
app: $(if $(BUILD_HOST),remote-build,lint test-swift)
	@Tools/build-bundle.sh build

remote-build:
	@Tools/remote-build.sh "$(BUILD_HOST)"

test: lint test-tools test-swift

core:
	@Tools/not-on-air.sh
	@Tools/build-core.sh

# **A warning the compiler wrote down fails the build, whatever the compiler exited with**: `swift test` first, then
# every source's diagnostics file of the build it made (Tools/compiler-warnings.py). Both always run; either failing
# fails the target.
DIAGNOSTICS := .build/out/Intermediates.noindex/XDict.build/Debug
# The service's tests read `conformance/`'s fixtures and the slow ones (Tools/build-fixtures.sh), written by the core's
# own MDX writer: no dictionary content enters the repository.
test-swift: core
	@Tools/not-on-air.sh
	Tools/build-fixtures.sh $(APPLE)/.build/fixtures
	swift test; status=$$?; python3 Tools/compiler-warnings.py $(DIAGNOSTICS) || status=1; exit $$status

# Correctness rules only (.swiftlint.yml says which and why). `--strict` because a warning nobody fails on is a warning
# nobody reads; the version is pinned because a new SwiftLint can add findings to a rule, and a gate that moves by
# itself is not a gate.
SWIFTLINT_VERSION := 0.65.1
lint:
	@Tools/not-on-air.sh
	@command -v swiftlint >/dev/null || { echo "swiftlint not found: brew install swiftlint" >&2; exit 1; }
	@test "$$(swiftlint version)" = "$(SWIFTLINT_VERSION)" || \
	  { echo "swiftlint $$(swiftlint version); this gate is pinned to $(SWIFTLINT_VERSION)" >&2; exit 1; }
	swiftlint lint --strict --quiet

strings: core
	@Tools/not-on-air.sh
	@Tools/strings.sh

# **The source tree is read before the bundle is built**, and the run holds it to what it finds when it starts and when
# it ends: an edit made while `app` built would otherwise be filed against a bundle that does not have it.
# **A bundle already built of this very tree is not built again** (`.build/XDict.app.source-tree`, written here once the
# tree is still the same after the build, removed by Tools/build-bundle.sh whenever it publishes another bundle): its
# lint, tests and build ran when it was made.
# **Only what changed since its last pass runs** (Tools/e2e-run.sh select, by Tools/gate-cache.py): nothing at all, and
# no bundle built, when nothing did. STAGES=<names> forces those; FULL=1 every default sub-stage; RELEASE_NEEDED=1 what a
# release cannot carry from the ledger. The run is split over both E2E Macs (E2E_HOST_MACOS, E2E_HOST_MACOS_2) unless
# E2E_SPLIT=0 or E2E_HOST is given. **Its rows are keyed with what the bundle names itself** (Provenance.txt, written by
# its build: its tree and toolchain; Tools/build-bundle.sh).
E2E_SPLIT ?= $(if $(filter command line,$(origin E2E_HOST)),0,1)
FULL ?=
export XDICT_E2E_HOST_2 := $(E2E_HOST_MACOS_2)
export XDICT_E2E_SPLIT := $(E2E_SPLIT)
export XDICT_E2E_STAGES := $(STAGES)
export XDICT_E2E_FULL := $(FULL)
RELEASE_NEEDED ?=
export XDICT_E2E_RELEASE_NEEDED := $(RELEASE_NEEDED)
e2e:
	@[ -n "$(E2E_HOST)" ] || { echo "E2E_HOST_MACOS is not set: put the E2E Mac's SSH name in $(REPO)/local.mk" >&2; exit 1; }
	@stages=$$(Tools/e2e-run.sh select) || exit 1; stages=$$(echo $$stages); \
	if [ -z "$$stages" ]; then echo "e2e: every sub-stage is unchanged since its last pass; nothing to run (FULL=1 runs them all)"; exit 0; fi; \
	Tools/e2e.sh --drivers $$stages || exit 1; \
	tree=$$(Tools/source-tree.sh) && \
	if [ -d .build/XDict.app ] && [ "$$(cat .build/XDict.app.source-tree 2>/dev/null)" = "$$tree" ]; then \
	  echo "e2e: .build/XDict.app is built of this tree already; not building it again"; \
	else \
	  $(MAKE) app && { [ "$$(Tools/source-tree.sh)" != "$$tree" ] || echo "$$tree" >.build/XDict.app.source-tree; }; \
	fi && \
	XDICT_E2E_TREE="$$tree" XDICT_E2E_ONLY="$(E2E_ONLY)" XDICT_E2E_FAILFAST="$(E2E_FAILFAST)" \
	  Tools/e2e-run.sh run $$stages

# T0: the sub-stages named, stopping at the first that fails.
e2e-quick:
	@[ -n "$(STAGES)" ] || { echo "e2e-quick: name the sub-stages, STAGES=\"hostile.production lookup.core\"" >&2; exit 1; }
	@$(MAKE) e2e E2E_FAILFAST=1

# T1: now the same as `make e2e`: what changed since each sub-stage's last pass (BASE is no longer read).
e2e-affected:
	@$(MAKE) e2e

# **E2E runs only on the owner's demand** (2026-10-17): what `make e2e` would run, and why, running nothing.
e2e-pending:
	@Tools/e2e-run.sh pending

# Every gate the tree needs, in parallel on the build Macs, cached; no E2E, only the line of what is pending.
land:
	@Tools/land.sh

# **Renders only as permitted** (owner, 2026-10-18): what a change needs pictured, and why, rendering nothing
# (Tools/gallery/render_affected.py, render-affected.map); FULL=1 the whole gallery (288). `render-affected` renders
# exactly that, and from an agent's shell only with XDICT_RENDER_REQUESTED=1, set by the orchestrator on the owner's yes.
render-pending:
	@python3 -I Tools/gallery/render_affected.py pending $(if $(filter command line environment,$(origin BASE)),--base "$(BASE)") $(if $(filter 1,$(FULL)),--full)

render-affected:
	@Tools/gallery/render-affected.sh $(if $(filter command line environment,$(origin BASE)),--base "$(BASE)") $(if $(filter 1,$(FULL)),--full)

# What a change reaches, drawn (Tools/affected_graph.py; no request leaves the page).
BASE ?= macos-v1
affected-graph:
	@out=$$(python3 -I Tools/affected_graph.py html --base "$(BASE)" $(PATHS)) && open "$$out" && echo "$$out"

affected-graph-update:
	@python3 -I Tools/affected_graph.py generate

# The E2E plan's own tests (Tools/tests/e2e-plan-test.sh): what the sub-stages own and what a change selects; the
# WI-10 measurement's arithmetic; every linked crate and bundled font with its notice (Tools/notices.py, needs cargo).
test-tools:
	@Tools/not-on-air.sh
	@python3 -I Tools/tests/ui_demo_test.py
	@python3 -I Tools/tests/ui_tour_registry_test.py
	@python3 -I Tools/tests/ui_tour_visibility_test.py
	@Tools/tests/e2e-plan-test.sh
	@python3 -I Tools/tests/land_plan_test.py
	@Tools/tests/e2e-requested-test.sh
	@python3 -I Tools/tests/e2e_harness_test.py
	@Tools/tests/not-on-air-test.sh
	@Tools/tests/expand-entitlements-test.sh
	@Tools/tests/render-requested-test.sh
	@Tools/tests/affected-graph-test.sh
	@Tools/tests/remote-build-test.sh
	@Tools/tests/lab-test.sh
	@Tools/tests/development-lab-test.sh
	@Tools/tests/core-on-host-test.sh
	@Tools/tests/gate-cache-test.sh
	@Tools/tests/e2e-ledger-test.sh
	@python3 -I Tools/tests/e2e_deps_test.py
	@Tools/tests/e2e-drivers-test.sh
	@Tools/tests/e2e-run-test.sh
	@Tools/tests/main-checkout-test.sh
	@Tools/tests/land-test.sh
	@Tools/tests/clean-dev-test.sh
	@Tools/tests/on-demand-test.sh
	@python3 -I Tools/tests/hostile_test.py
	@python3 -I Tools/tests/anywhere_test.py
	@python3 -I Tools/tests/lookup_typing_test.py
	@python3 -I Tools/tests/compiler_warnings_test.py
	@python3 -I Tools/tests/lookup_checks_test.py
	@python3 -I Tools/tests/measure_test.py
	@python3 -I Tools/tests/ui_tour_test.py
	@python3 -I Tools/tests/ledger_test.py
	@python3 -I Tools/tests/render_affected_test.py
	@python3 -I Tools/tests/render_history_test.py
	@python3 -I Tools/tests/tokens_test.py
	@python3 -I Tools/tokens.py gen --check
	@python3 -I Tools/tokens.py check
	@python3 -I Tools/gallery/ledger.py check $(if $(XDICT_KNOWN_COMMITS),--known-commits $(XDICT_KNOWN_COMMITS))
	@Tools/tests/notices-test.sh
	@Tools/tests/icons-test.sh

# Every platform's icon set from Resources/XDict.icon and Resources/MenuBarIcon.svg (Tools/icons/README.md), written
# into apps/*/icons/, on BUILD_HOST: the generator compiles Swift and rasterises, which the Air never does. **Unset is
# refused, not run here**: a worktree has no local.mk, and a quiet fallback once ran it on the Air. On a build Mac
# itself, run `Tools/icons.sh generate`.
icons:
	@[ -n "$(BUILD_HOST)" ] || { echo "icons: BUILD_HOST is not set (local.mk, or BUILD_HOST=<build Mac>); on a build Mac run Tools/icons.sh generate" >&2; exit 1; }
	@Tools/icons.sh remote "$(BUILD_HOST)"

N ?= 30
STAGE ?=
e2e-status e2e-ledger:
	@E2E_LEDGER_LAST="$(N)" E2E_LEDGER_STAGE="$(STAGE)" Tools/e2e-status.sh show

release-plan:
	@Tools/e2e-status.sh plan

# An on-demand read of the E2E evidence a release would carry. **No step requires it**: E2E is on demand (owner,
# 2026-10-24), and a release's own gate is the smoke on its stapled bundle in Tools/release.sh.
e2e-evidence:
	@Tools/e2e-status.sh require-fresh

e2e-evidence-bootstrap:
	@Tools/e2e-status.sh require-fresh --bootstrap

# **Built where `app` builds** (BUILD_HOST: Tools/remote-build.sh, whose products Tools/build-bundle.sh requires to be of
# this very tree), never compiled on this Mac when a build host is set; without one, here, with the notices check too.
RELEASE_BUILD := $(if $(BUILD_HOST),remote-build,lint test-tools test-swift)
release: $(RELEASE_BUILD)
	@Tools/release.sh

release-bootstrap: $(RELEASE_BUILD)
	@Tools/release.sh --bootstrap

clean:
	@Tools/build-bundle.sh clean

# A dry run unless APPLY=1. Runs on this Mac (it builds nothing) and reaches BUILD_HOST over one ssh.
APPLY ?=
ARGS ?=
clean-dev:
	@Tools/clean-dev.sh $(if $(APPLY),--apply) $(ARGS)
