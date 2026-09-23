<p align="center">
  <a href="https://bee.wippy.ai/">
    <img src="docs/assets/logo.svg" alt="Bee" width="152">
  </a>
</p>

<h1 align="center">Bee</h1>

<p align="center">
  <a href="https://bee.wippy.ai/">Website</a> ·
  <a href="docs/README.md">Documentation</a> ·
  <a href="https://github.com/wippyai/bee/releases">Releases</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

<p align="center">
  <a href="https://github.com/wippyai/bee/actions/workflows/native.yml"><img alt="Bee CI" src="https://github.com/wippyai/bee/actions/workflows/native.yml/badge.svg"></a>
  <a href="https://github.com/wippyai/bee/releases"><img alt="Release" src="https://img.shields.io/github/v/release/wippyai/bee?display_name=tag&include_prereleases&sort=semver"></a>
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-ffc963"></a>
</p>

Bee is a terminal desktop built on the [Wippy runtime](https://github.com/wippyai/runtime).
Shells, managed coding agents, applications, threads and approvals run in one
workspace as separate processes. The workspace belongs to a background owner,
so closing a terminal leaves it running. Several Bees can join into a Hive.

<p align="center">
  <img src="docs/assets/desktop.gif" alt="Bee desktop with Terminal, Settings, and Process Manager" width="100%">
</p>

> [!IMPORTANT]
> Bee is alpha software. Contracts still change between releases.

## Install

Linux and macOS, amd64 and arm64:

```sh
curl -fsSL https://bee.wippy.ai/install.sh | sh -s -- --version 0.0.1-alpha.1
```

Without `--version` the installer takes the latest stable release, and alphas
are prereleases. It verifies the archive's SHA-256 checksum and places `bee` in
`~/.local/bin`. Archives are also on
[GitHub Releases](https://github.com/wippyai/bee/releases).

## Use

```sh
cd my-project
bee
```

Each project directory gets its own state and owner. Keys: **F1** Start menu,
**Alt+Tab** switch apps, **F11** maximize, **Ctrl+Q** detach, **F12** replace
the presenter.

Managed agents:

```sh
bee claude
bee codex
bee agy
bee grok
bee muse
```

Saved profiles live in the Agent app. Agents reach Bee through a scoped MCP
gateway: threads, delivery, docs and child launch.

Attach from another terminal:

```sh
bee desktops                  # list displays of the running owner
bee observe                   # watch without control
bee attach WORKSPACE DISPLAY  # take control of one display
```

Join another Bee's Hive:

```sh
bee hive invite               # on the hive node: prints a single-use invite
bee hive join INVITE          # on the joining node, with its owner stopped
bee hive peers
```

`bee --help` lists every command.

## Build

Requires Git, Go 1.27.0 and a C compiler; see
[native distribution](docs/operations/native.md).

```sh
make setup
make check
make standalone
./dist/bee
```

Bee builds from unpatched runtime main, pinned in `wippy.build.json`.

| Path | Contents |
|---|---|
| [`src/core`](src/core) | Workspace, application, desktop and client lifecycle |
| [`src/apps`](src/apps) | Bundled applications |
| [`modules`](modules) | Components: gateway, threads, hub, governance, placement, hive and drivers |
| [`native`](native) | Launch facts and OS I/O events |

Read the [agent guide](docs/development/agent-guide.md) and
[conventions](docs/development/conventions.md) before changing code.

## License

Bee code and artwork are [MIT](LICENSE). Wippy is MPL-2.0; dependencies keep
their own licenses. See [SECURITY.md](SECURITY.md) to report a vulnerability.
