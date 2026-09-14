# Standalone distribution uses the same native components for tools and releases.
BUILDER ?= env GOWORK=off GOTOOLCHAIN=go1.27.0 go run build/bootstrap.go
NATIVE_WIPPY ?= .wippy/bin/bee-wippy
BEE_BINARY ?= dist/bee
BEE_BUILD_MANIFEST ?= wippy.build.json
BEE_BUNDLE_MANIFEST ?= dist/bee.bundle.build.json
AGY_MODEL ?= gemini-3.8-flash
MILESTONE ?=
PROMOTION_RECEIPT ?= dist/promotion-$(MILESTONE).json
.PHONY: native-tools native-check native-bootstrap-check native-pack standalone native-binary-check
native-tools:
	$(BUILDER) toolchain "$(BEE_BUILD_MANIFEST)" --output "$(NATIVE_WIPPY)"

native-bootstrap-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go test -race build/bootstrap.go build/bootstrap_test.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet build/bootstrap.go build/bootstrap_test.go

native-check: native-bootstrap-check
	$(MAKE) -C native check
	$(MAKE) -C native integration WIPPY="$(abspath $(NATIVE_WIPPY))"

native-pack:
	python3 build/bundle.py --manifest "$(BEE_BUILD_MANIFEST)" --output "$(BEE_BUNDLE_MANIFEST)" --toolchain "$(abspath $(NATIVE_WIPPY))" $(if $(BEE_VERSION),--version "$(BEE_VERSION)",) $(if $(BEE_MODE),--mode "$(BEE_MODE)",)

standalone: native-pack
	$(BUILDER) build "$(BEE_BUNDLE_MANIFEST)" --output "$(BEE_BINARY)"

.PHONY: bundle-check bundle-assets-check
bundle-check:
	python3 -m unittest discover -s build -p 'bundle_test.py'

bundle-assets-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/bundle_assets.py

native-binary-check:
	python3 tests/native_binary.py "$(BEE_BINARY)"
	python3 tests/native_modules.py "$(BEE_BINARY)"
	BEE_ABOUT_SOURCE="$(BEE_ABOUT_SOURCE)" python3 tests/native_about.py "$(BEE_BINARY)"
	$(MAKE) native-agent-selector-check BEE_BINARY="$(BEE_BINARY)"

BEE_RELEASE_ARCHIVE ?= dist/release/bee-$(shell go env GOOS)-$(shell go env GOARCH).tar.gz
.PHONY: release
release: repository-check native-tools
	$(MAKE) check WIPPY="$(abspath $(NATIVE_WIPPY))"
	$(MAKE) native-check
	$(MAKE) standalone
	$(MAKE) native-binary-check
	$(BUILDER) package "$(BEE_BINARY)" --output "$(BEE_RELEASE_ARCHIVE)"

HUB_VISIBILITY ?= private
.PHONY: hub-check hub-publish
hub-check:
	@test -n "$(BEE_VERSION)" || { echo 'Set BEE_VERSION to the release version.' >&2; exit 1; }
	$(MAKE) lint WIPPY="$(abspath $(NATIVE_WIPPY))"
	"$(abspath $(NATIVE_WIPPY))" publish --dry-run --version "$(BEE_VERSION)"

hub-publish: hub-check
	"$(abspath $(NATIVE_WIPPY))" publish --version "$(BEE_VERSION)" --protected --module-visibility "$(HUB_VISIBILITY)"

# Two real executables, one disposable state directory; no --base workaround.
.PHONY: native-upgrade-check
native-upgrade-check:
	@test -n "$(PREVIOUS_BEE)" || { echo "PREVIOUS_BEE must name a Bee binary predating Hive Manager" >&2; exit 1; }
	python3 tests/native_upgrade.py "$(PREVIOUS_BEE)" "$(BEE_BINARY)"

.PHONY: native-client-check
native-client-check:
	python3 tests/native_client.py "$(BEE_BINARY)"

# Reusable release acceptance: Linux network namespace, disposable state and
# frame-bearing public desktop/reconnect checks. Restored-install fixtures stay
# outside the repository target because they require an independently reviewed
# registry backup and artifact set.
.PHONY: offline-boot-check
offline-boot-check:
	tests/offline_boot.sh "$(abspath $(BEE_BINARY))"

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

.PHONY: native-agent-selector-check
native-agent-selector-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native test ../tests/native_agent_selector.go ../tests/native_agent_selector_test.go -count=1
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/native_agent_selector.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/native_agent_selector.go "$(abspath $(BEE_BINARY))"

.PHONY: native-managed-agent-check
native-managed-agent-check:
	test -n "$(AGENT_PROVIDER)"
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/native_agent_selector.go managed "$(AGENT_PROVIDER)" "$(abspath $(BEE_BINARY))"

.PHONY: native-agy-live-check native-agy-recovery-live-check native-claude-recovery-live-check native-codex-recovery-live-check native-grok-live-check native-grok-recovery-live-check
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

# A promotion check is read-only with respect to the installed Bee. It builds a
# fresh candidate, exercises the public journeys for one milestone, and writes a
# machine-readable evidence receipt only after every gate succeeds. Installation
# remains a separate, explicit operation.
.PHONY: promotion-check promotion-native-agents-check
promotion-check:
	@test "$(MILESTONE)" = native-agents || { echo "unsupported MILESTONE: $(MILESTONE)" >&2; exit 2; }
	@test -z "$$(git status --porcelain --untracked-files=all)" || { echo "promotion requires a clean immutable commit" >&2; exit 2; }
	$(MAKE) promotion-native-agents-check PROMOTION_COMMIT="$$(git rev-parse HEAD)"

promotion-native-agents-check:
	@test -n "$(PROMOTION_COMMIT)" -a "$$(git rev-parse HEAD)" = "$(PROMOTION_COMMIT)" || { echo "promotion commit is absent or changed" >&2; exit 2; }
	@test -x "$(PREVIOUS_BEE)" || { echo "PREVIOUS_BEE must name the executable rollback build" >&2; exit 2; }
	@test -x "$(AGY_BIN)" -a -f "$(AGY_LOGIN_FILE)" || { echo "Agy executable/login inputs are required" >&2; exit 2; }
	@test -x "$(CLAUDE_BIN)" -a "$(CLAUDE_CREDENTIAL_ENV)" = ANTHROPIC_API_KEY || { echo "Claude executable and ANTHROPIC_API_KEY selector are required" >&2; exit 2; }
	@test -x "$(CODEX_BIN)" -a -f "$(CODEX_LOGIN_FILE)" -a -f "$(CODEX_CONFIG_FILE)" || { echo "Codex executable/login/config inputs are required" >&2; exit 2; }
	@test -x "$(GROK_BIN)" -a -f "$(GROK_LOGIN_FILE)" -a -f "$(GROK_CONFIG_FILE)" || { echo "Grok executable/login/config inputs are required" >&2; exit 2; }
	@test -z "$$(git status --porcelain --untracked-files=all)" || { echo "promotion requires a clean immutable commit" >&2; exit 2; }
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go test -race ./cmd/promotion-receipt
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet ./cmd/promotion-receipt
	$(MAKE) repository-check
	$(MAKE) native-tools NATIVE_WIPPY="$(abspath $(NATIVE_WIPPY))"
	@test -x "$(NATIVE_WIPPY)" || { echo "native-tools did not produce the exact promotion runtime" >&2; exit 2; }
	$(MAKE) check WIPPY="$(abspath $(NATIVE_WIPPY))"
	$(MAKE) native-check NATIVE_WIPPY="$(abspath $(NATIVE_WIPPY))"
	$(MAKE) standalone NATIVE_WIPPY="$(abspath $(NATIVE_WIPPY))" BEE_BINARY="$(abspath $(BEE_BINARY))"
	$(MAKE) native-agy-recovery-live-check BEE_BINARY="$(abspath $(BEE_BINARY))" AGY_BIN="$(abspath $(AGY_BIN))" AGY_LOGIN_FILE="$(abspath $(AGY_LOGIN_FILE))" AGY_MODEL="$(AGY_MODEL)"
	$(MAKE) native-claude-recovery-live-check BEE_BINARY="$(abspath $(BEE_BINARY))" CLAUDE_BIN="$(abspath $(CLAUDE_BIN))" CLAUDE_CREDENTIAL_ENV="$(CLAUDE_CREDENTIAL_ENV)"
	$(MAKE) native-codex-recovery-live-check BEE_BINARY="$(abspath $(BEE_BINARY))" CODEX_BIN="$(abspath $(CODEX_BIN))" CODEX_LOGIN_FILE="$(abspath $(CODEX_LOGIN_FILE))" CODEX_CONFIG_FILE="$(abspath $(CODEX_CONFIG_FILE))"
	$(MAKE) native-grok-recovery-live-check BEE_BINARY="$(abspath $(BEE_BINARY))" GROK_BIN="$(abspath $(GROK_BIN))" GROK_LOGIN_FILE="$(abspath $(GROK_LOGIN_FILE))" GROK_CONFIG_FILE="$(abspath $(GROK_CONFIG_FILE))"
	$(MAKE) native-binary-check BEE_BINARY="$(abspath $(BEE_BINARY))"
	$(MAKE) offline-boot-check BEE_BINARY="$(abspath $(BEE_BINARY))"
	$(MAKE) native-client-check BEE_BINARY="$(abspath $(BEE_BINARY))"
	$(MAKE) native-independent-desktops-check BEE_BINARY="$(abspath $(BEE_BINARY))"
	$(MAKE) native-agent-recovery-check BEE_BINARY="$(abspath $(BEE_BINARY))"
	$(MAKE) native-agent-crash-recovery-check BEE_BINARY="$(abspath $(BEE_BINARY))"
	$(MAKE) native-upgrade-check BEE_BINARY="$(abspath $(BEE_BINARY))" PREVIOUS_BEE="$(abspath $(PREVIOUS_BEE))"
	$(MAKE) native-project-nodes-check BEE_BINARY="$(abspath $(BEE_BINARY))" PREVIOUS_BEE="$(abspath $(PREVIOUS_BEE))"
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run ./cmd/promotion-receipt \
		-milestone native-agents \
		-expected-commit "$(PROMOTION_COMMIT)" \
		-binary "$(abspath $(BEE_BINARY))" \
		-runtime "$(abspath $(NATIVE_WIPPY))" \
		-previous "$(abspath $(PREVIOUS_BEE))" \
		-build-manifest "$(abspath $(BEE_BUILD_MANIFEST))" \
		-bundle-manifest "$(abspath $(BEE_BUNDLE_MANIFEST))" \
		-agy "$(abspath $(AGY_BIN))" \
		-agy-login "$(abspath $(AGY_LOGIN_FILE))" \
		-agy-model "$(AGY_MODEL)" \
		-builder-command "$(BUILDER)" \
		-bee-version "$(BEE_VERSION)" \
		-bee-mode "$(BEE_MODE)" \
		-claude "$(abspath $(CLAUDE_BIN))" \
		-claude-credential-env "$(CLAUDE_CREDENTIAL_ENV)" \
		-codex "$(abspath $(CODEX_BIN))" \
		-codex-login "$(abspath $(CODEX_LOGIN_FILE))" \
		-codex-config "$(abspath $(CODEX_CONFIG_FILE))" \
		-grok "$(abspath $(GROK_BIN))" \
		-grok-login "$(abspath $(GROK_LOGIN_FILE))" \
		-grok-config "$(abspath $(GROK_CONFIG_FILE))" \
		-output "$(abspath $(PROMOTION_RECEIPT))"
