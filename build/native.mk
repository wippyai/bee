# Standalone distribution uses the same native components for tools and releases.
BUILDER ?= scripts/build_native.py
NATIVE_WIPPY ?= .wippy/bin/bee-wippy
BEE_BINARY ?= dist/bee
.PHONY: native-tools native-check native-pack standalone
native-tools:
	python3 "$(BUILDER)" toolchain wippy.build.json --output $(NATIVE_WIPPY)

native-check:
	$(MAKE) -C native check
	$(MAKE) -C native integration WIPPY="$(abspath $(NATIVE_WIPPY))"

native-pack:
	python3 scripts/native_pack.py "$(abspath $(NATIVE_WIPPY))"

standalone: native-pack
	python3 "$(BUILDER)" build wippy.build.json --output $(BEE_BINARY)

.PHONY: native-binary-check
native-binary-check:
	python3 tests/native_binary.py "$(BEE_BINARY)"
