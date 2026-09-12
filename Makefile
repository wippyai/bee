WIPPY ?= .wippy/bin/bee-wippy
LINT_FLAGS ?=
.PHONY: setup run lint test fixture-gateway-client threads threads-module resources-module gateway-check pack check
setup: native-tools
.PHONY: hub-inspect-check
# Explicit live-Hub proof; ordinary checks do not require Hub network access.
hub-inspect-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/hub_inspect.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/hub_inspect.go -runtime "$(abspath $(WIPPY))"
.PHONY: hub-preview-check
hub-preview-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/hub_preview.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/hub_preview.go -runtime "$(abspath $(WIPPY))"
.PHONY: hub-unit-check
hub-unit-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/hub_unit.py
.PHONY: native-modules-lifecycle-check
native-modules-lifecycle-check:
	python3 tests/native_modules_lifecycle.py "$(BEE_BINARY)"
.PHONY: modules-app-check
modules-app-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/modules_app.py
check: modules-app-check
.PHONY: hub-manage-check
hub-manage-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/hub_inspect.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/hub_inspect.go -runtime "$(abspath $(WIPPY))" -manage
.PHONY: hub-recovery-check
hub-recovery-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/hub_recovery.py
.PHONY: sync-check
sync-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/sync_module.py
.PHONY: sync-unit-check
sync-unit-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/sync_unit.py
.PHONY: sync-hive-check
sync-hive-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 BEE_HIVE_SUPERVISOR_RUNTIME="$(abspath $(WIPPY))" go test -race -count=1 -v tests/hive_remote.go tests/hive_supervisor_test.go -run '^TestHiveSupervisorFeeds$$'
.PHONY: governance-runtime-check
governance-runtime-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/governance_runtime.py

.PHONY: governance-overlay-check governance-overlay-composed-base-check
governance-overlay-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/governance_overlay.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/governance_overlay.go -runtime "$(abspath $(WIPPY))" -gate owner
governance-overlay-composed-base-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/governance_overlay.go -runtime "$(abspath $(WIPPY))" -gate composed-base

.PHONY: governance-workspace-check
governance-workspace-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/governance_workspace.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/governance_workspace.go -runtime "$(abspath $(WIPPY))"

run:
	BEE_RUNTIME="$(abspath $(WIPPY))" bash ./run.sh
lint:
	$(WIPPY) lint $(LINT_FLAGS) --set lua.type_system.enabled=true --set lua.type_system.strict=true
fixture-gateway-client: tests/fixtures/harness/gateway_client.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go build -o tests/fixtures/harness/bin/gateway-client tests/fixtures/harness/gateway_client.go
test: fixture-gateway-client
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/unit.py
.PHONY: hive-reader-check clipboard-contract-check
hive-reader-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/hive_reader.py
clipboard-contract-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/clipboard_contract.py
.PHONY: client-desktop-check local-launcher-check client-storage-check retained-desktop-check
retained-desktop-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" PYTHONPATH=tests python3 -c 'import client_desktop; client_desktop.run(command="retained-supervisor-probe"); client_desktop.run(command="retained-supervisor-probe", storage_delay=True); client_desktop.run(command="retained-supervisor-probe", launch_exit=True); client_desktop.run(command="retained-supervisor-probe", primary_render_delay=True); client_desktop.run(command="retained-supervisor-probe", copy_exit=True); client_desktop.run(command="retained-supervisor-probe", primary_exit=True)'
client-storage-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" PYTHONPATH=tests python3 -c 'import storage; storage.client_storage()'
client-desktop-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/client_desktop.py
local-launcher-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/local_launcher.py
.PHONY: terminal-scroll-check terminal-selection-check
terminal-selection-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/terminal_selection.py
terminal-scroll-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/terminal_scroll.py
.PHONY: process-manager-check
process-manager-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" PYTHONPATH=tests python3 -c 'import tui_smoke; tui_smoke.process_manager(False); tui_smoke.process_manager(True)'
.PHONY: window-retirement-check
window-retirement-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/window_retirement.py
.PHONY: window-native-check managed-window-app-check managed-provider-window-check window-hooks-check
window-native-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/window_native.py
managed-provider-window-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/managed_provider_window.py
managed-window-app-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/managed_window_app.py
window-hooks-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/window_hooks.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/window_hooks.go -runtime "$(abspath $(WIPPY))"
.PHONY: layout-ack-check
layout-ack-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" PYTHONPATH=tests python3 -c 'import personalization; personalization.acknowledged_layout()'
threads:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/threads.py
threads-module:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/thread_module.py
.PHONY: harness-module
harness-module:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/harness_module.go -root .. -runtime "$(abspath $(WIPPY))"
resources-module:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/resources_module.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/resources_module.go -root .. -runtime "$(abspath $(WIPPY))"
gateway-check:
	BEE_GOVERNANCE_DB=governance.db BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/gateway.py
pack: lint
	mkdir -p dist
	$(WIPPY) pack dist/bee.wapp

# Source-free acceptance boots run in disposable working directories, including
# cases without .wippy/. Keep their governance store inside that fixture too.
check desktop-check client-storage-check: export BEE_GOVERNANCE_DB = governance.db

check: identity-native-check installer-check bundle-check bundle-assets-check lint test window-native-check managed-window-app-check window-hooks-check threads threads-module harness-module resources-module gateway-check governance-workspace-check pack headless-check workspace-hosts-check
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/storage.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/thread_storage.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/resources.py
	$(MAKE) desktop-check WIPPY="$(abspath $(WIPPY))"

.PHONY: desktop-check fresh-pack-check
fresh-pack-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/fresh_pack.py
desktop-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/connection_ui.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/tui_smoke.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/fresh_pack.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/taskbar.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/personalization.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/announcements.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/interactions.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/close_confirmation.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/control_delivery.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/drag_failure.py
	$(MAKE) window-retirement-check WIPPY="$(abspath $(WIPPY))"
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/console.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/terminal_scroll.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/navigation.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/terminal_selection.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/lifecycle.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/client_desktop.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/local_launcher.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/recovery.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/inbox_app.py
	env GOWORK=off GOTOOLCHAIN=go1.27.0 BEE_RUNTIME="$(abspath $(WIPPY))" go run tests/hive_manager_app.go
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/timeline_app.py

include build/native.mk

ACTIONLINT ?= go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12
GITLEAKS ?= go run github.com/zricethezav/gitleaks/v8@v8.30.1
.PHONY: repository-check
repository-check:
	@command -v shellcheck >/dev/null || { echo 'Install ShellCheck to validate workflow scripts.' >&2; exit 1; }
	env GOWORK=off $(ACTIONLINT)
	env GOWORK=off $(GITLEAKS) git --log-opts=--all --redact --no-banner
	env GOWORK=off $(GITLEAKS) dir --redact --no-banner

.PHONY: installer-check
installer-check:
	sh -n install.sh tests/install.sh
	sh tests/install.sh

.PHONY: hive-runtime-check
hive-runtime-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/hive_boot.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/hive_boot.go -runtime "$(abspath $(NATIVE_WIPPY))" -nodes 20

.PHONY: hive-harness-check hive-remote-check hive-presenter-check hive-desktop-check hive-lan-check
hive-harness-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go test -race tests/hive_remote.go tests/hive_remote_test.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/hive_remote.go tests/hive_remote_test.go

hive-remote-check: hive-harness-check
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/hive_remote.go -runtime "$(abspath $(NATIVE_WIPPY))" -stall

hive-presenter-check: hive-harness-check
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/hive_remote.go -runtime "$(abspath $(NATIVE_WIPPY))" -presenter-stall

hive-desktop-check: hive-harness-check
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/hive_remote.go -runtime "$(abspath $(NATIVE_WIPPY))" -desktop

.PHONY: hive-admission-check
hive-admission-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/hive_admission.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/hive_admission.go -runtime "$(abspath $(NATIVE_WIPPY))"

hive-lan-check: hive-harness-check
	@test -n "$(HIVE_SSH)" -a -n "$(HIVE_REMOTE_RUNTIME)" -a -n "$(HIVE_HOST_ADDRESS)" -a -n "$(HIVE_CLIENT_ADDRESS)" || { echo 'Set HIVE_SSH, HIVE_REMOTE_RUNTIME, HIVE_HOST_ADDRESS and HIVE_CLIENT_ADDRESS.'; exit 1; }
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/hive_remote.go -runtime "$(abspath $(NATIVE_WIPPY))" \
		-ssh "$(HIVE_SSH)" -remote-runtime "$(HIVE_REMOTE_RUNTIME)" \
		-host-address "$(HIVE_HOST_ADDRESS)" -client-address "$(HIVE_CLIENT_ADDRESS)"

.PHONY: managed-launch-check
managed-launch-check: fixture-gateway-client
	@test -n "$(BEE_RUNTIME)" -a -n "$(BEE_CLAUDE_BIN)" -a -n "$(BEE_CODEX_BIN)" || { echo 'Set BEE_RUNTIME (combined runtime), BEE_CLAUDE_BIN and BEE_CODEX_BIN.'; exit 1; }
	env -u ANTHROPIC_API_KEY BEE_RUNTIME="$(abspath $(BEE_RUNTIME))" BEE_CLAUDE_BIN="$(BEE_CLAUDE_BIN)" BEE_CODEX_BIN="$(BEE_CODEX_BIN)" python3 tests/managed_launch.py

.PHONY: headless-check
headless-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/headless.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/headless.go "$(abspath $(WIPPY))"

.PHONY: workspace-hosts-check
workspace-hosts-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/workspace_hosts.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/workspace_hosts.go "$(abspath $(WIPPY))"

.PHONY: hive-supervisor-check
hive-supervisor-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/hive_remote.go tests/hive_supervisor_test.go tests/hive_service_bootstrap_test.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 BEE_HIVE_SUPERVISOR_RUNTIME="$(abspath $(NATIVE_WIPPY))" go test -race -count=1 -v tests/hive_remote.go tests/hive_supervisor_test.go tests/hive_service_bootstrap_test.go -run '^TestHiveSupervisor'

.PHONY: attachments-check
attachments-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" PYTHONPATH=tests python3 -c 'import lifecycle; lifecycle.detached()'

# Enabled retained-desktop owner through native Hive; explicit disposable enrollment.
.PHONY: hive-desktop-admission-check
hive-desktop-admission-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/hive_remote.go tests/hive_supervisor_test.go tests/hive_desktop_remote_test.go tests/hive_desktop_admission_test.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 BEE_HIVE_SUPERVISOR_RUNTIME="$(abspath $(NATIVE_WIPPY))" go test -race -count=1 -timeout=150s -v tests/hive_remote.go tests/hive_supervisor_test.go tests/hive_desktop_remote_test.go tests/hive_desktop_admission_test.go -run '^TestHiveDesktopAdmission$$'

.PHONY: hive-desktop-catalog-check
hive-desktop-catalog-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/hive_remote.go tests/hive_supervisor_test.go tests/hive_desktop_remote_test.go tests/hive_desktop_admission_test.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 BEE_HIVE_SUPERVISOR_RUNTIME="$(abspath $(NATIVE_WIPPY))" go test -race -count=1 -timeout=150s -v tests/hive_remote.go tests/hive_supervisor_test.go tests/hive_desktop_remote_test.go tests/hive_desktop_admission_test.go -run '^TestHiveDesktopCatalog$$'

.PHONY: connection-ui-check
connection-ui-check: pack
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/connection_ui.py

.PHONY: client-defaults-check
client-defaults-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" PYTHONPATH=tests python3 -c 'import client_desktop; client_desktop.run(defaults_probe=True)'

.PHONY: hive-manager-check
hive-manager-check: pack
	env GOWORK=off GOTOOLCHAIN=go1.27.0 BEE_RUNTIME="$(abspath $(WIPPY))" go run tests/hive_manager_app.go

.PHONY: identity-native-check
identity-native-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/identity_native.py
