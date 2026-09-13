# Native distribution

Bee can be assembled into a Linux or macOS executable on amd64 or arm64 containing Wippy, its
versioned application bundle and the `ioevents` native component. The reusable
assembler is [wippyai/builder](https://github.com/wippyai/builder); Bee selects its
inputs in `wippy.build.json` and pins the assembler in `build/builder.lock.json`.
Both repositories are currently private. No stable native release is published.

See the [native distribution audit](NATIVE_AUDIT.md) for reviewed boundaries,
fixed findings and validation evidence.

The [application and native module SDK](https://github.com/wippyai/builder/blob/main/docs/SDK.md)
documents pack/UI configuration, native factories, typed Lua exports and argument
passing. Event adapters depend on pinned runtime engine APIs.
`filesystem:watch()` remains a proposed runtime extension.

## Offline startup

Normal Bee startup must use embedded code and locally retained deployment artifacts
without downloading dependencies or requiring a reachable Hive peer. Installing or
updating modules is an explicit operation. Fresh startup, restored deployments,
restart and local client reconnect must work with external networking disabled;
see [offline acceptance](handoffs/OFFLINE_BOOT.md). Local loopback communication
remains available for clients and scoped MCP endpoints.

## Build and check

```sh
make native-tools
make check WIPPY="$PWD/.wippy/bin/bee-wippy"
make native-check
make standalone
make native-binary-check
```

The source tools and executable use the same compiled component selection.
`make native-binary-check` launches the source-free executable with literal
arguments, checks Settings recovery, the terminal, fullscreen aliases and
presenter rejoin. The fixture reads only disposable stores; it uses the source-free executable for
all application operations. The current split-bundle proof is recorded in the
[composition handoff](handoffs/STANDALONE_MODULE_COMPOSITION.md).
`build/bootstrap.go` runs the pinned Go assembler.
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

The runtime stays on Bee's existing pinned revision to preserve its TTY API.
The checksummed foundation and application-host patches retain upstream MPL-2.0
headers. Upstream changes are prepared as runtime PRs
[667](https://github.com/wippyai/runtime/pull/667) and
[668](https://github.com/wippyai/runtime/pull/668). The builder checks out committed
source into a temporary directory and verifies patches before compiling.
The complete [upstream dependency list](RUNTIME_UPSTREAM.md) tracks removal of the
patch inputs and Bee's `runtime/` directory.
The dependency-notices patch pins Nexus annotations to the source revision
containing its MIT license, as proposed in
[runtime PR #677](https://github.com/wippyai/runtime/pull/677).
The publish-dry-run patch allows credential-free publication packing with an
explicit version; [runtime PR #684](https://github.com/wippyai/runtime/pull/684)
prepares that fix upstream. Uploads still require credentials.

`BEE_VERSION=0.1.0-dev make standalone` prepares the explicitly owned modules
in `build/modules.json`. Child namespaces remain slices of their named owner;
each module has one `ns.definition`. The build freezes `src/`, runs strict lint,
checks source inventory, and packs through Wippy's existing namespace exclusions.
Source-free loading must match every pack's assigned IDs and kinds exactly.
Missing or multiply owned namespaces and extra module roots fail the build.

Claude and Codex each have a separate driver pack (`bee/driver-claude` and
`bee/driver-codex`). The shared `bee/driver` pack owns the contract, kit and
transport. Installing a driver does not activate it or grant execution: the host
still selects its profile, executable and permissions. This split passed native
bundle assembly with 17 modules and 612 entries; production launch profiles and
independent Hub publication remain separate work.

`build/bundle.py` writes checksummed artifacts under `dist/native-bundles/` and
atomically replaces `dist/bee.bundle.build.json` only after every pack passes.
The pinned Go builder assembles that generated manifest. `wippy.build.json`
remains the runtime/native/default-version input and is not resealed by packing;
failed packing preserves the previous bundle. All bundled modules receive the
selected Bee version. This is host composition, not independent Hub publication.
Runtime patches are checksum-verified and copied into the generated bundle with
their original contents and licenses.

`make bundle-check` checks ownership failures and failed-build preservation.
For coordinated validation, `BEE_BUILD_MANIFEST` can select an isolated candidate
input; `BEE_BUNDLE_MANIFEST` selects its generated output. The release runtime pin
still lacks the typed listener and Future declarations required by current Bee
source. Candidate acceptance does not make the default release build ready.
See [the runtime gate](handoffs/STATUS_RUNTIME_GATE.md) and
[composition evidence](handoffs/STANDALONE_MODULE_COMPOSITION.md).

### Component files

Component-owned WASM, templates and other files travel inside their owning pack.
Declare an `fs.directory` with a literal module-relative directory and select its
exact registry ID through Wippy's existing `embed` list in `wippy.yaml`:

```yaml
embed:
  - bee.example:assets
```

The corresponding entry uses `directory: ./assets/example` and `base: module`.
Bundle preparation freezes that directory along with source and records each
file's SHA-256 in the generation's `ownership.json`. Wippy embeds the bytes and
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

`make bundle-assets-check` packs a valid empty WASM module and a nested template,
copies only the pack to a new folder, deletes source and loose build assets, then
reads the exact bytes through Wippy's filesystem API and proves writes fail.
This verifies asset transfer and loading, not WASM execution or automatic Hive
distribution. Those remain separate runtime/application capabilities.

## Installed application and updates

```sh
./dist/bee
./dist/bee --state-dir /path/to/bee-state
./dist/bee --command bee-app run bee.settings:app
./dist/bee update
./dist/bee --base
./dist/bee runtime auth --help
```

The default state directory is the OS user configuration directory plus `bee`
(`~/.config/bee` on Linux). The caller's working directory is preserved. The build
manifest maps workspace, thread, approval, resource, credential and placement
databases into this directory, plus the placement filesystem root. Client layout
uses the adjacent `workspace.db.client` file. Explicit subsystem environment
variables override these defaults. Registry history is separate from application
databases. These mappings apply to newly assembled executables; an application
pack update alone does not change the installed launcher's defaults.

On first boot the embedded pack seeds a Wippy lock and vendor deployment.
Later boots preserve the installed selection. `update` uses the normal Wippy Hub
resolver in a staged deployment, lints against the compiled native modules,
verifies artifact hashes, then switches the activation record. Failure retains
the previous selection. Stop Bee before updating; the state directory has an
exclusive process-lifetime lock. Hub credentials and an available published Bee
module are required for real Bee updates. The [release protocol](RELEASING.md)
provides a local Hub preflight and a publication workflow. The deployment token
is configured and passed live publish authorization checks. A completed Bee upload
and update proof remain pending. In-app Hub installation is
not implemented.

The manifest's `base` mode provides explicit `--base` recovery using embedded code
and separate registry history. `bootstrap` mode seeds only the first deployment
and rejects `--base`. Neither mode resets application databases. Existing migration
checks can reject older code against newer data. Code activation requires a
restart; schema rollback requires an application-specific migration strategy.

Normal standalone launches enable event-stream logging (Wippy's `-e`) so runtime
logs go to the event bus instead of writing over the desktop. The development
launcher uses the same default. Arguments following the application name remain
literal application arguments. This native default requires rebuilding the executable;
updating an application pack does not change an already installed launcher.

`runtime` exposes the Wippy CLI directly, with its explicit logging flags. `runtime update` modifies the selected
deployment directly and bypasses standalone staging. Native code updates
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
their own state directories. Local sequential validation with two isolated Bee
installations reused 184 cache files without rewriting them. Two concurrent
installations also passed strict checking with an eight-entry cache limit and
pruning after every write. Cross-computer distribution remains untested; sharing
is opt-in. Use a directory writable only by the owning OS user.

## I/O events

The Bee-owned [native component](../native/ioevents/README.md) uses the pinned MIT
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
[release protocol](RELEASING.md) for local builds, required checks and tag rules.
The reusable builder action is pinned by full commit and shared within the
organization; native module fetching uses the consuming repository's token.

Archives contain the executable, input manifest provenance, effective Go module
files, available dependency license notices and the runtime patch sources.
Archive timestamps and ownership are normalized; pack timestamps and the native
C toolchain still affect binary reproducibility. The Linux amd64 inventory has
root notices for all linked Go modules, including the pinned MPL-2.0 registry bindings.
See the [dependency notice review](DEPENDENCY_NOTICES.md) for pending upstream reviews.
Complete those reviews and native target acceptance before publishing a
stable release. No release tag is created by development checks.

## State-directory coverage

Standalone packaging checks every shipped `db.sql.sqlite` entry against the
application's `data_env` bindings. A new database without a state-bound path
refuses packaging; a relative source default is insufficient. The client store
inherits the workspace path with a `.client` suffix. Registry history is selected
by the runtime. The host manifest also binds governance storage, so adding that
component cannot silently put its database in the launch directory.

`make native-project-nodes-check BEE_BINARY=/absolute/bee` reads the executable's
provenance manifest and verifies every declared database, the client store,
registry history and placement root. Two project nodes must use distinct files;
explicit `--state-dir` must contain those stores without creating another set
in the default state or project folder. It also checks terminal cwd, same-project
display reuse and client-only refusal. This proves the tested executable's
composition, not components absent from that executable or Hive convergence.
Explicit environment path overrides remain host-selected runtime configuration.
