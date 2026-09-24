# Standalone distribution uses the same native components for tools and releases.
BUILDER ?= env GOWORK=off GOTOOLCHAIN=go1.27.0 go run build/bootstrap.go
NATIVE_WIPPY ?= .wippy/bin/bee-wippy
BEE_BINARY ?= dist/bee
BEE_BUILD_MANIFEST ?= wippy.build.json
BEE_BUNDLE_MANIFEST ?= dist/bee.bundle.build.json
# BEE_NATIVE_LOCAL=1 compiles the checked-out native sources instead of the
# native module version pinned in wippy.build.json (development only).
BEE_NATIVE_LOCAL ?=
# A development build compiles the checked-out native sources. Export the local
# file proxy and disable direct VCS for the pinned builder so both the pack and
# build recipes resolve the worktree pseudo-version; the release path sets none.
ifneq ($(BEE_NATIVE_LOCAL),)
export GOPRIVATE := none
export GONOPROXY := none
export GONOSUMDB := github.com/wippyai/bee/*
export GONOSUMCHECK := 1
export GOPROXY := file://$(abspath .wippy/local-native/proxy),https://proxy.golang.org
endif
AGY_MODEL ?= gemini-3.8-flash
.PHONY: native-tools native-check native-bootstrap-check portable-pack-atomic-check native-pack portable-deployment-check standalone native-binary-check native-portable-check native-pin-check
NATIVE_PIN_COMMIT ?= HEAD
native-tools:
	$(BUILDER) toolchain "$(BEE_BUILD_MANIFEST)" --output "$(NATIVE_WIPPY)"

native-pin-check:
	build/native-pin.sh "$(BEE_BUILD_MANIFEST)" "$(NATIVE_PIN_COMMIT)"

native-bootstrap-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go test -race build/bootstrap.go build/bootstrap_test.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet build/bootstrap.go build/bootstrap_test.go

native-check: native-bootstrap-check
	$(MAKE) -C native check
	$(MAKE) -C native integration WIPPY="$(abspath $(NATIVE_WIPPY))"

portable-pack-atomic-check:
	tests/portable_pack_atomic.sh

native-pack:
	@test -x "$(NATIVE_WIPPY)" || { echo 'Run make native-tools before packing Bee.' >&2; exit 1; }
	@if [ -n "$(BEE_NATIVE_LOCAL)" ]; then \
		version=$$(build/local_native.sh "$(BEE_BUILD_MANIFEST)"); \
		BEE_BUILD_MANIFEST=".wippy/local-native/bee.build.json" \
			WIPPY="$(abspath $(NATIVE_WIPPY))" BEE_BUNDLE_MANIFEST="$(BEE_BUNDLE_MANIFEST)" \
			$(if $(BEE_VERSION),BEE_VERSION="$(BEE_VERSION)",) build/portable-pack.sh; \
	else \
		WIPPY="$(abspath $(NATIVE_WIPPY))" BEE_BUILD_MANIFEST="$(BEE_BUILD_MANIFEST)" BEE_BUNDLE_MANIFEST="$(BEE_BUNDLE_MANIFEST)" $(if $(BEE_VERSION),BEE_VERSION="$(BEE_VERSION)",) build/portable-pack.sh; \
	fi

portable-deployment-check: native-pack
	tests/portable_deployment.sh "$(abspath $(NATIVE_WIPPY))" "$(dir $(BEE_BUNDLE_MANIFEST))portable-deployment"

standalone: native-pack
	$(MAKE) standalone-sealed

# Assembles the executable from an already sealed pack set, so every target
# of one release embeds the same packs the Hub receives.
.PHONY: standalone-sealed
standalone-sealed:
	@test -f "$(BEE_BUNDLE_MANIFEST)" || { echo 'Run make native-pack before assembling Bee.' >&2; exit 1; }
	$(BUILDER) build "$(BEE_BUNDLE_MANIFEST)" --output "$(BEE_BINARY)"

native-binary-check:
	python3 tests/processes_check.py
	python3 tests/native_binary.py "$(BEE_BINARY)"
	python3 tests/native_modules.py "$(BEE_BINARY)"
	BEE_ABOUT_SOURCE="$(BEE_ABOUT_SOURCE)" python3 tests/native_about.py "$(BEE_BINARY)"
	$(MAKE) native-agent-selector-check BEE_BINARY="$(BEE_BINARY)"
	$(MAKE) window-command-hooks-check BEE_BINARY="$(BEE_BINARY)"

BEE_RELEASE_ARCHIVE ?= dist/release/bee-$(shell go env GOOS)-$(shell go env GOARCH).tar.gz
.PHONY: release
release: repository-check native-tools
	$(MAKE) check WIPPY="$(abspath $(NATIVE_WIPPY))"
	$(MAKE) native-check
	$(MAKE) native-pack
	tests/portable_deployment.sh "$(abspath $(NATIVE_WIPPY))" "$(dir $(BEE_BUNDLE_MANIFEST))portable-deployment"
	$(BUILDER) build "$(BEE_BUNDLE_MANIFEST)" --output "$(BEE_BINARY)"
	$(MAKE) native-binary-check
	@if [ "$(shell go env GOOS)" = linux ]; then $(MAKE) offline-boot-check; fi
	$(BUILDER) package "$(BEE_BINARY)" --output "$(BEE_RELEASE_ARCHIVE)"

HUB_VISIBILITY ?= private
BEE_DEPLOYMENT ?= $(dir $(BEE_BUNDLE_MANIFEST))portable-deployment
.PHONY: hub-check hub-publish hub-publish-script-check
# Both upload the sealed packs of the release deployment that
# `make standalone BEE_VERSION=X` (or native-pack) embeds; neither repacks.
hub-check:
	WIPPY="$(abspath $(NATIVE_WIPPY))" BEE_VERSION="$(BEE_VERSION)" BEE_DEPLOYMENT="$(abspath $(BEE_DEPLOYMENT))" build/hub-publish.sh check

hub-publish: hub-check
	WIPPY="$(abspath $(NATIVE_WIPPY))" BEE_VERSION="$(BEE_VERSION)" BEE_DEPLOYMENT="$(abspath $(BEE_DEPLOYMENT))" HUB_VISIBILITY="$(HUB_VISIBILITY)" build/hub-publish.sh publish

check: hub-publish-script-check
hub-publish-script-check:
	tests/hub_publish.sh

# Post-publication check: a real Hub package installs into the published
# release deployment, which resolves every locked bee/* module from the Hub.
# It holds only once that release's packs are published, so `make check` never
# runs it; hub-publish-release does, right after publication.
.PHONY: hub-release-install-check
hub-release-install-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/hub_release_install.py "$(if $(BEE_DEPLOYMENT),$(abspath $(BEE_DEPLOYMENT)))" "$(BEE_VERSION)"

# Publish one GitHub release's modules to the Hub from that release's own
# deployment archive, then run the post-publication check against it. TAG
# names the release (drafts included). hub-release-restore downloads and
# verifies the deployment; hub-release-publish uploads the restored deployment
# with WIPPY_TOKEN or the Wippy CLI login and runs the post-publication check;
# hub-check-release restores and dry-runs only.
HUB_RELEASE_DIR ?= dist/hub-release
HUB_RELEASE_DEPLOYMENT = $(abspath $(HUB_RELEASE_DIR))/deployment
HUB_RELEASE_VERSION = $(patsubst v%,%,$(TAG))
.PHONY: hub-release-tag hub-release-restore hub-release-publish hub-check-release hub-publish-release hub-release-script-check
hub-release-tag:
	@test -n "$(TAG)" || { echo 'Set TAG to the release tag, for example TAG=v0.1.0.' >&2; exit 1; }

hub-release-restore: hub-release-tag
	build/hub-release.sh "$(TAG)" "$(abspath $(HUB_RELEASE_DIR))"

hub-release-publish: hub-release-tag
	$(MAKE) hub-publish BEE_VERSION="$(HUB_RELEASE_VERSION)" BEE_DEPLOYMENT="$(HUB_RELEASE_DEPLOYMENT)"
	$(MAKE) hub-release-install-check BEE_VERSION="$(HUB_RELEASE_VERSION)" BEE_DEPLOYMENT="$(HUB_RELEASE_DEPLOYMENT)"

hub-check-release: hub-release-restore
	$(MAKE) hub-check BEE_VERSION="$(HUB_RELEASE_VERSION)" BEE_DEPLOYMENT="$(HUB_RELEASE_DEPLOYMENT)"

hub-publish-release: hub-release-restore
	$(MAKE) hub-release-publish

check: hub-release-script-check
hub-release-script-check:
	tests/hub_release.sh

# Two real executables, one disposable state directory; no --base workaround.
.PHONY: native-upgrade-check
native-upgrade-check:
	@test -n "$(PREVIOUS_BEE)" || { echo "PREVIOUS_BEE must name a Bee binary predating Hive Manager" >&2; exit 1; }
	python3 tests/native_upgrade.py "$(PREVIOUS_BEE)" "$(BEE_BINARY)"

.PHONY: native-client-check
native-client-check:
	python3 tests/native_client.py "$(BEE_BINARY)"

# Two nodes in two state directories on this host join one hive with a
# one-line invite over the mesh's identity TLS; disposable state lives under
# .wippy/ and every owner the check starts is stopped.
.PHONY: hive-join-check
hive-join-check:
	python3 tests/hive_join.py "$(BEE_BINARY)"

# Reusable release acceptance: Linux network namespace, disposable state and
# frame-bearing public desktop/reconnect checks. Restored-install fixtures stay
# outside the repository target because they require an independently reviewed
# registry backup and artifact set.
.PHONY: offline-boot-check
offline-boot-check:
	tests/offline_boot.sh "$(abspath $(BEE_BINARY))"

# The executable is built only from the same sealed physical pack set. The
# offline smoke starts the native binary from an empty caller directory in a
# Linux network namespace.
native-portable-check: standalone
	tests/portable_deployment.sh "$(abspath $(NATIVE_WIPPY))" "$(dir $(BEE_BUNDLE_MANIFEST))portable-deployment"
	$(MAKE) native-binary-check BEE_BINARY="$(abspath $(BEE_BINARY))"
	$(MAKE) offline-boot-check BEE_BINARY="$(abspath $(BEE_BINARY))"

# Longer diagnostic gate for repeated departures; no user's Bee is touched.
.PHONY: native-client-retention-check
native-client-retention-check:
	python3 tests/native_client.py "$(BEE_BINARY)" --idle-reconnects

# Opt-in overlapping-display diagnostic. Failure preserves disposable evidence.
RECONNECT_ROUNDS ?= 30
RECONNECT_KEEP ?= 0
.PHONY: native-reconnect-check
native-reconnect-check:
	python3 tests/native_reconnect.py "$(BEE_BINARY)" --rounds "$(RECONNECT_ROUNDS)" $(if $(filter 1,$(RECONNECT_KEEP)),--keep-fixture,)

.PHONY: native-desktop-selection-check
native-desktop-selection-check:
	python3 tests/native_desktop_selection.py "$(BEE_BINARY)"

.PHONY: native-workspace-switch-check
native-workspace-switch-check:
	python3 tests/native_workspace_switch.py "$(BEE_BINARY)"

.PHONY: native-daemon-check
native-daemon-check:
	python3 tests/native_daemon.py "$(BEE_BINARY)"

.PHONY: native-connection-ui-check native-independent-desktops-check
native-connection-ui-check:
	python3 tests/native_connection_ui.py "$(BEE_BINARY)"

native-independent-desktops-check:
	python3 tests/native_client.py "$(BEE_BINARY)" --desktops

.PHONY: native-settings-resize-check
native-settings-resize-check:
	python3 tests/native_settings_resize.py "$(BEE_BINARY)"

.PHONY: native-display-appearance-check
native-display-appearance-check:
	python3 tests/native_display_appearance.py "$(BEE_BINARY)"

.PHONY: native-display-transfer-check
native-display-transfer-check:
	python3 tests/native_display_transfer.py "$(BEE_BINARY)"

.PHONY: native-hive-catalog-check
native-hive-catalog-check:
	python3 tests/native_hive_catalog.py "$(BEE_BINARY)"

.PHONY: native-project-nodes-check
native-project-nodes-check:
	python3 tests/native_project_nodes.py "$(BEE_BINARY)" $(if $(PREVIOUS_BEE),"$(PREVIOUS_BEE)",)

# The shipped executable's hook-post command submits a native window's command
# hooks to a live gateway run by the development runtime.
.PHONY: window-command-hooks-check
window-command-hooks-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/window_hooks.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/window_hooks.go -runtime "$(abspath $(NATIVE_WIPPY))" -bee "$(abspath $(BEE_BINARY))"
# Downloads, verified against native/go.sum, every module and the toolchain the
# Go acceptance harnesses of native-binary-check compile against, so the check
# can run with the network cut and GOPROXY=off.
.PHONY: native-harness-modules
native-harness-modules:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native list -deps -test ../tests/native_agent_selector.go ../tests/native_agent_selector_test.go >/dev/null
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go list -deps tests/window_hooks.go >/dev/null
# Runs native-binary-check as this user in a fresh network namespace whose only
# interface is loopback. The harness modules are fetched first while online;
# GOPROXY=off turns any module the fetch missed into a failure.
.PHONY: native-binary-offline-check
native-binary-offline-check: native-harness-modules
	unshare --user --map-root-user --net -- sh -c 'ip link set lo up && exec env GOPROXY=off "$$0" native-binary-check BEE_BINARY="$$1"' "$(MAKE)" "$(BEE_BINARY)"
.PHONY: native-agent-selector-check
native-agent-selector-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native test ../tests/native_agent_selector.go ../tests/native_agent_selector_test.go -count=1
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/native_agent_selector.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/native_agent_selector.go "$(abspath $(BEE_BINARY))"

.PHONY: native-managed-agent-check
native-managed-agent-check:
	test -n "$(AGENT_PROVIDER)"
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/native_agent_selector.go managed "$(AGENT_PROVIDER)" "$(abspath $(BEE_BINARY))"

.PHONY: native-agy-live-check native-agy-recovery-live-check native-claude-recovery-live-check native-codex-recovery-live-check native-grok-live-check native-grok-recovery-live-check native-muse-recovery-live-check
.PHONY: native-agent-picker-check
native-agent-picker-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/native_agent_selector.go picker "$(abspath $(BEE_BINARY))"

native-agy-live-check:
	test -n "$(AGY_BIN)"
	env GOWORK=off GOTOOLCHAIN=go1.27.0 BEE_BINARY="$(abspath $(BEE_BINARY))" AGY_BIN="$(abspath $(AGY_BIN))" go -C native test ../tests/native_agent_selector.go ../tests/native_agent_live_test.go -run TestActualAgyManagedStartup -count=1 -v

native-agy-recovery-live-check:
	test -n "$(AGY_BIN)" -a -n "$(AGY_LOGIN_FILE)"
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/native_agent_selector.go ../tests/native_agent_live_test.go ../tests/native_agent_agy_recovery_test.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 BEE_BINARY="$(abspath $(BEE_BINARY))" AGY_BIN="$(abspath $(AGY_BIN))" AGY_LOGIN_FILE="$(abspath $(AGY_LOGIN_FILE))" AGY_MODEL="$(AGY_MODEL)" go -C native test ../tests/native_agent_selector.go ../tests/native_agent_live_test.go ../tests/native_agent_agy_recovery_test.go -run '^TestActualAgyManagedColdRecovery$$' -count=1 -v

native-claude-recovery-live-check:
	test -n "$(CLAUDE_BIN)" -a -n "$(CLAUDE_CREDENTIAL_ENV)"
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/native_agent_selector.go ../tests/native_agent_live_test.go ../tests/native_agent_claude_recovery_test.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 BEE_BINARY="$(abspath $(BEE_BINARY))" CLAUDE_BIN="$(abspath $(CLAUDE_BIN))" CLAUDE_CREDENTIAL_ENV="$(CLAUDE_CREDENTIAL_ENV)" go -C native test ../tests/native_agent_selector.go ../tests/native_agent_live_test.go ../tests/native_agent_claude_recovery_test.go -run '^TestActualClaudeManagedColdRecovery$$' -count=1 -v

native-codex-recovery-live-check:
	test -n "$(CODEX_BIN)" -a -n "$(CODEX_LOGIN_FILE)" -a -n "$(CODEX_CONFIG_FILE)"
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/native_agent_selector.go ../tests/native_agent_live_test.go ../tests/native_agent_codex_recovery_test.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 BEE_BINARY="$(abspath $(BEE_BINARY))" CODEX_BIN="$(abspath $(CODEX_BIN))" CODEX_LOGIN_FILE="$(abspath $(CODEX_LOGIN_FILE))" CODEX_CONFIG_FILE="$(abspath $(CODEX_CONFIG_FILE))" go -C native test ../tests/native_agent_selector.go ../tests/native_agent_live_test.go ../tests/native_agent_codex_recovery_test.go -run '^TestActualCodexManagedColdRecovery$$' -count=1 -v

native-grok-live-check:
	test -n "$(GROK_BIN)" -a -n "$(GROK_LOGIN_FILE)"
	env GOWORK=off GOTOOLCHAIN=go1.27.0 BEE_BINARY="$(abspath $(BEE_BINARY))" GROK_BIN="$(abspath $(GROK_BIN))" GROK_LOGIN_FILE="$(abspath $(GROK_LOGIN_FILE))" go -C native test ../tests/native_agent_selector.go ../tests/native_agent_live_test.go -run TestActualGrokManagedStartup -count=1 -v

native-grok-recovery-live-check:
	test -n "$(GROK_BIN)" -a -n "$(GROK_LOGIN_FILE)" -a -n "$(GROK_CONFIG_FILE)"
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/native_agent_selector.go ../tests/native_agent_live_test.go ../tests/native_agent_grok_recovery_test.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 BEE_BINARY="$(abspath $(BEE_BINARY))" GROK_BIN="$(abspath $(GROK_BIN))" GROK_LOGIN_FILE="$(abspath $(GROK_LOGIN_FILE))" GROK_CONFIG_FILE="$(abspath $(GROK_CONFIG_FILE))" go -C native test ../tests/native_agent_selector.go ../tests/native_agent_live_test.go ../tests/native_agent_grok_recovery_test.go -run '^TestActualGrokManagedColdRecovery$$' -count=1 -v

native-muse-recovery-live-check:
	test -n "$(MUSE_BIN)" -a -n "$(MUSE_LOGIN_FILE)"
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/native_agent_selector.go ../tests/native_agent_live_test.go ../tests/native_agent_muse_recovery_test.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 BEE_BINARY="$(abspath $(BEE_BINARY))" MUSE_BIN="$(abspath $(MUSE_BIN))" MUSE_LOGIN_FILE="$(abspath $(MUSE_LOGIN_FILE))" go -C native test ../tests/native_agent_selector.go ../tests/native_agent_live_test.go ../tests/native_agent_muse_recovery_test.go -run '^TestActualMuseManagedColdRecovery$$' -count=1 -v
