# Standalone distribution uses the same native components for tools and releases.
BUILDER ?= env GOWORK=off GOTOOLCHAIN=go1.27.0 go run build/bootstrap.go
NATIVE_WIPPY ?= .wippy/bin/bee-wippy
BEE_BINARY ?= dist/bee
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
	$(MAKE) lint WIPPY="$(abspath $(NATIVE_WIPPY))"
	$(BUILDER) pack wippy.build.json --toolchain "$(abspath $(NATIVE_WIPPY))" $(if $(BEE_VERSION),--version "$(BEE_VERSION)",)
	$(if $(BEE_MODE),$(BUILDER) seal wippy.build.json --mode "$(BEE_MODE)",@true)

standalone: native-pack
	$(BUILDER) build wippy.build.json --output "$(BEE_BINARY)"

native-binary-check:
	python3 tests/native_binary.py "$(BEE_BINARY)"

BEE_RELEASE_ARCHIVE ?= dist/release/bee-$(shell go env GOOS)-$(shell go env GOARCH).tar.gz
.PHONY: release
release: native-tools
	$(MAKE) check WIPPY="$(abspath $(NATIVE_WIPPY))"
	$(MAKE) native-check
	$(MAKE) standalone
	$(MAKE) native-binary-check
	$(BUILDER) package "$(BEE_BINARY)" --output "$(BEE_RELEASE_ARCHIVE)"
