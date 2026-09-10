# Standalone distribution uses the same native components for tools and releases.
BUILDER ?= env GOWORK=off GOTOOLCHAIN=go1.27.0 go run build/bootstrap.go
NATIVE_WIPPY ?= .wippy/bin/bee-wippy
BEE_BINARY ?= dist/bee
BEE_BUILD_MANIFEST ?= wippy.build.json
BEE_BUNDLE_MANIFEST ?= dist/bee.bundle.build.json
.PHONY: native-tools native-check native-bootstrap-check native-pack standalone native-binary-check
native-tools:
	$(BUILDER) toolchain wippy.build.json --output "$(NATIVE_WIPPY)"

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
