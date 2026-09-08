![Bee — a terminal workspace built on Wippy](docs/assets/banner.png)

[![Foundation checks](https://github.com/wippyai/bee/actions/workflows/check.yml/badge.svg)](https://github.com/wippyai/bee/actions/workflows/check.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-edbd59)](LICENSE)

Bee is a terminal desktop for coding. Run shells and command-line agents in
separate windows, switch between them, and keep your workspace preferences.
Built on [Wippy](https://github.com/wippyai/runtime).

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

**Development preview.** Linux amd64 is the tested target. There is no stable
release download yet. Install a locally built executable onto PATH:

```sh
install -Dm755 dist/bee "$HOME/.local/bin/bee"
export PATH="$HOME/.local/bin:$PATH"
```

Keep `~/.local/bin` on PATH in your shell configuration. Native release packaging
is still being prepared; source-development instructions are in the
[development guide](docs/DEVELOPMENT.md).

## Inside Bee

- **Terminal** — an interactive shell, or an installed command-line program.
- **Settings** — themes, backgrounds and tab appearance.
- **Process Manager** — live process and service metrics.
- **Test Status** — background UI checks with recorded results you can reopen.

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
