# "Build-time artifacts"

_Path: en/guides/artifacts_

> "Declaring a filesystem resource as a format-aware artifact, materializing it into a consuming project, and what the runtime reconciles automatically."

## Table of Contents

- Build-time artifacts

## Content

# Build-time artifacts


A module can ship a directory that consumers use **at build time** rather than
at runtime — most usefully, a package that other modules compile against. Wippy
calls these **artifacts**: ordinary WAPP filesystem resources marked with
`meta.artifact.format`.

This is how a shared package reaches a module in a different repository. A path
alias only resolves inside one repo; an artifact travels with the module.

[The Design Layer](../frontend/design-layer.md) explains *what* belongs in such
a package and what does not; this page is the mechanism that ships it.



## Declaring an artifact


The producer declares a normal `fs.directory` and marks it with a format:

```yaml


# src/_index.yaml

entries:
  - name: package_fs
    kind: fs.directory
    meta:
      comment: The npm package consumers materialize at build time.
      artifact:
        format: node-package
    directory: ./package
```

Nothing else changes: the resource is embedded into the WAPP like any other
`fs.directory` — list it under `embed:` in `wippy.yaml` or pass `--embed` to
`wippy publish` and `wippy pack`; a directory that is not embedded is neither
packed nor validated. Declared artifacts are **validated during module publish
and application pack**, so a malformed one fails at publish rather than in a
consumer.



## Formats


A format adapter decides how a directory is validated, what identity it has,
and where it lands. Wippy ships one built-in:

| Format | Owns subtree | Validates |
|---|---|---|
| `node-package` | `npm/` | `package.json` |

`node-package` requires a `name` and a semantic `version`, and **rejects
`preinstall`, `install`, `postinstall` and `prepare` lifecycle scripts** — a
materialized package may not execute anything on install. It writes to
`npm/<package name>` under the materialization root.

The format must be registered in the binary doing the work. Hosts may register
additional formats; duplicate names and overlapping roots are rejected.



## Materializing


Most of the time you do not run anything. Materialized outputs are reconciled
automatically during:

- full and targeted `wippy install` and `wippy update`
- cold boot
- Hub-backed dynamic install, update and uninstall

Full install, update, cold boot and runtime dependency reconciliation are
*exact*: stale outputs are pruned. A **targeted** install overlays only the
selected modules and preserves outputs belonging to modules it did not select.

Local module replacements go through the same validation and materialization
lifecycle as packed resources, so a replaced module's artifact behaves like a
published one.



### Materializing explicitly


For a build step that needs the artifact before the runtime is involved, the
CLI exposes it directly:

```bash
wippy artifacts materialize <pack.wapp> <namespace:name> [--root <directory>]
```

`--root` defaults to `.wippy`. The resource must declare `meta.artifact.format`
and that format must be registered in this CLI.

Be clear about what this command deliberately does **not** do: it does not
resolve module dependencies, does not mutate `wippy.lock`, does not invoke
package managers, and does not participate in runtime composition. It validates
one artifact out of one WAPP and writes it to disk.



### Where output lands


`artifact.materialization_root` configures the application-owned output root.
Its default is the parent of the dependency vendor directory. Each format owns
a non-overlapping subtree beneath it, so `node-package` output is always under
`<root>/npm/`.

Materialization is transactional. Content is validated and staged, managed
roots are swapped atomically under a process lock, a failure rolls back with
the surrounding registry transaction, and an interrupted swap is recovered on
the next run.



## Worked example: a shared frontend package


A producer module whose only job is to publish a package — it serves nothing at
runtime:

```yaml


# platform/ui-kit/src/_index.yaml

version: "1.0"
namespace: kickside.ui_kit

entries:
  - name: package_fs
    kind: fs.directory
    meta:
      artifact:
        format: node-package
    directory: ./package
```

A consumer materializes it into its own tree before installing dependencies:

```bash
wippy artifacts materialize kickside-ui-kit-1.5.0.wapp \
  kickside.ui_kit:package_fs --root ./.wippy
```

That writes `./.wippy/npm/@kickside/ui-kit`. The consumer picks it up with an
ordinary workspaces glob, so resolution is plain node resolution from there on:

```json
{
  "workspaces": ["./.wippy/npm/@*/*"]
}
```

```bash
npm install
```

Two things worth copying from this shape:

- **The package is its own module, not a directory inside a bigger one.** The
  artifact carries its own `package.json` version, and tying it to a module
  that changes for unrelated reasons forces a release of one every time the
  other moves.
- **The consumer resolves it as a normal dependency.** Once materialized there
  is no Wippy-specific import path, which is what lets the same source build
  inside the monorepo and outside it.



### Authoring the producer


For a package artifact there is usually **nothing to build** — the directory is
the deliverable. A CSS vocabulary package is just files plus a manifest:

```text
platform/ui-kit/
├── src/_index.yaml      # declares package_fs as the artifact
└── package/             # the directory that becomes the npm package
    ├── package.json
    ├── kx-card.css
    └── kx-state.css
```

```json
{
  "name": "@kickside/ui-kit",
  "version": "1.5.0",
  "type": "module",
  "sideEffects": ["*.css"],
  "exports": {
    "./kx-card.css": "./kx-card.css",
    "./kx-state.css": "./kx-state.css"
  },
  "files": ["kx-card.css", "kx-state.css", "package.json"]
}
```

`sideEffects` matters for a CSS-only package: without it a bundler is free to
treat an imported stylesheet as dead code and drop it.

**The package version must equal the module version.** `wippy publish`
validates this and refuses a mismatch, so bump both together. This is also the
reason to give a shared package its *own* module rather than nesting it inside
a larger one — otherwise every unrelated change to the host module forces a
release of the package, and vice versa.



### Publishing


```bash


# validate without publishing

wippy publish --dry-run --version 1.5.0 --embed package_fs



# publish

wippy publish --create --module-type library --module-visibility public --version 1.5.0 --embed package_fs
```

Declared artifacts are validated as part of publish, so a package.json that
fails the format's rules is rejected here rather than in a consumer's build.



### The dev loop


Publishing on every edit is not a dev loop. Pack the producer locally and point
the consumer's materialize step at that file instead:

```bash


# from the producer module

wippy pack /tmp/ui-kit-dev.wapp --embed package_fs



# consumers materialize from the local pack rather than the published one

UI_KIT_WAPP=/tmp/ui-kit-dev.wapp make ui-kit MOD=workflows
```

Keep that override as the *only* difference between the dev path and CI — an
environment variable that selects the pack file, with everything downstream
identical. A dev loop that materializes differently from CI stops predicting
CI.



### Wiring it into make and CI


Make the materialize step a **prerequisite of the consumer's build**, not a
thing a person remembers to run:

```make
UI_KIT_WAPP ?=

build:
	@case " $(UI_KIT_CONSUMERS) " in *" $(MOD) "*) $(MAKE) ui-kit MOD=$(MOD);; esac
	cd $(call fe_dir,$(MOD)) && npm run build
```

CI then needs no artifact-specific step at all: it runs the same `make build`,
`UI_KIT_WAPP` is unset, so the fetch-and-materialize path runs against the
published version pinned in `build-inputs`. A fresh checkout cannot compile
against a stale or missing package, and a contributor who has never heard of
artifacts still gets a correct build.



## What you still have to hand-roll


`wippy artifacts materialize` is deliberately narrow, so a build that consumes
an artifact currently glues four steps together itself. Knowing which four
saves rediscovering them:

**1. Getting the `.wapp`.** The command takes a *pack file path*, not a module
reference, and does not resolve dependencies — so something has to fetch the
producer first. The workable pattern is a tiny Wippy project whose only job is
to pin and download it:

```yaml


# build-inputs/wippy.lock — a project that exists only to fetch

directories:
  modules: .wippy
  src: ./src
modules:
  - name: kickside/ui-kit
    version: 1.5.0
    hash: be1eafd5…
```

```bash
( cd build-inputs && wippy install )
wapp=$(ls build-inputs/.wippy/vendor/kickside/ui-kit-*.wapp | grep -v sha256 | sort | tail -1)
```

Pinning it here rather than in the application lock keeps a build-time input
out of the runtime dependency graph.

**2. Materializing once per consumer**, into a root the consumer's package
manager can see:

```bash
wippy artifacts materialize "$wapp" kickside.ui_kit:package_fs --root ./ui/.wippy
```

**3. Wiring the consumer's `package.json`.** Materializing writes files; it
does not edit manifests. npm links the package only if the consumer declares
*both* the workspace glob and the dependency:

```json
{
  "workspaces": ["./.wippy/npm/@*/*"],
  "dependencies": { "@kickside/ui-kit": "*" }
}
```

The version is `*` because the materialized package carries its own. Script
this and make it idempotent — if the wiring is missing, the build fails much
later with a bare `ENOENT` on a stylesheet, which reads as a missing file
rather than as missing wiring.

**4. Running the package manager.** `materialize` does not invoke one, so
`npm install` is yours to call, after step 3.

Together, in a target that takes the consuming module as a parameter:

```make
ui-kit:
	@set -e; \
	( cd build-inputs && $(WIPPY) install ); \
	wapp=$$(ls build-inputs/.wippy/vendor/kickside/ui-kit-*.wapp | grep -v sha256 | sort | tail -1); \
	test -n "$$wapp" || { echo "no ui-kit .wapp; is the module published?"; exit 1; }; \
	$(WIPPY) artifacts materialize "$$wapp" kickside.ui_kit:package_fs --root $(DIR)/.wippy; \
	cd $(DIR) && node ../../scripts/wire-ui-kit.mjs && npm install --no-audit --no-fund
```

Make the whole target a prerequisite of the consumer's build, so a fresh
checkout cannot compile against a stale or absent package.



## Out of scope


Artifacts intentionally do not introduce a second resolver, package registry,
archive format, lock schema, Hub API, or module manifest. Build-only dependency
semantics, redistribution policy and host ABI validation are separate concerns
and are not solved here.



## Related


- [Dependency Management](./dependency-management.md) — resolving modules and
  local replacements
- [Publishing](./publishing.md) — what a published module contains
- [The Design Layer](../frontend/design-layer.md) — why a shared frontend
  vocabulary ships as a package in the first place



## Navigation

Previous: "Dependency Management" (guides/dependency-management)
Next: "Building Components" (guides/components)
