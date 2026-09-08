WIPPY ?= .wippy/bin/wippy
.PHONY: setup run lint test threads pack check
setup:
	python3 scripts/runtime_setup.py
run:
	BEE_RUNTIME="$(abspath $(WIPPY))" bash ./run.sh
lint:
	$(WIPPY) lint
test:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/unit.py
threads:
	BEE_RUNTIME="$(abspath $(WIPPY))" python3 tests/threads.py
pack:
	mkdir -p dist
	$(WIPPY) pack dist/bee.wapp

check: lint test threads pack
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
