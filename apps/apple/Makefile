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
#   make e2e-affected [BASE=macos-v1]
#                     T1: the sub-stages the change since BASE needs (Tools/e2e-affected.sh), or nothing
#   make test-tools   the E2E plan's own tests: every check in one sub-stage, what a change selects (part of `test`)
#   make e2e-status   what each sub-stage last did, how long it took, on which build, of which source tree
#   make release BUILD_NUMBER=<n>
#                     a notarised, stapled DMG in .build/release, Gatekeeper-checked here and on the E2E Mac. Refuses
#                     unless every implemented stage last passed fresh on a development bundle of this very source tree,
#                     and unless that tree is committed
#   make release-bootstrap BUILD_NUMBER=<n>
#                     the same, requiring fresh evidence of the `launch` stage only (the skeleton's; plan-macos-v1 WI-2)
#   make clean        remove the bundle and its stage (not SwiftPM's or cargo's caches)

.NOTPARALLEL:
.DEFAULT_GOAL := app
.PHONY: app remote-build test test-swift test-tools core lint strings e2e e2e-quick e2e-affected e2e-status e2e-evidence \
	e2e-evidence-bootstrap release release-bootstrap clean

APPLE := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO := $(abspath $(APPLE)/../..)
# Machine-local settings, untracked: the E2E Mac's SSH name and the like. Absent is normal here; a missing host is loud
# where it is needed.
-include $(REPO)/local.mk

# Unset: the login keychain's Developer ID Application identity, which Tools/build-bundle.sh requires to be exactly one.
SIGN_ID ?=
# Empty for a development build, numbered from the clock. A release passes the release counter's value.
BUILD_NUMBER ?=
# The notarytool keychain profile: a name, never a credential (XiaolaiDict ADR-0026).
NOTARY_PROFILE ?= chase-notary
E2E_HOST ?= $(E2E_HOST_MACOS)
# Another Mac's SSH name to compile on; unset, this one compiles.
BUILD_HOST ?=
# The owner's 25 dictionaries, for the `entries` stage; unset, that stage fails as not measured.
E2E_CORPUS ?=

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
	@Tools/build-core.sh

# **A warning the compiler wrote down fails the build, whatever the compiler exited with**: `swift test` first, then
# every source's diagnostics file of the build it made (Tools/compiler-warnings.py). Both always run; either failing
# fails the target.
DIAGNOSTICS := .build/out/Intermediates.noindex/XDict.build/Debug
# The service's tests read `conformance/`'s fixtures and the slow ones (Tools/build-fixtures.sh), written by the core's
# own MDX writer: no dictionary content enters the repository.
test-swift: core
	Tools/build-fixtures.sh $(APPLE)/.build/fixtures
	swift test; status=$$?; python3 Tools/compiler-warnings.py $(DIAGNOSTICS) || status=1; exit $$status

# Correctness rules only (.swiftlint.yml says which and why). `--strict` because a warning nobody fails on is a warning
# nobody reads; the version is pinned because a new SwiftLint can add findings to a rule, and a gate that moves by
# itself is not a gate.
SWIFTLINT_VERSION := 0.65.1
lint:
	@command -v swiftlint >/dev/null || { echo "swiftlint not found: brew install swiftlint" >&2; exit 1; }
	@test "$$(swiftlint version)" = "$(SWIFTLINT_VERSION)" || \
	  { echo "swiftlint $$(swiftlint version); this gate is pinned to $(SWIFTLINT_VERSION)" >&2; exit 1; }
	swiftlint lint --strict --quiet

strings: core
	@Tools/strings.sh

# **The source tree is read before the bundle is built**, and the run holds it to what it finds when it starts and when
# it ends: an edit made while `app` built would otherwise be filed against a bundle that does not have it.
# **A bundle already built of this very tree is not built again** (`.build/XDict.app.source-tree`, written here once the
# tree is still the same after the build, removed by Tools/build-bundle.sh whenever it publishes another bundle): its
# lint, tests and build ran when it was made.
e2e:
	@[ -n "$(E2E_HOST)" ] || { echo "E2E_HOST_MACOS is not set: put the E2E Mac's SSH name in $(REPO)/local.mk" >&2; exit 1; }
	@tree=$$(Tools/source-tree.sh) && \
	if [ -d .build/XDict.app ] && [ "$$(cat .build/XDict.app.source-tree 2>/dev/null)" = "$$tree" ]; then \
	  echo "e2e: .build/XDict.app is built of this tree already; not building it again"; \
	else \
	  $(MAKE) app && { [ "$$(Tools/source-tree.sh)" != "$$tree" ] || echo "$$tree" >.build/XDict.app.source-tree; }; \
	fi && \
	XDICT_E2E_TREE="$$tree" XDICT_E2E_ONLY="$(E2E_ONLY)" XDICT_E2E_FAILFAST="$(E2E_FAILFAST)" \
	  Tools/e2e.sh "$(E2E_HOST)" $(STAGES)

# T0: the sub-stages named, stopping at the first that fails.
e2e-quick:
	@[ -n "$(STAGES)" ] || { echo "e2e-quick: name the sub-stages, STAGES=\"hostile.production lookup.core\"" >&2; exit 1; }
	@$(MAKE) e2e E2E_FAILFAST=1

# T1: the sub-stages the change since BASE needs (Tools/e2e-affected.map); nothing when it needs none.
BASE ?= macos-v1
e2e-affected:
	@stages=$$(Tools/e2e-affected.sh "$(BASE)" | tr '\n' ' ') || exit 1; \
	if [ -z "$$stages" ]; then echo "e2e-affected: the change since $(BASE) needs no end-to-end sub-stage"; \
	else echo "e2e-affected: since $(BASE): $$stages"; $(MAKE) e2e STAGES="$$stages"; fi

# The E2E plan's own tests (Tools/tests/e2e-plan-test.sh): what the sub-stages own and what a change selects.
test-tools:
	@Tools/tests/e2e-plan-test.sh
	@Tools/tests/remote-build-test.sh
	@Tools/tests/core-on-host-test.sh
	@python3 -I Tools/tests/hostile_test.py
	@python3 -I Tools/tests/anywhere_test.py

e2e-status:
	@Tools/e2e-status.sh show

# The evidence a release needs, asked before its tests so a missing run costs seconds; Tools/release.sh asks again
# after its build, before anything is uploaded.
e2e-evidence:
	@Tools/e2e-status.sh require-fresh

e2e-evidence-bootstrap:
	@Tools/e2e-status.sh require-fresh --bootstrap

release: e2e-evidence lint test-swift
	@Tools/release.sh

release-bootstrap: e2e-evidence-bootstrap lint test-swift
	@Tools/release.sh --bootstrap

clean:
	@Tools/build-bundle.sh clean
