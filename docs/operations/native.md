# Native distribution

Bee can be assembled into a Linux or macOS executable on amd64 or arm64 containing Wippy, its
versioned application pack and the `ioevents` native component. The reusable
assembler is [wippyai/builder](https://github.com/wippyai/builder); Bee selects its
inputs in `wippy.build.json` and pins the assembler in `build/builder.lock.json`.
Bee is public. No stable native release is published.

The [application and native module SDK](https://github.com/wippyai/builder/blob/main/docs/SDK.md)
documents pack/UI configuration, native factories, typed Lua exports and argument
passing. Event adapters depend on pinned runtime engine APIs.
`filesystem:watch()` remains a proposed runtime extension.

## Offline startup

Normal Bee startup must use embedded code and locally retained deployment artifacts
without downloading dependencies or requiring a reachable Hive peer. Installing or
updating modules is an explicit operation. Fresh startup, restored deployments,
restart and local client reconnect must work with external networking disabled.
Local loopback communication
remains available for clients and scoped MCP endpoints.

Explicit `--state` selects the state directory. The standalone executable
preserves the caller's working directory for native commands; application and
registry state remain in the selected state directory.

## Build and check

```sh
make native-tools
make check WIPPY="$PWD/.wippy/bin/bee-wippy"
make native-check
make native-portable-check
```

The source tools and executable use the same compiled component selection.
`make native-binary-check` launches the source-free executable with literal
arguments, checks Settings recovery, the terminal, fullscreen aliases and
presenter rejoin. The fixture reads only disposable stores; it uses the source-free
executable for all application operations.
`build/bootstrap.go` runs the pinned Go assembler.
The assembler compiles the native components at the version pinned in
`wippy.build.json`; that version comes from the module proxy, not the checkout.
A development build compiles the checked-out native sources instead:

```sh
BEE_NATIVE_LOCAL=1 make standalone
```

`build/local_native.sh` writes `native/` into a file-based Go module proxy under
a fresh worktree pseudo-version, and `build/local_native_manifest.py` rewrites a
copy of the build manifest to require it. `build/native.mk` exports that proxy
plus `GOPRIVATE=none GONOPROXY=none` and a scoped `GONOSUMDB`, because the pinned
builder resolves its `private` native modules through direct VCS. The sealed
release build leaves `BEE_NATIVE_LOCAL` unset and resolves the pinned version
exactly. A deliberate syntax error in a native source now fails the build, which
proves the development build compiles the worktree and not the cached module.
The Go assembler requires Git, Go 1.27.0, a C compiler and Git credentials that can
read the selected private modules. Running the resulting binary needs neither Go,
Wippy nor the Bee checkout. The native Terminal still requires `/bin/bash` and
runs with the OS user's authority. The current Linux build uses the platform's
C library. CI builds and exercises all four targets for release tags. Windows
desktop support still needs a replacement for the Bash/POSIX terminal assumptions.

Linux standalone acceptance also passes in a Debian Bookworm container with a
numeric non-root UID, networking disabled, a read-only root and all capabilities
dropped. Only the executable and test harness are mounted. The Terminal tolerates
an unset `USER` through Wippy's explicit empty placeholder fallback. Container
images still need Bash and a compatible C library.

The build manifest selects the runtime and any required patches. The builder
checks out the selected runtime in a temporary directory before compiling.
Uploads still require separate credentials. [Runtime integration](../development/runtime.md)
describes the boundary between Bee and the selected runtime.

`BEE_VERSION=0.1.0-dev make native-pack` stages the real root and physical module
layout only to write About metadata, then runs `wippy pack --module` for
`bee/bee` and every dependency selected by the root lock. It writes immutable
pack generations under `dist/native-packs/`, a source-free lock/vendor deployment
at `dist/portable-deployment/`, and seals every exact WAPP path and SHA-256 into
`dist/bee.bundle.build.json`. The deployment has an empty source path and no
local replacements. `make portable-deployment-check` inspects each WAPP, then
proves Linux network-isolated headless boot, restart and digest rejection after
one vendor-pack byte changes.

Agy, Claude, Codex, Grok and Muse each have a separate driver pack
(`bee/driver-agy`, `bee/driver-claude`, `bee/driver-codex`, `bee/driver-grok`
and `bee/driver-muse`). The shared `bee/driver` pack owns the contract, kit and
transport. Installing a driver does not activate it or grant execution: the host
still selects its profile, executable and permissions.

The pinned Go builder assembles only the sealed generated manifest. It verifies
every WAPP and runtime-patch hash before embedding them. The input
`wippy.build.json` remains the runtime/native/default-version input; a failed
pack or seal leaves the previous manifest and portable-deployment pointer in
place. WAPP timestamps are runtime-owned and can produce a new immutable
generation on a repeated build; each generation remains internally exact.
For coordinated validation, `BEE_BUILD_MANIFEST` can select an isolated input;
`BEE_BUNDLE_MANIFEST` selects its generated output.

### Component files

Component-owned WASM, templates and other files travel inside their owning pack.
Declare an `fs.directory` with a literal module-relative directory and select its
exact registry ID through Wippy's existing `embed` list in `wippy.yaml`:

```yaml
embed:
  - bee.example:assets
```

The corresponding entry uses `directory: ./assets/example` and `base: module`.
Wippy embeds the bytes and
changes only the selected filesystem kind from `fs.directory` to `fs.embed`;
the entry keeps its identity and remains owned by the same module. The pack
checksum covers those resources too. Installation or transfer of the pack carries
the files without depending on the source checkout.

Selection is explicit: no wildcard embedding of workspace stores, placement
homes or the host filesystem. Embedded inputs must be regular files/directories
inside the component source tree, with no symlinks or environment-selected paths.
Installed embedded files are read-only; changing shipped assets requires a new
component version through the same publication/activation boundary as its code.
Runtime-generated workspace files retain their own resource/storage owners.

## Installed application and updates

The embedded baseline contains the complete default desktop and its bundled
system applications, including Terminal, Settings, Process Manager, Timeline,
Hive Manager and About. First boot requires no Hub connection, account or
downloaded extension. The standalone acceptance harness starts with empty state,
opens the current default applications, proves that the removed Test Status app
does not return, exercises a native shell and verifies Settings recovery. Linux
release jobs run it with networking disabled.

```sh
./dist/bee
./dist/bee --state /path/to/bee-state
./dist/bee run bee.settings:app
./dist/bee update
./dist/bee recover
./dist/bee wippy auth --help
```

The default state directory is the OS user configuration directory plus `bee`
(`~/.config/bee` on Linux). The caller's working directory is preserved. The build
manifest maps workspace, thread, approval, resource, credential and placement
databases into this directory, plus the placement filesystem root. Client layout
uses the adjacent `workspace.db.client` file. Explicit subsystem environment
variables override these defaults. Registry history is separate from application
databases. These mappings apply to newly assembled executables; an application
pack update alone does not change the installed launcher's defaults.

On first boot the embedded pack seeds `deployments/<bundle-id>/wippy.lock` and
its vendor deployment.
Later boots preserve the installed selection. `update` uses the normal Wippy Hub
resolver in a staged deployment, lints against the compiled native modules,
verifies artifact hashes, then switches the activation record. Failure retains
the previous selection. Stop Bee before updating; the state directory has an
exclusive process-lifetime lock. Hub credentials and an available published Bee
module are required for real Bee updates. The [release protocol](releasing.md)
provides a local Hub preflight and publication workflow. In-app Hub installation
is not implemented.

The executable's immutable bundle is seeded under `deployments/<bundle-id>`.
`run` continues the selected deployment, while `recover` starts the shipped
bundle with a separate `recovery/registry.db` history and records its receipt.
Neither operation resets application databases. Existing migration checks can
reject older code against newer data. Code activation requires a restart; schema
rollback requires an application-specific migration strategy.

Normal standalone launches enable event-stream logging (Wippy's `-e`) so runtime
logs go to the event bus instead of writing over the desktop. The development
launcher uses the same default. Arguments following the application name remain
literal application arguments. This native default requires rebuilding the executable;
updating an application pack does not change an already installed launcher.

`wippy` exposes the Wippy CLI directly, with its explicit logging flags. `wippy
update` is the CLI operation for direct Wippy updates; the executable's `update`
operation uses standalone staging. Native code updates
require a new executable; Hub updates replace application packs. Lint catches
missing module exports and type incompatibilities, but a semantic native-version
requirement gate is not implemented.

## Shared startup cache

Wippy can share compiled Lua and type-check artifacts between local installations
using an absolute `lua.cache.dir`. Configure each installation's state-directory
`.wippy.yaml` with the same user-owned location:

```yaml
version: '1.0'
lua:
  type_system:
    enabled: true
    strict: true
  cache:
    enabled: true
    dir: /absolute/user-cache/wippy/lua
```

Cache keys include code identity, source, dependencies and compiler cache version;
type-check keys also include checker settings and native type manifests. Changed
entries are recomputed. Workspace databases and deployment selections remain in
their own state directories. Cross-computer cache sharing is opt-in; use a
directory writable only by the owning OS user.

## I/O events

The Bee-owned [native component](../../native/ioevents/README.md) uses the pinned MIT
Syncthing notify backend. Consumers declare `ioevents`, obtain an explicit named
host filesystem resource, and need both `fs.get` and `ioevents.watch` permissions.
The typed watch channel uses Wippy scheduler subscriptions with process-owned
cleanup. No application receives watcher permissions merely by importing it.

The backend reports directory change hints plus periodic rescan events. Consumers
must reconcile filesystem contents because native hints can be lost. Watches are
bounded and nonrecursive. This module does not implement the planned workspace
resource catalog or add a file browser to Bee.

## GitHub pipeline

`.github/workflows/native.yml` runs full Linux amd64 acceptance for PRs and main.
Release tags and manual runs build Linux and macOS binaries on amd64 and arm64
runners and exercise each executable. Linux acceptance disables networking.
Each target uploads an archive and checksum. Application tags also prepare a
draft GitHub release, with write permission isolated to that job. The separate
native-module workflow checks and releases the nested Go module. See the
[release protocol](releasing.md) for local builds, required checks and tag rules.
The reusable builder action is pinned by full commit and shared within the
organization; native module fetching uses the consuming repository's token.

Archives contain the executable, input manifest provenance, effective Go module
files, available dependency license notices and the runtime patch sources.
Archive timestamps and ownership are normalized; pack timestamps and the native
C toolchain still affect binary reproducibility. Each release target needs its
own dependency inventory and root license notices. See [dependency
notices](dependencies.md). Complete notice review and native target
acceptance before publishing a stable release. No release tag is created by
development checks.

## State-directory coverage

Standalone packaging checks every shipped `db.sql.sqlite` entry against the
application's `data` bindings. A new database without a state-bound path
refuses packaging; a relative source default is insufficient. The client store
inherits the workspace path with a `.client` suffix. Ordinary runs use
`registry.db`, while `recover` uses `recovery/registry.db`. The host manifest
also binds governance and sync storage, so adding either component cannot
silently put its database in the launch directory.

`make native-project-nodes-check BEE_BINARY=/absolute/bee` reads the executable's
provenance manifest and verifies every declared database, the client store,
registry history and placement root. Two project nodes must use distinct files;
explicit `--state` must contain those stores without creating another set
in the default state or project folder. It also checks terminal cwd, same-project
display reuse and client-only refusal. This proves the tested executable's
composition, not components absent from that executable or Hive convergence.
Explicit environment path overrides remain host-selected runtime configuration.
