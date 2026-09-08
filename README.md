![Bee — a terminal workspace built on Wippy](docs/assets/banner.png)

# Bee

[![Foundation checks](https://github.com/wippyai/bee/actions/workflows/check.yml/badge.svg)](https://github.com/wippyai/bee/actions/workflows/check.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-edbd59)](LICENSE)

A terminal desktop with independent application processes, persistent workspace
preferences, and a built-in shell. Built on [Wippy](https://github.com/wippyai/runtime).

[Quick start](#quick-start) · [Applications](#applications) · [Build and test](#build-and-test) · [Documentation](docs/README.md)

**Development preview.** Linux amd64 is the tested target. Native release
workflows prepare drafts; stable releases and Bee Hub publication are pending.

## Quick start

From this checkout, build the native toolchain and standalone application:

```sh
make native-tools standalone
./dist/bee
```

Building requires Go 1.27.0, Git, a C compiler, and credentials for the selected
private repositories. Terminal requires `/bin/bash`. The resulting `bee`
executable contains Wippy, the Bee application pack, and its native modules.

Press **F1** to open the menu. Choose **Terminal** for a shell or **Tools** for
Settings, Process Manager, and Test Status. A fresh workspace starts with an empty
desktop. Preferences and applications that support recovery resume on later boots.

## Applications

| Application | What it does |
|---|---|
| **Terminal** | Runs an interactive Bash session in its own process |
| **Settings** | Selects from 16 themes, 11 backgrounds, and labeled or compact app tabs |
| **Process Manager** | Shows process and service state, memory, scheduler activity, and queue depth |
| **Test Status** | Runs UI checks in a background worker and replays their recorded results |

Apps have independent lifetimes. Closing Test Status leaves its worker running;
reopening the view loads the journal. Pressing **F12** replaces Bee's presenter
while retaining live applications, layout, and preferences.

| Control | Action |
|---|---|
| F1 | Open the application menu |
| Alt+Tab / Alt+Shift+Tab | Switch applications |
| Alt+F9 / F11 | Minimize / maximize |
| Ctrl+W / Ctrl+Q | Close the active application / exit Bee |
| F12 | Reload the presenter |
| Drag a title / corner | Move / resize a window |
| Right-click a title or tab | Window actions, custom label, and accent |

Terminal asks for confirmation before closing a running shell. Native commands
run with the local OS user's filesystem and network permissions.

## Build and test

The [Go builder](https://github.com/wippyai/builder) assembles the runtime, packs,
and native components selected in [`wippy.build.json`](wippy.build.json).
[`runtime/builder.lock.json`](runtime/builder.lock.json) pins the builder itself.

```sh
# Run editable source with the native development toolchain.
BEE_RUNTIME="$PWD/.wippy/bin/bee-wippy" ./run.sh

# Install the existing acceptance harness dependencies, then run the checks.
python3 -m pip install -r tests/requirements.txt
make check WIPPY="$PWD/.wippy/bin/bee-wippy"
make native-check native-binary-check

# Produce a portable Wippy application pack.
make pack WIPPY="$PWD/.wippy/bin/bee-wippy"
```

Checks exercise typed Lua, registry imports, process permissions, real terminal
sessions, native filesystem events, persistence, and recovery. Fixtures run in
temporary workspaces. See the [audit](docs/NATIVE_AUDIT.md) for verified behavior
and remaining release work.

## Distribution and state

The standalone binary seeds its embedded application on first boot and preserves
installed selections on subsequent launches. Base mode provides explicit recovery
from embedded code; bootstrap mode seeds only the initial deployment. Native code
changes require a new executable.

Standalone state defaults to the OS user configuration directory under `bee`.
Use `./dist/bee --state-dir /path/to/state` to select a different directory.
Source launches use `.wippy/workspace.db`; `BEE_WORKSPACE_DB` overrides the
workspace database path. Application data and runtime registry history have
separate stores.

The compiled [`ioevents` module](native/ioevents/README.md) exposes filesystem
change hints through typed Wippy channels. Watches reference named filesystem
resources and require explicit host-selected permissions. Linux Docker acceptance
covers host-originated bind-mount events; macOS, Windows, and Docker Desktop
acceptance remain pending.

See [native distribution](docs/NATIVE_DISTRIBUTION.md) for update commands,
release artifacts, state handling, and platform limits.

## Repository layout

| Path | Responsibility |
|---|---|
| [`src/core`](src/core) | Workspace, session, app admission, presenter, typed protocols, and storage |
| [`src/ui`](src/ui) | Shared appearance and application lifecycle helpers |
| [`src/apps`](src/apps) | Bundled application processes |
| [`src/threads`](src/threads) | Thread journal, client API, and persistence |
| [`native`](native) | Go components, Lua bindings, and native integration tests |
| [`build`](build) | Pinned builder bootstrap and Make targets |
| [`tests`](tests) | Model, registry, storage, and terminal acceptance checks |
| [`docs`](docs) | Implementation contracts, development guide, and proposals |

Production loads `src/`. Registry identities remain stable across directory
moves. The host selects app admission and permissions; each application owns its
process and declared resources.

## Documentation

- [Foundation status](docs/FOUNDATION_STATUS.md) — implemented behavior and ownership.
- [Application contracts](docs/APPLICATION_CONTRACTS.md) — launch, messages, dialogs, and recovery.
- [Development guide](docs/DEVELOPMENT.md) — code placement, types, permissions, and checks.
- [Native SDK](https://github.com/wippyai/builder/blob/main/docs/SDK.md) — packs, boot components, and typed Lua modules.
- [Package boundaries](docs/PACKAGE_BOUNDARIES.md) — current seams and planned installation work.

Hub installation, workspace overlays, agent/MCP adapters, and filesystem resource
discovery are proposals. The [documentation map](docs/README.md) distinguishes
implemented contracts from design work.

## License

Bee-owned code is [MIT licensed](LICENSE). Wippy runtime patches retain MPL-2.0;
third-party dependencies retain their own licenses. Release archives include
available dependency notices and runtime patch sources.
