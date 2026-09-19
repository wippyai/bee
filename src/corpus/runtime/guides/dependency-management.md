# "Dependency Management"

_Path: en/guides/dependency-management_

> "Declare, resolve, install, update, replace, and verify Wippy module dependencies with a lock file."

## Table of Contents

- Dependency Management

## Content

# Dependency Management


Wippy resolves module dependencies from source declarations and records exact versions in `wippy.lock`. Published modules are downloaded from the Hub into the project's module directory.

The `acme/*` module names, versions, hashes, and local paths below are illustrative.
Substitute modules and verified digests from your own project or the Hub.



### wippy.lock


The lock file tracks your project's directory layout and pinned dependencies:

```yaml
directories:
  modules: .wippy
  src: ./src
modules:
  - name: acme/http
    version: v1.2.0
    hash: 4ea816fe84ca58a1f0869e5ca6afa93d6ddd72fa09e1162d9e600a7fbf39f0a2
  - name: acme/sql
    version: v2.0.1
    hash: b3f9c8e12a456d7890abcdef1234567890abcdef1234567890abcdef12345678
```

| Field | Description |
|-------|-------------|
| `directories.modules` | Where downloaded modules are stored (default: `.wippy`) |
| `directories.src` | Where your source code lives (default: `./src`) |
| `modules[].name` | Module identifier in `org/module` format |
| `modules[].version` | Pinned semantic version |
| `modules[].hash` | Artifact digest the downloaded pack must match; a bare hex value is read as `sha256` |
| `modules[].root` | Marks the selected deployment root; at most one module may carry it |
| `options.unpack_modules` | Extract packs into directories instead of loading them as `.wapp` files (default: `false`) |



### wippy.yaml


Module metadata for publishing. Required only when you publish your own module:

```yaml
organization: acme
module: http
version: 1.2.0
description: HTTP utilities for Wippy
license: MIT
repository: https://github.com/acme/wippy-http
keywords:
  - http
  - web
```

| Field | Required | Description |
|-------|----------|-------------|
| `organization` | Yes | Lowercase, alphanumeric with hyphens |
| `module` | Yes | Lowercase, alphanumeric with hyphens |
| `version` | No | Semantic version (set at publish time) |
| `description` | No | Module description |
| `license` | No | SPDX license identifier |
| `repository` | No | Source repository URL |
| `homepage` | No | Project homepage |
| `keywords` | No | Discovery keywords |
| `authors` | No | Author list |



## Declaring Dependencies


Add `ns.dependency` entries in your `_index.yaml`:

```yaml
version: "1.0"
namespace: app
entries:
  - name: dependency.http
    kind: ns.dependency
    component: acme/http
    version: "^1.0.0"

  - name: dependency.sql
    kind: ns.dependency
    component: acme/sql
    version: ">=2.0.0"
```



### Version Constraints


| Constraint | Example | Matches |
|------------|---------|---------|
| Exact | `1.2.3` | Only 1.2.3 |
| Caret | `^1.2.0` | >=1.2.0, <2.0.0 |
| Tilde | `~1.2.0` | >=1.2.0, <1.3.0 |
| Range | `>=1.0.0` | 1.0.0 and above |
| Wildcard | `*` | Any version (picks highest) |
| Combined | `>=1.0.0 <2.0.0` | Between 1.0.0 and 2.0.0 |



### Resolution Rules


- Each module resolves against the **intersection of all declared ranges** across the dependency graph. Incompatible ranges (diamond conflicts) fail resolution with an explicit error rather than silently picking one side.
- A full `wippy update` solves every module from its declared ranges; a targeted update and boot-time repair keep a pinned version that still satisfies every live range.
- **Root parameters win over transitive ones**: when your app and a dependency both bind the same requirement, the parameters on your `ns.dependency` take precedence. Version ranges are never overridden; every declaration joins the intersection.
- A component declared by several root `ns.dependency` entries is controlled by one of them — established declarations before new ones, parameter carriers before plain ones, ties on the lowest entry ID — and the others fold into references to it. A duplicate whose parameters disagree with the controlling declaration is rejected with a conflict error; update the existing dependency instead.

Two resolution failures are reported distinctly. A constraint expression that cannot be satisfied by any release ever — the intersection of live ranges is empty — is a conflict, and the error names the module and every requester that contributed a range. A valid range set for which the hub currently publishes no matching version is an availability failure instead: a later release can make it resolvable without any change to the declarations.

The runtime persists each resolved graph in its registry history and replays it at boot instead of re-solving, so a deployed application boots with exactly the versions that were resolved when the dependency change was applied. `wippy.lock` remains the portable snapshot for source projects.



### Entry provenance


Provenance is registry-owned, not entry metadata. When entries are loaded, the registry stamps each one with the deployment source that supplied it:

| Field | Description |
|-------|-------------|
| `registry.owner` | Module name (`org/module`) that supplied the entry; empty for application source |
| `registry.root` | Set on `ns.dependency` entries supplied by the deployment root, marking them as root declarations |

Entry authors never write these fields; they are assigned during loading and cannot be forged from an `_index.yaml`. Inspect them with `wippy registry list --registry-meta --json`.



### Starting a New Project


```bash
wippy init
```

Creates a `wippy.lock` with default directories.



### Adding Dependencies


```bash
wippy add acme/http               # Latest version
wippy add acme/http@1.2.3         # Exact version
wippy add acme/http@latest         # Latest label
```

This updates the lock file. Then install:

```bash
wippy install
```



### Resolving from Source


If your source already declares `ns.dependency` entries:

```bash
wippy update
```

This scans your source directory, resolves all dependency constraints, updates the lock file, and installs modules.



### Updating Dependencies


```bash
wippy update                       # Re-resolve all dependencies
wippy update acme/http             # Update only acme/http
wippy update acme/http acme/sql    # Update specific modules
```

When updating specific modules, other modules stay pinned to their current versions. If the update would require changing non-target modules, you are prompted for confirmation.



### Installing from Lock File


```bash
wippy install                      # Install all from lock
wippy install --refresh            # Re-fetch every module (--force and --repair are aliases)
```



## Module Storage


Downloaded modules are stored under the `.wippy/vendor/` directory:

```
project/
  wippy.lock
  src/
    _index.yaml
  .wippy/
    vendor/
      acme/
        http-v1.2.0.wapp
        sql-v2.0.1.wapp
```

By default, modules are kept as `.wapp` files. To extract them into directories:

```yaml


# wippy.lock

options:
  unpack_modules: true
```

With unpacking enabled:

```
.wippy/
  vendor/
    acme/
      http-v1.2.0.wapp
      http/
        wippy.yaml
        src/
          _index.yaml
          ...
```

Unpacking never discards the pack. The canonical verified `.wapp` stays beside the extracted directory because it is the only content-addressed evidence for the module, and artifact materialization and repair read resources back out of it. The `.wapp` is what installation checks for: a directory whose pack is missing counts as not installed, and the module is downloaded again. Each install extracts the directory afresh from the verified archive, so hand-edits to a vendored directory do not survive.

Modules resolved from a [workspace replacement](#local-development-with-replacements) are never downloaded or vendored; they load from the local path.



## Local Development with Replacements


For local development, map Hub modules to local directories in the `workspace` section of a runtime configuration file. This is typically a private, ignored file composed over `.wippy.yaml`:

```yaml


# .wippy.workspace.yaml

version: "1.0"
workspace:
  replacements:
    acme/http: ../local-http
    acme/sql: ../local-sql
```

```bash
wippy run --config .wippy.yaml --config .wippy.workspace.yaml
```

Keys are `org/module`, values are directories (relative paths resolve against the first `--config` file's directory). Setting a replacement to `null` disables one inherited from an earlier config layer or profile. Replacements can also live inside a [profile](guides/configuration.md#profiles) so they activate only with `--profile workspace`.

The path is required to exist, and to be a directory, only for a module the lock graph actually selects. A replacement declared for a module that nothing depends on is a resolution input, not a boot input: it can point at a directory that is not checked out on this machine without failing validation.

A replacement changes where a module's source comes from, not which release was chosen. It keeps the selected version, while reconciliation snapshots the current local tree and records its digest and size as the replacement identity. Entries loaded from it shadow the vendored ones with the same ID. When a replacement is declared for a module the lock does not pin a version for, resolution asks the hub for a release version, and until stronger evidence selects one it holds a local-only zero version.

Workspace replacements affect the load graph at boot and are never written to `wippy.lock`. Changes to the local source are reconciled directly, without contacting the hub. The module's source `exclude:` globs from `wippy.yaml` apply to replacement directories too, both when loading entries and when hashing content.

The `replacements:` section in `wippy.lock` is deprecated. It still loads with a warning; move those entries to `workspace.replacements` in a configuration file.



## Load Order


At boot, Wippy loads entries from directories in this order:

1. Source directory (`src`)
2. Replacement directories
3. Vendored module directories

Modules with active replacements skip their vendor path.



## Integrity Verification


Every module in the lock file carries an artifact digest. Boot refuses to load a module whose lock entry has none; `wippy install` accepts such an entry and records the digest the hub serves with the download.

At boot, downloads are staged: the pack is written to a temporary file next to its final location, verified against both the digest pinned in `wippy.lock` and the digest the hub served with the download URL (plus the served size), and only then renamed into place. A staged file that fails verification is deleted. `wippy install` renames the download into its vendor path before verifying it, checks it against the served digest and size only, deletes it on failure, and replaces a lock digest that differs from the served one rather than enforcing it.

A digest mismatch is a hard, non-retryable failure. At boot it is `PermissionDenied`, "module integrity verification failed", raised for a fresh download and for an already-vendored pack, which is re-verified against the lock digest before entries are loaded. `wippy install` reports it as `Internal`: "failed to store module" wrapping "verify cached WAPP: digest mismatch" for a pack already in the vendor directory, and "failed to download module" wrapping "verify downloaded WAPP: digest mismatch" for a fresh download. Nothing retries, re-downloads over the mismatch, or falls back to the served content.

The same check guards resolution. When the hub serves a manifest whose digest differs from the one the lock pins, the manifest cache is refreshed once and re-compared; if it still disagrees, resolution fails naming both digests.

Extracted directories carry their own recorded digest, size, and tree digest, and are re-verified against the recorded values, so a modified vendored tree is detected rather than loaded.

Replacement sources are content-addressed per reconciliation attempt. The runtime
snapshots the current local tree, then verifies that same digest and size before
loading it. A concurrent change fails validation instead of mixing two source
generations. A later reconciliation can accept a new local tree; its old recorded
digest is a checkpoint, not an immutable Hub artifact identity.

On restart, immutable historical artifacts are prefetched separately. Historical
local replacements are reconciled against the final dependency declarations
before loading, so a removed replacement does not require its old directory to
remain on disk. A replacement still selected by the final graph must be present
and valid.



## Build-time Artifacts


A module can ship a filesystem resource marked with `meta.artifact.format` that consumers materialize onto disk instead of reading at runtime. Full and targeted `wippy install` and `wippy update`, cold boot, and runtime dependency operations reconcile those outputs as part of the same transaction that changes the module graph; `artifact.materialization_root` sets the output root. See [Build-time artifacts](guides/artifacts.md).



## See Also


- [Build-time artifacts](guides/artifacts.md) - Declaring, materializing and reconciling artifact resources
- [Building Components](guides/components.md) - The author side: `ns.requirement` and supplying values via `parameters`
- [CLI](guides/cli.md) - Command reference
- [Publishing](guides/publishing.md) - Publishing modules to the hub
- [Project Structure](start/structure.md) - Project layout



## Navigation

Previous: "Language Server" (guides/lsp)
Next: "Build-time artifacts" (guides/artifacts)
