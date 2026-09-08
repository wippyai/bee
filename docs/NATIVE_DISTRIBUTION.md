# Native distribution

Bee can be assembled into one Linux amd64 executable containing Wippy, its
versioned application pack and the `ioevents` native component. The reusable
assembler is [wippyai/builder](https://github.com/wippyai/builder); Bee selects its
inputs in `wippy.build.json` and pins the assembler in `runtime/builder.lock.json`.
Both repositories are currently private. No stable native release is published.

See the [native distribution audit](NATIVE_AUDIT.md) for reviewed boundaries,
fixed findings and validation evidence.

The [application and native module SDK](https://github.com/wippyai/builder/blob/main/docs/SDK.md)
documents pack/UI configuration, native factories, typed Lua exports and argument
passing. Event adapters depend on pinned runtime engine APIs.
`filesystem:watch()` remains a proposed runtime extension.

## Build and check

```sh
make native-tools
make check WIPPY="$PWD/.wippy/bin/bee-wippy"
make native-check
make standalone
make native-binary-check
```

The source tools and executable use the same compiled component selection.
`build/bootstrap.go` runs the pinned Go assembler.
The Go assembler requires Git, Go 1.27.0, a C compiler and Git credentials that can
read the selected private modules. Running the resulting binary needs neither Go,
Wippy nor the Bee checkout. The native Terminal still requires `/bin/bash` and
runs with the OS user's authority. The current Linux build uses the platform's
C library. Other platforms require separate build and application acceptance.

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

`BEE_VERSION=0.1.0-dev make standalone` regenerates the pack and records its exact
version and hash in the manifest. Bee exports one module root definition at
`bee:definition`. Child namespaces keep their existing library/process identities;
Bee has one published module root.

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
(`~/.config/bee` on Linux). The caller's working directory is preserved. Workspace
and thread databases use this state directory unless their explicit environment
variables override it. Registry history is separate from application databases.

On first boot the embedded pack seeds a Wippy lock and vendor deployment.
Later boots preserve the installed selection. `update` uses the normal Wippy Hub
resolver in a staged deployment, lints against the compiled native modules,
verifies artifact hashes, then switches the activation record. Failure retains
the previous selection. Stop Bee before updating; the state directory has an
exclusive process-lifetime lock. Hub credentials and an available published Bee
module are required for real Bee updates. The [release protocol](RELEASING.md)
provides a local Hub preflight and a publication workflow. Hub credentials and an
actual Bee publication/update proof remain pending. In-app Hub installation is
not implemented.

The manifest's `base` mode provides explicit `--base` recovery using embedded code
and separate registry history. `bootstrap` mode seeds only the first deployment
and rejects `--base`. Neither mode resets application databases. Existing migration
checks can reject older code against newer data. Code activation requires a
restart; schema rollback requires an application-specific migration strategy.

`runtime` exposes the Wippy CLI directly. `runtime update` modifies the selected
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
C toolchain still affect binary reproducibility. Two linked Go modules currently
lack root license files in their pinned distributions; the inventory lists them.
See the [dependency notice review](DEPENDENCY_NOTICES.md) for the remaining work.
Resolve those notices and review native target acceptance before publishing a
stable release. No release tag is created by development checks.
