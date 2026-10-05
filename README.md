<p align="center">
  <a href="https://bee.wippy.ai/">
    <img src="docs/assets/logo.svg" alt="Bee" width="152">
  </a>
</p>

<h1 align="center">Bee</h1>

<p align="center">
  <a href="https://bee.wippy.ai/">Website</a> ·
  <a href="https://github.com/wippyai/bee/releases">Releases</a>
</p>

<p align="center">
  <a href="https://github.com/wippyai/bee/actions/workflows/ci.yml"><img alt="Bee CI" src="https://github.com/wippyai/bee/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://github.com/wippyai/bee/releases"><img alt="Release" src="https://img.shields.io/github/v/release/wippyai/bee?display_name=tag&include_prereleases&sort=semver"></a>
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-ffc963"></a>
</p>

Bee is a terminal desktop for coding agents, built on the
[Wippy runtime](https://github.com/wippyai/runtime). Claude Code, Codex,
Antigravity, Grok, Muse and OpenCode run as sessions with their own terminal
windows, next to a shell, your applications, and an inbox for everything that
needs you. Agents can drive other agents, and can build applications and
drivers that you approve into the running desktop.

> [!IMPORTANT]
> Bee is alpha software. Contracts still change between releases.

## Install

Linux and macOS, amd64 and arm64:

```sh
curl -fsSL https://bee.wippy.ai/install.sh | sh
```

The installer takes the latest release, or the one `--version VERSION` names,
verifies its SHA-256 checksum and puts `bee` in `~/.local/bin`.

## Use

```sh
cd my-project
bee
```

Each folder runs its own Bee node with its own state. **Sessions** starts an
agent: **N** picks one, **Enter** opens it in a window, **H** runs it headless.
Closing a window leaves the agent running; reopen it from Sessions. **X**
closes a session.

Open an agent directly:

```sh
bee claude
bee codex
bee agy
bee grok
bee muse
bee opencode
```

Desktop keys: **Alt+Tab** switches windows, **Alt+F9** minimizes, **F11**
maximizes, **Ctrl+W** closes the focused app, **Ctrl+Q** leaves the desktop.

| Command | What it does |
| --- | --- |
| `bee` | Open this folder's desktop |
| `bee NAME` | Open an app by its command name, such as `bee claude` |
| `bee client` | Display a running node's desktops |
| `bee node` | Run this folder's node without a display |
| `bee hive init` | Join every Bee node on this machine into one hive |
| `bee gov` | Revert a governed overlay to its retained baseline |

### Agents working together

Every agent reaches Bee through a scoped MCP server. With it, an agent opens
other agents' sessions, sends them work, waits for or joins their results, and
closes them. Permission prompts and approvals from every session land in
**Needs you**.

### Applications and drivers made by agents

An agent authors an application or an agent driver as an overlay, freezes it
and requests delivery. Bee checks it, and **Needs you** opens on your desktop
with one approval that names the version and the permissions it adds. Approving
it installs the overlay into the running node; an application opens on your
desktop right away. **Overlays** keeps the history and reverts a version.

## Build

Requires Git, Go and a C compiler.

```sh
make tools
make lint
make test
make build
./dist/bee
```

Releases build from the runtime commit pinned in `wippy.build.json`;
`make runtime-pin RUNTIME_VERSION=<commit>` moves the pin.

## License

Bee code and artwork are [MIT](LICENSE). Wippy is MPL-2.0; dependencies keep
their own licenses.
