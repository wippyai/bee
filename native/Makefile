export GOWORK := off
export GOTOOLCHAIN := go1.27.0
TAGS := fts5 sqlite_vec treesitter sqlite_preupdate_hook
.PHONY: check test
check: test
	go vet -tags "$(TAGS)" ./...
test:
	go test -race -tags "$(TAGS)" ./...

.PHONY: rendezvous-check
rendezvous-check:
	@test -n "$(RENDEZVOUS_RUNTIME)" || { echo "RENDEZVOUS_RUNTIME must name the reviewed runtime checkout" >&2; exit 1; }
	@set -eu; testmod=$$(mktemp -d); trap 'rm -rf "$$testmod"' EXIT; \
	cp go.mod go.sum "$$testmod/"; \
	if test -n "$(RENDEZVOUS_RUNTIME)"; then go mod edit -modfile="$$testmod/go.mod" -replace="github.com/wippyai/runtime=$(abspath $(RENDEZVOUS_RUNTIME))"; fi; \
	go test -mod=mod -modfile="$$testmod/go.mod" -race -count=1 -timeout=60s -tags "$(TAGS) rendezvousintegration" ./hive/rendezvous ./internal/privatefile; \
	go vet -mod=mod -modfile="$$testmod/go.mod" -tags "$(TAGS) rendezvousintegration" ./hive/rendezvous

# For native components consuming API additions in Bee's pinned runtime patches.
.PHONY: patched-check
patched-check:
	go test -race ../build/test_native.go ../build/test_native_test.go
	go vet ../build/test_native.go ../build/test_native_test.go
	go run ../build/test_native.go ../wippy.build.json .

WIPPY ?= wippy
.PHONY: integration
integration:
	python3 tests/integration.py "$(WIPPY)"

# Boots the actual repository Hive source; does not enable production activation.
.PHONY: hive-service-check
hive-service-check:
	@set -eu; testmod=$$(mktemp -d); trap 'rm -rf "$$testmod"' EXIT; \
	cp go.mod go.sum "$$testmod/"; \
	BEE_TEST_WIPPY="$$(command -v "$(WIPPY)")" go test -mod=mod -modfile="$$testmod/go.mod" -race -count=1 -timeout=90s -tags "$(TAGS) hiveintegration" ./hive/service; \
	go vet -mod=mod -modfile="$$testmod/go.mod" -tags "$(TAGS) hiveintegration" ./hive/service

.PHONY: privatefile-windows-check
privatefile-windows-check:
	@set -eu; testbin=$$(mktemp -d); trap 'rm -rf "$$testbin"' EXIT; \
	GOOS=windows CGO_ENABLED=0 go test -c -o "$$testbin/privatefile.test.exe" ./internal/privatefile; \
	GOOS=windows CGO_ENABLED=0 go test -c -o "$$testbin/identity.test.exe" ./hive/identity; \
	GOOS=windows CGO_ENABLED=0 go vet ./internal/privatefile ./hive/identity

.PHONY: config-windows-check
config-windows-check:
	@set -eu; testbin=$$(mktemp -d); trap 'rm -rf "$$testbin"' EXIT; \
	GOOS=windows CGO_ENABLED=0 go test -c -o "$$testbin/config.test.exe" ./hive/config; \
	GOOS=windows CGO_ENABLED=0 go vet ./hive/config

# Native viewport mechanism proof; extra runtime test dependencies stay temporary.
.PHONY: display-check display-windows-check
display-check:
	@set -eu; testmod=$$(mktemp -d); trap 'rm -rf "$$testmod"' EXIT; \
	cp go.mod go.sum "$$testmod/"; \
	go test -mod=mod -modfile="$$testmod/go.mod" -race -count=1 -timeout=60s -tags "$(TAGS) displayintegration" ./client/display; \
	go vet -mod=mod -modfile="$$testmod/go.mod" -tags "$(TAGS) displayintegration" ./client/display

display-windows-check:
	@set -eu; testbin=$$(mktemp -d); trap 'rm -rf "$$testbin"' EXIT; \
	GOOS=windows CGO_ENABLED=0 go test -c -o "$$testbin/display.test.exe" ./client/display; \
	GOOS=windows CGO_ENABLED=0 go vet ./client/display

# Requires a review checkout with runtime/research/physical-input.patch applied.
.PHONY: physical-client-check
physical-client-check:
	@test -n "$(PHYSICAL_RUNTIME)" || { echo "PHYSICAL_RUNTIME must name the reviewed runtime checkout" >&2; exit 1; }
	@set -eu; testmod=$$(mktemp -d); trap 'rm -rf "$$testmod"' EXIT; \
	cp go.mod go.sum "$$testmod/"; \
	go mod edit -modfile="$$testmod/go.mod" -replace="github.com/wippyai/runtime=$(abspath $(PHYSICAL_RUNTIME))"; \
	go test -mod=mod -modfile="$$testmod/go.mod" -race -count=1 -timeout=60s -tags "$(TAGS) physicalclient" ./client/physical; \
	go vet -mod=mod -modfile="$$testmod/go.mod" -tags "$(TAGS) physicalclient" ./client/physical

.PHONY: local-client-windows-check
local-client-windows-check:
	@set -eu; testbin=$$(mktemp -d); trap 'rm -rf "$$testbin"' EXIT; \
	GOOS=windows CGO_ENABLED=0 go test -c -o "$$testbin/local.test.exe" ./client/local; \
	GOOS=windows CGO_ENABLED=0 go vet ./client/local

.PHONY: display-owner-check
display-owner-check:
	@set -eu; testmod=$$(mktemp -d); trap 'rm -rf "$$testmod"' EXIT; \
	cp go.mod go.sum "$$testmod/"; \
	go test -mod=mod -modfile="$$testmod/go.mod" -race -count=1 -timeout=60s -tags "$(TAGS) ownerintegration" ./client/owner; \
	go vet -mod=mod -modfile="$$testmod/go.mod" -tags "$(TAGS) ownerintegration" ./client/owner

.PHONY: mesh-client-check
mesh-client-check:
	@test -n "$(MESH_RUNTIME)" || { echo "MESH_RUNTIME must name the reviewed runtime checkout" >&2; exit 1; }
	@set -eu; testmod=$$(mktemp -d); trap 'rm -rf "$$testmod"' EXIT; \
	cp go.mod go.sum "$$testmod/"; \
	go mod edit -modfile="$$testmod/go.mod" -replace="github.com/wippyai/runtime=$(abspath $(MESH_RUNTIME))"; \
	go test -mod=mod -modfile="$$testmod/go.mod" -race -count=1 -timeout=90s -tags "$(TAGS) meshclient physicalclient" ./client/mesh ./client/physical; \
	go vet -mod=mod -modfile="$$testmod/go.mod" -tags "$(TAGS) meshclient physicalclient" ./client/mesh ./client/physical

# Explicit runtime gate; expected to fail until remote monitor ingress is supplied.
.PHONY: mesh-monitor-check
mesh-monitor-check:
	@test -n "$(MESH_RUNTIME)" || { echo "MESH_RUNTIME must name the reviewed runtime checkout" >&2; exit 1; }
	@set -eu; testmod=$$(mktemp -d); trap 'rm -rf "$$testmod"' EXIT; \
	cp go.mod go.sum "$$testmod/"; \
	go mod edit -modfile="$$testmod/go.mod" -replace="github.com/wippyai/runtime=$(abspath $(MESH_RUNTIME))"; \
	go test -mod=mod -modfile="$$testmod/go.mod" -race -count=1 -timeout=30s -tags "$(TAGS) meshclient meshmonitorproof" ./client/mesh -run '^TestNativeRemoteMonitorMustObserveClientActorExit$$'

.PHONY: hive-client-check
hive-client-check:
	@test -n "$(MESH_RUNTIME)" || { echo "MESH_RUNTIME must name the reviewed client runtime checkout" >&2; exit 1; }
	@set -eu; testmod=$$(mktemp -d); trap 'rm -rf "$$testmod"' EXIT; \
	cp go.mod go.sum "$$testmod/"; \
	go mod edit -modfile="$$testmod/go.mod" -replace="github.com/wippyai/runtime=$(abspath $(MESH_RUNTIME))"; \
	go test -mod=mod -modfile="$$testmod/go.mod" -race -count=1 -timeout=60s -tags "$(TAGS) meshclient" ./client/hive; \
	go vet -mod=mod -modfile="$$testmod/go.mod" -tags "$(TAGS) meshclient" ./client/hive

# Disposable supervisor round-trip client; not the public launcher.
.PHONY: hive-desktop-client-fixture
hive-desktop-client-fixture:
	@test -n "$(MESH_RUNTIME)" -a -n "$(FIXTURE_OUTPUT)" || { echo "MESH_RUNTIME and FIXTURE_OUTPUT are required" >&2; exit 1; }
	@set -eu; testmod=$$(mktemp -d); trap 'rm -rf "$$testmod"' EXIT; \
	cp go.mod go.sum "$$testmod/"; \
	go mod edit -modfile="$$testmod/go.mod" -replace="github.com/wippyai/runtime=$(abspath $(MESH_RUNTIME))"; \
	go build -race -mod=mod -modfile="$$testmod/go.mod" -tags "$(TAGS) meshclient physicalclient" -o "$(abspath $(FIXTURE_OUTPUT))" ./client/hive/testfixture

# Same-account credential provisioning uses the normal native TLS configuration.
.PHONY: local-tls-check
local-tls-check:
	@test -n "$(MESH_RUNTIME)" || { echo "MESH_RUNTIME must name the reviewed runtime checkout" >&2; exit 1; }
	@set -eu; testmod=$$(mktemp -d); trap 'rm -rf "$$testmod"' EXIT; \
	cp go.mod go.sum "$$testmod/"; \
	go mod edit -modfile="$$testmod/go.mod" -replace="github.com/wippyai/runtime=$(abspath $(MESH_RUNTIME))"; \
	go test -mod=mod -modfile="$$testmod/go.mod" -race -count=1 -timeout=60s -tags "$(TAGS) meshclient" ./hive/localtls; \
	go vet -mod=mod -modfile="$$testmod/go.mod" -tags "$(TAGS) meshclient" ./hive/localtls

LOCAL_OWNER_TEST_RUN ?= .
.PHONY: local-owner-check
local-owner-check:
	@test -n "$(MESH_RUNTIME)" || { echo "MESH_RUNTIME must name the reviewed runtime checkout" >&2; exit 1; }
	@set -eu; testmod=$$(mktemp -d); trap 'rm -rf "$$testmod"' EXIT; \
	cp go.mod go.sum "$$testmod/"; \
	go mod edit -modfile="$$testmod/go.mod" -replace="github.com/wippyai/runtime=$(abspath $(MESH_RUNTIME))"; \
	go test -mod=mod -modfile="$$testmod/go.mod" -race -count=1 -timeout=90s -run "$(LOCAL_OWNER_TEST_RUN)" -tags "$(TAGS) meshclient physicalclient" ./hive/localowner; \
	go vet -mod=mod -modfile="$$testmod/go.mod" -tags "$(TAGS) meshclient physicalclient" ./hive/localowner

.PHONY: client-session-check
client-session-check:
	@test -n "$(MESH_RUNTIME)" || { echo "MESH_RUNTIME must name the reviewed runtime checkout" >&2; exit 1; }
	@set -eu; testmod=$$(mktemp -d); trap 'rm -rf "$$testmod"' EXIT; \
	cp go.mod go.sum "$$testmod/"; \
	go mod edit -modfile="$$testmod/go.mod" -replace="github.com/wippyai/runtime=$(abspath $(MESH_RUNTIME))"; \
	go test -mod=mod -modfile="$$testmod/go.mod" -race -count=1 -timeout=60s -tags "$(TAGS) meshclient physicalclient" ./client/session; \
	go vet -mod=mod -modfile="$$testmod/go.mod" -tags "$(TAGS) meshclient physicalclient" ./client/session

.PHONY: client-launch-check
client-launch-check:
	@test -n "$(MESH_RUNTIME)" || { echo "MESH_RUNTIME must name the reviewed runtime checkout" >&2; exit 1; }
	@set -eu; testmod=$$(mktemp -d); trap 'rm -rf "$$testmod"' EXIT; \
	cp go.mod go.sum "$$testmod/"; \
	go mod edit -modfile="$$testmod/go.mod" -replace="github.com/wippyai/runtime=$(abspath $(MESH_RUNTIME))"; \
	go test -mod=mod -modfile="$$testmod/go.mod" -race -count=1 -timeout=60s -tags "$(TAGS) meshclient physicalclient" ./launch; \
	go vet -mod=mod -modfile="$$testmod/go.mod" -tags "$(TAGS) meshclient physicalclient" ./launch

# Requires one reviewed runtime with both native launch and clipboard APIs.
.PHONY: local-owner-selection-check
local-owner-selection-check:
	$(MAKE) local-owner-check LOCAL_OWNER_TEST_RUN=TestNativeClientSelectionComposition
