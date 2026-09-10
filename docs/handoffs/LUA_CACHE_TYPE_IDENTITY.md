# Cached native type identity refusal

Current Bee source initially failed strict lint at five broker calls with
`argument 1: expected tty.Viewport, got tty.Viewport`. Rebuilding the selected
local toolchain did not fix it. The same source and toolchain passed in a fresh
source directory, and transplanting the old cache into that directory reproduced
the five failures. This isolates the refusal to persisted Lua cache state; the
precise runtime invalidation/serialization defect is not yet established.

## Reproduction artifacts

- Source: `/tmp/bee-current-lint-repro-20260909`.
- Original cache: `/tmp/bee-lint-cache-before-reset-20260909`.
- The source directory currently contains the transplanted failing cache at
  `.wippy/cache/lua`; its earlier passing cache is `.wippy/cache/lua-good`.
- Toolchain: `/tmp/bee-validation-toolchain` (manifest provenance verified).
- Failing replay: `/tmp/bee-isolated-failing-cache-replay.log`, exit 1.
- Fresh-source pass: `/tmp/bee-current-lint-isolated.log`, exit 0.

Run the strict linter from the reproduction source directory. Preserve the
failing cache before reset. No casts, type-check disabling, runtime edits or
production source changes were used to make the comparison pass.

## Local recovery

`make setup` refreshed the development toolchain using the available builder pin.
`make lint LINT_FLAGS=--cache-reset` then passed all 249 entries; a subsequent
plain `make lint` also passed. Logs:
`/tmp/bee-lint-after-cache-reset.log` and
`/tmp/bee-warm-default-lint-after-reset.log`.

`LINT_FLAGS` is opt-in. Normal lint keeps its cache, and strict types remain on.
Reset is a local recovery step, not a substitute for fixing the runtime cache
identity or invalidation problem. Do not add unconditional resets to hide it.
