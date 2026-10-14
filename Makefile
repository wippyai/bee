# Bee build protocol. Every step is pinned by wippy.build.json (runtime module
# and version) and BUILDER_VERSION. Release CI uses the checked adapter below.
#
#   make tools     install wippy-builder and build the matching wippy toolchain
#   make check     lint, fixture lint, boot checks and the sharded Lua suites
#   make lint      lint application and fixture source with that toolchain
#   make test      run the Lua suites in tests/ against the application source
#   make build     pack the application, record its checksum, build dist/bee
#   make install   install dist/bee as ~/.local/bin/bee (previous kept as bee.prev)
#   make runtime-pin RUNTIME_VERSION=<commit>  pin the release build to one runtime commit
#   make native-pin NATIVE_VERSION=<commit>    pin the release build's native module to one pushed Bee commit
#
# RUNTIME_SOURCE=<path to a local runtime checkout> builds against that
# checkout's HEAD for unreleased runtime branches, and against this
# repository's HEAD for the native host: the build reads a local manifest
# pinned to those commits, and Go fetches both modules from the local
# checkouts through git URL rewrites scoped to the build's processes.

BUILDER_VERSION ?= 0c58e22a3f242b183298872e770e406d111d3242
SHELL := /bin/bash
.SHELLFLAGS := -eo pipefail -c
VERSION ?= 0.2.0-dev
BIN := .wippy/bin
BUILDER := $(BIN)/wippy-builder
WIPPY := $(BIN)/wippy
INSTALL_DIR ?= $(HOME)/.local/bin

MANIFEST := wippy.build.json

export GOWORK := off
export GOTOOLCHAIN := go$(shell python3 -c 'import json; print(json.load(open("wippy.build.json"))["runtime"]["go"])')
export TMPDIR := $(abspath .wippy/tmp)
$(shell mkdir -p .wippy/tmp)

ifdef RUNTIME_SOURCE
MANIFEST := wippy.build.local.json
export GONOSUMDB := github.com/wippyai/runtime,github.com/wippyai/bee
export GOPRIVATE := github.com/wippyai/runtime,github.com/wippyai/bee
export GIT_CONFIG_COUNT := 2
export GIT_CONFIG_KEY_0 := url.file://$(abspath $(RUNTIME_SOURCE)).insteadOf
export GIT_CONFIG_VALUE_0 := https://github.com/wippyai/runtime
export GIT_CONFIG_KEY_1 := url.file://$(abspath .).insteadOf
export GIT_CONFIG_VALUE_1 := https://github.com/wippyai/bee
$(shell python3 build/local_manifest.py $(RUNTIME_SOURCE) .)
endif

CACHE_ROOT := $(if $(XDG_CACHE_HOME),$(XDG_CACHE_HOME),$(HOME)/.cache)
LUA_CACHE ?= $(CACHE_ROOT)/bee-lua/$(shell python3 build/tools.py --manifest $(MANIFEST) --builder $(BUILDER_VERSION) --key)
LINT_FLAGS := --memory-limit 1G --set lua.cache.dir=$(LUA_CACHE)

.PHONY: tools-key check boot-check fixture-lint agent-corpus-local agent-corpus-check tools runtime-pin native-pin compose lint test build release-pack install binary-identity hub-publish release-build-check

tools:
	python3 build/tools.py --manifest $(MANIFEST) --builder $(BUILDER_VERSION) --bin $(BIN)

tools-key:
	@python3 build/tools.py --manifest $(MANIFEST) --builder $(BUILDER_VERSION) --key

builder-version:
	@printf '%s\n' '$(BUILDER_VERSION)'

$(BUILDER) $(WIPPY): | tools

# runtime-pin moves the release build to one runtime commit: the manifest's
# runtime version and the native module's runtime requirement together.
runtime-pin:
	@test -n "$(RUNTIME_VERSION)" || { echo "set RUNTIME_VERSION=<runtime commit>"; exit 2; }
	python3 build/runtime_pin.py $(RUNTIME_VERSION)
	cd native && GOFLAGS=-mod=mod go get github.com/wippyai/runtime@$(RUNTIME_VERSION) && go mod tidy

# native-pin moves the release build's native module to one pushed Bee commit
# that holds the native packages the manifest names.
native-pin:
	@test -n "$(NATIVE_VERSION)" || { echo "set NATIVE_VERSION=<pushed bee commit>"; exit 2; }
	python3 build/native_pin.py $(NATIVE_VERSION)

# tests/compose.py writes the copy of src the suites load, with their
# test-only seams; it never changes src or a pack.
compose: binary-identity
	python3 tests/compose.py

binary-identity: tools
	python3 build/binary_identity.py --manifest $(MANIFEST) --toolchain $(WIPPY) --version $(VERSION) $(if $(REVISION),--revision $(REVISION))

release-build-check:
	python3 build/binary_identity_test.py
	python3 build/release_contract_test.py
	python3 build/ci_contract_test.py
	python3 build/hub_publish_test.py

hub-publish:
	python3 build/hub_publish.py --version "$(VERSION)" --wippy "$(abspath $(WIPPY))"

agent-corpus-local:
	python3 tools/corpus.py

agent-corpus-check:
	python3 tools/corpus.py --check

fixture-lint: compose
	cd tests && python3 locked.py exclusive .wippy/composition.lock $(abspath $(WIPPY)) install && python3 locked.py shared .wippy/composition.lock $(abspath $(WIPPY)) lint $(LINT_FLAGS)

lint: binary-identity fixture-lint
	python3 tools/corpus.py --check
	$(WIPPY) lint $(LINT_FLAGS)

check:
	+python3 tests/check.py

# The tests workspace loads bee/bee from the composed copy of src through its
# workspace replacement, so suites never ship in the application pack. Each
# shard starts from its own copied workspace, fixture executables, node and
# suite databases, HOME, XDG directories, temporary directory and gateway
# port. Only immutable installed vendor packs are shared. A clean
# environment: the harness and placement suites resolve the fixture
# executables in tests/fixtures/harness/bin by name and never reach the
# person's home, PATH or provider credentials. Provider variables a developer
# shell carries are set to fixture values the drivers must not read. Gateway,
# activation and inbox forwarding drains are disabled by fixture composition:
# the store suites queue, reserve, claim and drain that work themselves.
# TESTS keeps the native runner's substring filters. SHARDS defaults to four
# or fewer on small machines; each process receives its share of Go CPUs.
# tests/run.py --measure regenerates the balancing map from native runner logs.
# Copied metadata uses measured entry costs within existing deadline ceilings.
# Unmeasured entries keep the 30s fallback; each shard shares one measured
# suite_timeout among entries in the same named suite.
TEST_FIXTURES := $(abspath tests/fixtures)
TESTS ?=

$(TEST_FIXTURES)/harness/bin/gateway-client: $(TEST_FIXTURES)/harness/gateway_client.go
	go build -o $@ $<

SHARDS ?= $(shell python3 -c 'import os; print(min(4, max(1, len(os.sched_getaffinity(0)) // 4)))')

boot-check: test-prepare
	python3 tests/boot.py $(abspath $(WIPPY)) $(LUA_CACHE)

test-prepare: fixture-lint $(TEST_FIXTURES)/harness/bin/gateway-client
	python3 build/tools_test.py
	python3 -m unittest discover -s tests -p '*_test.py'

test: boot-check
	python3 tests/run.py --wippy $(abspath $(WIPPY)) --lua-cache $(LUA_CACHE) --shards $(SHARDS) --tests $(TESTS)

test-shard: test-prepare
	@test -n "$(SHARD)" || { echo "set SHARD=<1-based shard>"; exit 2; }
	python3 tests/run.py --wippy $(abspath $(WIPPY)) --lua-cache $(LUA_CACHE) --shards $(SHARDS) --shard $(SHARD) --tests $(TESTS)



define PACK_APPLICATION
$(WIPPY) install
$(BUILDER) pack $(MANIFEST) --toolchain $(WIPPY) --version $(VERSION)
endef

build: lint
	+$(MAKE) release-prepare release-compile VERSION=$(VERSION)

# Release pack and ordinary builder entrypoints.
release-pack: binary-identity
	$(PACK_APPLICATION)

install: build
	@if [ -e $(INSTALL_DIR)/bee ]; then cp $(INSTALL_DIR)/bee $(INSTALL_DIR)/bee.prev; fi
	install -m 755 dist/bee $(INSTALL_DIR)/bee

# One preparation path supplies CI consumers and the version-stamped release.
release-prepare: tools
	LUA_CACHE=$(LUA_CACHE) VERSION=$(VERSION) python3 build/prepare.py

release-compile: ci-tools
	BEE_RELEASE_SOURCE=$(abspath .wippy/release-module) .wippy/bin/bee-release-builder build $(MANIFEST) -o dist/bee
	GOOS=$(if $(GOOS),$(GOOS),$(shell go env GOHOSTOS)) GOARCH=$(if $(GOARCH),$(GOARCH),$(shell go env GOHOSTARCH)) python3 build/verify_target.py dist/bee

TARGET ?= linux/amd64

ci-tools: tools
	python3 build/release_builder.py

ci-tools-outputs:
	@python3 build/ci.py tools-outputs --target $(TARGET)

ci-application-key:
	@python3 build/ci.py application-key

ci-prepare: tools
	LUA_CACHE=$(LUA_CACHE) VERSION=$(VERSION) python3 build/prepare.py --fixtures --revision prepared
	LUA_CACHE=$(LUA_CACHE) python3 build/ci.py export

ci-restore:
	python3 build/ci.py restore-prepared

ci-import:
	python3 build/ci.py import

ci-stamp:
	python3 build/release_version.py $(VERSION)
	+$(MAKE) release-prepare VERSION=$(VERSION)
	LUA_CACHE=$(LUA_CACHE) python3 build/ci.py export

ci-require:
	python3 build/ci.py require-ci

ci-warm:
	python3 build/ci.py warm --target $(TARGET)

ci-plan:
	python3 build/ci.py plan-warm

ci-gate:
	python3 build/ci.py gate

release-rosetta:
	python3 build/ci.py rosetta

release-verify:
	python3 build/ci.py verify-release

release-publish:
	python3 build/ci.py publish --version $(VERSION)

release-package:
	python3 build/ci.py package --target $(TARGET) --version $(VERSION)

.PHONY: builder-version test-prepare test-shard release-prepare release-compile ci-tools ci-tools-outputs ci-application-key ci-prepare ci-restore ci-import ci-stamp ci-require ci-warm ci-gate ci-plan release-package release-rosetta release-verify release-publish
