# Bee build protocol. Every step is pinned by wippy.build.json (runtime module
# and version) and BUILDER_VERSION; nothing is cloned or patched.
#
#   make tools     install wippy-builder and build the matching wippy toolchain
#   make lint      lint the application and its tests with that toolchain
#   make test      run the Lua suites in tests/ against the application source
#   make e2e       drive two hive nodes and a display through the built binary
#   make footprint check a headless node's resident memory and live heap against budgets
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
VERSION ?= 0.1.0-dev
BIN := .wippy/bin
BUILDER := $(BIN)/wippy-builder
WIPPY := $(BIN)/wippy
INSTALL_DIR ?= $(HOME)/.local/bin

MANIFEST := wippy.build.json

export GOWORK := off
export GOTOOLCHAIN := go1.27.0

ifdef RUNTIME_SOURCE
MANIFEST := wippy.build.local.json
export GOPROXY := direct
export GONOSUMDB := github.com/wippyai/runtime,github.com/wippyai/bee
export GOPRIVATE := github.com/wippyai/runtime,github.com/wippyai/bee
export GIT_CONFIG_COUNT := 2
export GIT_CONFIG_KEY_0 := url.file://$(abspath $(RUNTIME_SOURCE)).insteadOf
export GIT_CONFIG_VALUE_0 := https://github.com/wippyai/runtime
export GIT_CONFIG_KEY_1 := url.file://$(abspath .).insteadOf
export GIT_CONFIG_VALUE_1 := https://github.com/wippyai/bee
$(shell python3 build/local_manifest.py $(RUNTIME_SOURCE) .)
endif

.PHONY: tools runtime-pin native-pin compose lint test e2e footprint build install binary-identity binary-identity-check

$(BUILDER):
	GOBIN=$(abspath $(BIN)) go install github.com/wippyai/builder/cmd/wippy-builder@$(BUILDER_VERSION)

$(WIPPY): $(BUILDER) $(MANIFEST)
	$(BUILDER) toolchain $(MANIFEST) -o $(WIPPY)

tools: $(BUILDER) $(WIPPY)

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
compose:
	python3 tests/compose.py

binary-identity: $(WIPPY)
	python3 build/binary_identity.py --manifest $(MANIFEST) --toolchain $(WIPPY) --version $(VERSION)

binary-identity-check:
	python3 build/binary_identity_test.py

lint: binary-identity compose
	python3 tools/corpus.py --check
	$(WIPPY) lint
	cd tests && $(abspath $(WIPPY)) install && $(abspath $(WIPPY)) lint

# The tests workspace loads bee/bee from the composed copy of src through its
# workspace replacement, so suites never ship in the application pack. Each
# run starts from fresh run state (the node database, the suites' own
# databases and fixture directories, a fixture HOME) and runs under a clean
# environment: the harness and placement suites resolve the fixture
# executables in tests/fixtures/harness/bin by name and never reach the
# person's home, PATH or provider credentials. Provider variables a developer
# shell carries are set to fixture values the drivers must not read. The gateway
# and governance effect workers stay stopped, and so does the inbox forwarding pump:
# the store suites queue, reserve, claim and drain that work themselves.
# TESTS selects test entries by id.
TEST_ROOT := $(abspath tests/.wippy/fixture)
TEST_FIXTURES := $(abspath tests/fixtures)
TESTS ?=

$(TEST_FIXTURES)/harness/bin/gateway-client: $(TEST_FIXTURES)/harness/gateway_client.go
	go build -o $@ $<

test: binary-identity compose $(TEST_FIXTURES)/harness/bin/gateway-client
	find tests/.wippy -mindepth 1 -maxdepth 1 ! -name vendor ! -name cache ! -name composition ! -name .artifacts.lock -exec rm -rf {} +
	mkdir -p $(TEST_ROOT)/home/.claude $(TEST_ROOT)/tmp $(TEST_ROOT)/bin && touch $(TEST_ROOT)/home/.claude/.credentials.json
	ln -sfn $(TEST_FIXTURES)/harness/bin/claude $(TEST_ROOT)/bin/absolute-claude
	cd tests && $(abspath $(WIPPY)) install && env -i \
		HOME=$(TEST_ROOT)/home XDG_CONFIG_HOME=$(TEST_ROOT)/home/.config \
		XDG_DATA_HOME=$(TEST_ROOT)/home/.local/share XDG_CACHE_HOME=$(TEST_ROOT)/home/.cache \
		WIPPY_CACHE_DIR=$(abspath tests/.wippy/cache) TMPDIR=$(TEST_ROOT)/tmp LANG=C.UTF-8 NO_COLOR= \
		PATH=$(TEST_FIXTURES)/harness/bin:$(TEST_ROOT)/bin:/usr/bin:/bin \
		BEE_FIXTURE_BIN=$(TEST_FIXTURES)/harness/bin BEE_FIXTURE_STREAMS=$(TEST_FIXTURES)/drivers \
		BEE_FIXTURE_HOOK_COMMAND=$(TEST_FIXTURES)/harness/bin/gateway-client \
		BEE_AMBIENT_LIVE_PROVIDER=none \
		CLAUDE_CONFIG_DIR=$(TEST_ROOT)/shell/claude CODEX_HOME=$(TEST_ROOT)/shell/codex \
		ANTHROPIC_API_KEY=fixture-shell-value-not-a-key \
		$(abspath $(WIPPY)) test --host bee:terminal \
		-o bee.gateway.service:gateway_installation_service:lifecycle.auto_start=false \
		-o bee.gateway.service:gateway_publication_service:lifecycle.auto_start=false \
		-o bee.gov.service:activation_service:lifecycle.auto_start=false \
		-o bee.threads.service:pump_service:lifecycle.auto_start=false \
		$(if $(TESTS),test $(TESTS))

e2e: build
	tests/e2e/hive.sh dist/bee

footprint: build
	tests/footprint.sh dist/bee

build: lint
	$(WIPPY) install
	$(BUILDER) pack $(MANIFEST) --toolchain $(WIPPY) --version $(VERSION)
	$(BUILDER) build $(MANIFEST) -o dist/bee

install: build
	@if [ -e $(INSTALL_DIR)/bee ]; then cp $(INSTALL_DIR)/bee $(INSTALL_DIR)/bee.prev; fi
	install -m 755 dist/bee $(INSTALL_DIR)/bee
