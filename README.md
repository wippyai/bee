![Bee](docs/assets/banner.svg)

[![Bee checks](https://github.com/wippyai/bee/actions/workflows/native.yml/badge.svg)](https://github.com/wippyai/bee/actions/workflows/native.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-edbd59)](LICENSE)

Bee is a terminal desktop for coding. Run shells and command-line agents in
separate windows, switch between them, and keep your workspace preferences.
Built on [Wippy](https://github.com/wippyai/runtime).

[Install](#install) · [Run](#run) · [Development](#development) · [Documentation](docs/README.md) · [Contributing](CONTRIBUTING.md)

![Bee running Settings, Terminal and Process Manager](docs/assets/desktop.gif)

*A recording of the current desktop: change a theme, run a command, maximize the
terminal, reload the presenter, and inspect running processes.*

## Run

From any project directory:

```sh
bee
bee claude
bee codex
bee agy
```

Agent commands open fullscreen and receive the arguments you pass after their
name. They must already be installed on PATH. These are native terminal sessions;
Bee-specific agent hooks and MCP integration are not implemented yet.

Run `bee observe` in another terminal to view the running Bee read-only. It shares
the retained desktop; typing cannot control its apps. Ctrl+Q or Ctrl+] detaches
that display. If no Bee is running, observation refuses without starting one.

Named commands attach to the selected owner and launch through its admitted
catalog. Ctrl+Q detaches while retaining applications. An already-running owner
keeps its loaded code after a binary update; new command routing requires an owner
started from the current build. See [current build status](docs/handoffs/GLOBAL_BUILD.md).

## Install

**Alpha.** Native builds target Linux and macOS on amd64 and arm64.
There is no stable release download yet. Install a locally built executable onto PATH:

```sh
mkdir -p "$HOME/.local/bin"
install -m755 dist/bee "$HOME/.local/bin/bee"
export PATH="$HOME/.local/bin:$PATH"
```

Keep `~/.local/bin` on PATH in your shell configuration. Source-development
instructions are in the
[development guide](docs/DEVELOPMENT.md).

Once the first alpha is [published](https://github.com/wippyai/bee/releases),
install it with an explicit version:

```sh
curl -fsSL https://github.com/wippyai/bee/releases/download/v0.1.0-alpha.1/install.sh | sh -s -- --version 0.1.0-alpha.1
```

The installer selects Linux or macOS on amd64 or arm64, verifies the archive's
SHA-256 checksum, and installs to `~/.local/bin` without sudo. To inspect it first
or choose a destination:

```sh
curl -fLO https://github.com/wippyai/bee/releases/download/v0.1.0-alpha.1/install.sh
sh install.sh --version 0.1.0-alpha.1 --dir "$HOME/.local/bin"
```

Replace the version with the release you want. The installer's default selects
the latest stable release; alpha releases need `--version`. Installing a new binary preserves
Bee's workspace data. Archive checksums detect download corruption; they are
served by the same GitHub release as the binary.

## Inside Bee

- **Terminal** — an interactive shell, or an installed command-line program.
- **Settings** — themes, backgrounds and tab appearance.
- **Process Manager** — live process and service metrics.
- **Approvals** — requests from agents that wait on you, decided once and recorded.
- **Timeline** — a thread's records in order, as its owner committed them.
- **Hive Manager** — the Bees you can see, their status and their desktops.

Press **F1** for the menu, **Alt+Tab** to switch apps, **F11** to maximize, and
**Ctrl+Q** to quit. Drag windows by their titles and resize from their corners.
**F12** reloads the presenter while applications keep running.

Preferences and supported app checkpoints survive restart. Terminal processes
do not survive quitting Bee. Native programs run with your OS user's permissions.

## Development

Start with the [development guide](docs/DEVELOPMENT.md). Run `make check` for typed
Lua, permissions, persistence and real terminal acceptance tests.

| Code | Purpose |
|---|---|
| [src/core](src/core) | Workspace, application lifecycle, desktop and storage |
| [src/ui](src/ui) | Shared UI and application helpers |
| [src/apps](src/apps) | Bundled applications, each in its own process |
| [src/threads](src/threads) | Local event journal and replay |
| [tests](tests) | Model and runtime acceptance checks |

[What works today](docs/FOUNDATION_STATUS.md) ·
[Application contracts](docs/APPLICATION_CONTRACTS.md) ·
[Next steps](docs/FOUNDATION_NEXT.md) ·
[Documentation](docs/README.md)

Remote workspace composition and in-app self-editing are planned. The demo above
shows local behavior only.

## License

Bee-owned code is [MIT](LICENSE). Runtime patches retain MPL-2.0; dependencies
retain their own licenses.

[Contributing](CONTRIBUTING.md) · [Code of conduct](https://github.com/wippyai/.github/blob/main/.github/CODE_OF_CONDUCT.md) · [Security](SECURITY.md)
