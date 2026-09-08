WIPPY ?= .wippy/bin/bee-wippy
.PHONY: setup run lint test threads pack check
setup: native-tools
run:
	BEE_RUNTIME="$(abspath $(WIPPY))" bash ./run.sh
lint:
	"$(WIPPY)" lint --set lua.type_system.enabled=true --set lua.type_system.strict=true
test:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/unit.py
threads:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/threads.py
pack: lint
	mkdir -p dist
	"$(WIPPY)" pack dist/bee.wapp

check: installer-check lint test threads pack
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/architecture.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/storage.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/thread_storage.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/tui_smoke.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/taskbar.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/personalization.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/announcements.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/interactions.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/close_confirmation.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/control_delivery.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/drag_failure.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/console.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/navigation.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/lifecycle.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/recovery.py
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/test_status.py

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
