WIPPY ?= .wippy/bin/bee-wippy
LINT_FLAGS ?=
.PHONY: setup run lint test fixture-gateway-client threads threads-module resources-module saved-profiles-check gateway-check pack check
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
.PHONY: hub-migration-runner-check
hub-migration-runner-check:
	@test -n "$(HUB_MIGRATION_PACK)" || { echo 'Set HUB_MIGRATION_PACK to the wippy/migration 0.3.17 artifact.'; exit 1; }
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/hub_migration_runner.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 BEE_RUNTIME="$(abspath $(WIPPY))" go -C native run ../tests/hub_migration_runner.go "$(HUB_MIGRATION_PACK)"
.PHONY: hub-migration-service-check
hub-migration-service-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/hub_migration_service.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 BEE_RUNTIME="$(abspath $(WIPPY))" go -C native run ../tests/hub_migration_service.go
check: hub-migration-service-check
.PHONY: native-modules-lifecycle-check
native-modules-lifecycle-check:
	python3 tests/native_modules_lifecycle.py "$(BEE_BINARY)"
.PHONY: modules-app-check
modules-app-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/modules_app.py
.PHONY: modules-update-check
modules-update-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/modules_update.py
check: modules-app-check
check: modules-update-check
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
	env GOWORK=off GOTOOLCHAIN=go1.27.0 BEE_HIVE_SUPERVISOR_RUNTIME="$(abspath $(WIPPY))" go test -race -count=1 -v tests/hive_remote.go tests/hive_supervisor_test.go tests/hive_replica_test.go -run '^TestHiveSupervisorFeeds$$'
.PHONY: governance-hive-delivery-check
governance-hive-delivery-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 BEE_HIVE_SUPERVISOR_RUNTIME="$(abspath $(WIPPY))" go test -race -count=1 -v tests/hive_remote.go tests/hive_supervisor_test.go tests/hive_replica_test.go -run '^TestHiveSupervisorReplica$$'
.PHONY: governance-runtime-check
governance-runtime-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/governance_runtime.py

.PHONY: governance-overlay-check governance-overlay-composed-base-check
governance-overlay-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/governance_overlay.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/governance_overlay.go -runtime "$(abspath $(WIPPY))" -gate owner
governance-overlay-composed-base-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/governance_overlay.go -runtime "$(abspath $(WIPPY))" -gate composed-base

.PHONY: app-journey-check
# One governed application: authored, frozen, staged, preflighted, approved,
# applied by the activation owner, admitted, opened from the desktop catalog
# and restored with its state after a host restart.
app-journey-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/app_journey.py
.PHONY: delivery-review-check
# What a person approves: the destination's own verdict, the diagnostics that
# block it, the entry set the plan changes, and the approval and activation
# record, all read back in the App Delivery review surface.
delivery-review-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/delivery_review.py
.PHONY: governance-workspace-check
governance-workspace-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/governance_workspace.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/governance_workspace.go -runtime "$(abspath $(WIPPY))"

run:
	BEE_RUNTIME="$(abspath $(WIPPY))" bash ./run.sh
lint:
	$(WIPPY) lint $(LINT_FLAGS) --set lua.type_system.enabled=true --set lua.type_system.strict=true
.PHONY: docker-configuration-check
.PHONY: docker-daemon-check
docker-daemon-check:
	test -n "$(DOCKER_COMPONENT)"
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/docker_daemon.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/docker_daemon.go -runtime "$(abspath $(WIPPY))" -docker-source "$(abspath $(DOCKER_COMPONENT))"
.PHONY: docker-boot-check
docker-boot-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/docker_boot.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/docker_boot.go -runtime "$(abspath $(WIPPY))"
docker-configuration-check:
	test -n "$(DOCKER_COMPONENT)"
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/docker_configuration.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/docker_configuration.go -runtime "$(abspath $(WIPPY))" -docker-source "$(abspath $(DOCKER_COMPONENT))"
.PHONY: docker-lifecycle-check
docker-lifecycle-check:
	test -n "$(DOCKER_COMPONENT)"
	test -n "$(DOCKER_IMAGE)"
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/docker_lifecycle.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/docker_lifecycle.go -runtime "$(abspath $(WIPPY))" -docker-source "$(DOCKER_COMPONENT)" -image "$(DOCKER_IMAGE)"
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/docker_lifecycle.go -runtime "$(abspath $(WIPPY))" -docker-source "$(DOCKER_COMPONENT)" -image "$(DOCKER_IMAGE)" -inspect-failure
.PHONY: docker-start-stop-check
docker-start-stop-check:
	test -n "$(DOCKER_COMPONENT)"
	test -n "$(DOCKER_IMAGE)"
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/docker_lifecycle.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/docker_lifecycle.go -runtime "$(abspath $(WIPPY))" -docker-source "$(DOCKER_COMPONENT)" -image "$(DOCKER_IMAGE)" -race create
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/docker_lifecycle.go -runtime "$(abspath $(WIPPY))" -docker-source "$(DOCKER_COMPONENT)" -image "$(DOCKER_IMAGE)" -race start
.PHONY: docker-agent-picker-check
docker-agent-picker-check:
	test -n "$(DOCKER_COMPONENT)"
	test -n "$(DOCKER_IMAGE)"
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/docker_agent_picker.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/docker_agent_picker.go -root "$(CURDIR)" -runtime "$(abspath $(WIPPY))" -docker-source "$(DOCKER_COMPONENT)" -image "$(DOCKER_IMAGE)"
.PHONY: codex-docker-picker-check
codex-docker-picker-check:
	test -n "$(DOCKER_COMPONENT)"
	test -n "$(CODEX_DOCKER_IMAGE)"
	test -n "$(GATEWAY_INTERFACE)"
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/docker_agent_picker.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/docker_agent_picker.go -root "$(CURDIR)" -runtime "$(abspath $(WIPPY))" -docker-source "$(DOCKER_COMPONENT)" -image "$(CODEX_DOCKER_IMAGE)" -interface "$(GATEWAY_INTERFACE)" -codex-component
.PHONY: docker-profile-component-check
docker-profile-component-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/docker_profile_component.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/docker_profile_component.go -root "$(CURDIR)" -runtime "$(abspath $(WIPPY))"
check: docker-profile-component-check
.PHONY: docker-exec-pty-check
docker-exec-pty-check:
	test -n "$(DOCKER_IMAGE)"
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/docker_exec_pty.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/docker_exec_pty.go -root "$(CURDIR)" -runtime "$(abspath $(WIPPY))" -image "$(DOCKER_IMAGE)"
.PHONY: codex-native-hooks-check
codex-native-hooks-check:
	test -n "$(CODEX)"
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/native_codex_hooks.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/native_codex_hooks.go -root "$(CURDIR)" -runtime "$(abspath $(WIPPY))" -codex "$(CODEX)"
.PHONY: docker-sandbox-check
docker-sandbox-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/docker_sandbox.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/docker_sandbox.go -runtime "$(abspath $(WIPPY))" -image "$(DOCKER_IMAGE)"
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
.PHONY: managed-window-failure-check
check: managed-window-failure-check
managed-window-failure-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/managed_window_failure.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/managed_window_failure.go -runtime "$(abspath $(WIPPY))" -root "$(CURDIR)"
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/managed_window_failure.go -runtime "$(abspath $(WIPPY))" -root "$(CURDIR)" -stage plan
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/managed_window_failure.go -runtime "$(abspath $(WIPPY))" -root "$(CURDIR)" -stage placement
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/managed_window_failure.go -runtime "$(abspath $(WIPPY))" -root "$(CURDIR)" -stage component
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/managed_window_failure.go -runtime "$(abspath $(WIPPY))" -root "$(CURDIR)" -stage generation
window-hooks-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/window_hooks.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/window_hooks.go -runtime "$(abspath $(WIPPY))"
.PHONY: window-recovery-check
check: window-recovery-check
window-recovery-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/window_hooks.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/window_hooks.go -runtime "$(abspath $(WIPPY))" -crash
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/window_hooks.go -runtime "$(abspath $(WIPPY))" -cancel-recovery
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/window_hooks.go -runtime "$(abspath $(WIPPY))" -pending-hook
.PHONY: native-agent-recovery-check
native-agent-recovery-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/native_agent_selector.go ../tests/native_agent_selector_test.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/native_agent_selector.go recovery "$(abspath $(BEE_BINARY))"
.PHONY: native-agent-crash-recovery-check
native-agent-crash-recovery-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/native_agent_selector.go ../tests/native_agent_selector_test.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/native_agent_selector.go recovery-crash "$(abspath $(BEE_BINARY))"
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
saved-profiles-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/saved_profiles.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/saved_profiles.go -runtime "$(abspath $(WIPPY))"
check: saved-profiles-check
gateway-check:
	BEE_GOVERNANCE_DB=governance.db BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/gateway.py
.PHONY: gateway-container-check gateway-readiness-check
gateway-container-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/gateway_container.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/gateway_container.go -runtime "$(abspath $(WIPPY))" -interface "$(GATEWAY_INTERFACE)" -image "$(DOCKER_IMAGE)"
gateway-readiness-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go vet tests/gateway_container.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/gateway_container.go -runtime "$(abspath $(WIPPY))" -readiness-only
check: gateway-readiness-check
pack: lint
	mkdir -p dist
	"$(WIPPY)" pack dist/bee.wapp

# Source-free acceptance boots run in disposable working directories, including
# cases without .wippy/. Keep their governance store inside that fixture too.
check desktop-check client-storage-check: export BEE_GOVERNANCE_DB = governance.db

check: identity-native-check installer-check bundle-check bundle-assets-check agent-corpus-check docs-agent-check lint test window-native-check managed-window-app-check window-hooks-check threads threads-module harness-module resources-module gateway-check governance-workspace-check pack about-check headless-check workspace-hosts-check
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/storage.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/thread_storage.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/resources.py
	$(MAKE) desktop-check WIPPY="$(abspath $(WIPPY))"

.PHONY: desktop-check fresh-pack-check about-check
about-check: pack
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/about.py
fresh-pack-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/fresh_pack.py
desktop-check: pack
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
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/inbox_decide.py
	$(MAKE) app-journey-check WIPPY="$(abspath $(WIPPY))"
	$(MAKE) delivery-review-check WIPPY="$(abspath $(WIPPY))"
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

.PHONY: managed-launch-fixture-check
managed-launch-fixture-check: fixture-gateway-client
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/managed_launch_fixture.py

.PHONY: thread-launch-check
thread-launch-check: fixture-gateway-client
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/thread_launch.py

.PHONY: docs-agent-check agent-corpus
# The embedded documentation corpus: build it from the published runtime docs
# and Bee's own contracts, or verify the committed snapshot offline.
agent-corpus:
	python3 build/agent_corpus.py
agent-corpus-check:
	python3 build/agent_corpus.py --check
# An admitted fixture agent answers three questions from the embedded corpus
# through the read-only docs tool, with no network.
docs-agent-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/docs_agent.py

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

.PHONY: modules-contents-check
modules-contents-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/modules_contents.py
check: modules-contents-check

.PHONY: native-contents-check
# Explicit live Hub probe, like native-modules-lifecycle-check.
native-contents-check:
	python3 tests/native_contents.py "$(BEE_BINARY)"

check: app-admission-check
.PHONY: app-admission-check
app-admission-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/app_admission.py

# Explicit live-provider proof: uses the installed Agy login and consumes inference.
.PHONY: research-benchmark-check
research-benchmark-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/research_benchmark.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/research_benchmark.go -root .. -runtime "$(abspath $(WIPPY))"

# Explicit live-provider proof: uses the installed Agy login and consumes
# inference. One managed agent authors a Bee application through the scoped
# Governance MCP, a person reviews and approves it, the activation owner
# applies it, and it opens as a window that survives a host restart.
.PHONY: agent-app-check
agent-app-check:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/agent_app.py

# Explicit live-provider proof: a saved Codex agent profile naming one Codex
# config profile reaches its model and does one real turn; consumes inference.
.PHONY: live-codex-profile-check live-codex-profile-lint
live-codex-profile-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/live_codex_profile.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/live_codex_profile.go -root .. -runtime "$(abspath $(WIPPY))" -profile "$(CODEX_PROFILE)"
live-codex-profile-lint:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/live_codex_profile.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/live_codex_profile.go -root .. -runtime "$(abspath $(WIPPY))" -profile "$(CODEX_PROFILE)" -lint-only

.PHONY: live-agy-mcp-check live-agy-mcp-lint
live-agy-mcp-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/live_agy_mcp.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/live_agy_mcp.go -root .. -runtime "$(abspath $(WIPPY))"
live-agy-mcp-lint:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/live_agy_mcp.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/live_agy_mcp.go -root .. -runtime "$(abspath $(WIPPY))" -lint-only

.PHONY: research-author-check research-author-lint research-repair-check
research-repair-check:
	@test -n "$(PROPOSAL)" -a -n "$(REVIEW)" || { echo 'Set PROPOSAL and REVIEW to the prior artifact and review feedback files'; exit 1; }
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/live_agy_mcp.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/live_agy_mcp.go -root .. -runtime "$(abspath $(WIPPY))" -author -proposal "$(abspath $(PROPOSAL))" -review "$(abspath $(REVIEW))"
research-author-check:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/live_agy_mcp.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/live_agy_mcp.go -root .. -runtime "$(abspath $(WIPPY))" -author
research-author-lint:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/live_agy_mcp.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/live_agy_mcp.go -root .. -runtime "$(abspath $(WIPPY))" -author -lint-only

.PHONY: research-delivery-check research-delivery-lint research-measurement-check
research-measurement-check:
	@test -n "$(ARTIFACT)" || { echo 'Set ARTIFACT to the reviewed measurable artifact JSON'; exit 1; }
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/research_delivery.go ../tests/research_desktop.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/research_delivery.go ../tests/research_desktop.go -root .. -runtime "$(abspath $(WIPPY))" -artifact "$(abspath $(ARTIFACT))" -measurement
research-delivery-lint:
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/research_delivery.go ../tests/research_desktop.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/research_delivery.go ../tests/research_desktop.go -root .. -runtime "$(abspath $(WIPPY))" -artifact "$(abspath $(ARTIFACT))" -lint-only
research-delivery-check:
	@test -n "$(ARTIFACT)" || { echo 'Set ARTIFACT to the reviewed artifact JSON'; exit 1; }
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/research_delivery.go ../tests/research_desktop.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/research_delivery.go ../tests/research_desktop.go -root .. -runtime "$(abspath $(WIPPY))" -artifact "$(abspath $(ARTIFACT))"

.PHONY: research-live-measurement-check
research-live-measurement-check:
	@test -n "$(ARTIFACT)" || (echo "ARTIFACT is required"; exit 1)
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native vet ../tests/research_delivery.go ../tests/research_desktop.go
	env GOWORK=off GOTOOLCHAIN=go1.27.0 go -C native run ../tests/research_delivery.go ../tests/research_desktop.go -root .. -runtime "$(abspath $(WIPPY))" -artifact "$(abspath $(ARTIFACT))" -measurement -live
