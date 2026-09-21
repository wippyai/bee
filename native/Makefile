export GOWORK := off
export GOTOOLCHAIN := go1.27.0
TAGS := fts5 sqlite_vec treesitter sqlite_preupdate_hook

.PHONY: check test patched-check integration

check: test

test:
	go test -race -tags "$(TAGS)" ./...

# Run the native packages against the exact runtime checkout and patches named
# by the production build manifest. The disposable modfile keeps this module's
# dependency files unchanged.
patched-check:
	go test -race ../build/test_native.go ../build/test_native_test.go
	go vet ../build/test_native.go ../build/test_native_test.go
	go run ../build/test_native.go ../wippy.build.json .

WIPPY ?= wippy
integration:
	go run tests/integration.go "$(WIPPY)"
