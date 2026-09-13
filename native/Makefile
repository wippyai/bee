export GOWORK := off
export GOTOOLCHAIN := go1.27.0
TAGS := fts5 sqlite_vec treesitter sqlite_preupdate_hook
.DEFAULT_GOAL := client-check
.PHONY: client-check
client-check: hive-client-check mesh-client-check rendezvous-check

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

.PHONY: rendezvous-check
rendezvous-check:
	@test -n "$(MESH_RUNTIME)" || { echo "MESH_RUNTIME must name the reviewed runtime checkout" >&2; exit 1; }
	@set -eu; testmod=$$(mktemp -d); trap 'rm -rf "$$testmod"' EXIT; \
	cp go.mod go.sum "$$testmod/"; \
	if test -n "$(MESH_RUNTIME)"; then go mod edit -modfile="$$testmod/go.mod" -replace="github.com/wippyai/runtime=$(abspath $(MESH_RUNTIME))"; fi; \
	go test -mod=mod -modfile="$$testmod/go.mod" -race -count=1 -timeout=60s -tags "$(TAGS) rendezvousintegration" ./hive/rendezvous ./internal/privatefile; \
	go vet -mod=mod -modfile="$$testmod/go.mod" -tags "$(TAGS) rendezvousintegration" ./hive/rendezvous

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
	go test -mod=mod -modfile="$$testmod/go.mod" -race -count=1 -timeout=60s -tags "$(TAGS) meshclient physicalclient" ./launch ./desktop; \
	go vet -mod=mod -modfile="$$testmod/go.mod" -tags "$(TAGS) meshclient physicalclient" ./launch ./desktop

# Requires one reviewed runtime with both native launch and clipboard APIs.
.PHONY: local-owner-selection-check
local-owner-selection-check:
	$(MAKE) local-owner-check LOCAL_OWNER_TEST_RUN=TestNativeClientSelectionComposition

# One-shot command hooks never enter runtime owner startup.
.PHONY: hook-post-check
hook-post-check:
	@test -n "$(MESH_RUNTIME)" || { echo "MESH_RUNTIME must name the reviewed runtime checkout" >&2; exit 1; }
	@set -eu; testmod=$$(mktemp -d); trap 'rm -rf "$$testmod"' EXIT; \
	cp go.mod go.sum "$$testmod/"; \
	go mod edit -modfile="$$testmod/go.mod" -replace="github.com/wippyai/runtime=$(abspath $(MESH_RUNTIME))"; \
	go test -mod=mod -modfile="$$testmod/go.mod" -race -count=1 -timeout=30s -tags "$(TAGS) meshclient physicalclient" ./hookpost ./harnesshost ./desktop; \
	go vet -mod=mod -modfile="$$testmod/go.mod" -tags "$(TAGS) meshclient physicalclient" ./hookpost ./harnesshost ./desktop
