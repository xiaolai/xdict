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
#                     relaunches the owner's dictionaries. STAGES="launch" runs only those
#   make e2e-status   what each stage last did, on which build, of which source tree
#   make release BUILD_NUMBER=<n>
#                     a notarised, stapled DMG in .build/release, Gatekeeper-checked here and on the E2E Mac. Refuses
#                     unless every implemented stage last passed fresh on a development bundle of this very source tree,
#                     and unless that tree is committed
#   make release-bootstrap BUILD_NUMBER=<n>
#                     the same, requiring fresh evidence of the `launch` stage only (the skeleton's; plan-macos-v1 WI-2)
#   make clean        remove the bundle and its stage (not SwiftPM's or cargo's caches)

.NOTPARALLEL:
.DEFAULT_GOAL := app
.PHONY: app test test-swift core lint strings e2e e2e-status e2e-evidence e2e-evidence-bootstrap release \
	release-bootstrap clean

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
# The owner's 25 dictionaries, for the `entries` stage; unset, that stage fails as not measured.
E2E_CORPUS ?=

# Handed to the scripts through the environment, as data, never spliced into a shell command.
export XDICT_SIGN_ID := $(SIGN_ID)
export XDICT_BUILD_NUMBER := $(BUILD_NUMBER)
export XDICT_NOTARY_PROFILE := $(NOTARY_PROFILE)
export XDICT_E2E_HOST := $(E2E_HOST)
export XDICT_E2E_CORPUS := $(E2E_CORPUS)

app: lint test-swift
	@Tools/build-bundle.sh build

test: lint test-swift

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
e2e:
	@[ -n "$(E2E_HOST)" ] || { echo "E2E_HOST_MACOS is not set: put the E2E Mac's SSH name in $(REPO)/local.mk" >&2; exit 1; }
	@tree=$$(Tools/source-tree.sh) && $(MAKE) app && XDICT_E2E_TREE="$$tree" Tools/e2e.sh "$(E2E_HOST)" $(STAGES)

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
