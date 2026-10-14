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

<p align="center">
  <img src="docs/assets/bee.gif" alt="Claude Code fixes failing tests and builds a Test Watch app; Codex joins and builds a Test Lint app; both are approved once in Needs you and open as windows next to the work" width="960">
</p>

Bee is a persistent workspace your coding agents extend, built on the
[Wippy runtime](https://github.com/wippyai/runtime). Claude Code, Codex,
Antigravity, Grok, Muse and OpenCode run as sessions with their own live
terminal windows, next to a shell, your applications and **Needs you**, where
every decision waits for you. Agents drive other agents and build applications
that you and they both use, and bees on all your machines join one hive.

> [!IMPORTANT]
> Bee is alpha software. Contracts still change between releases.

## Features

- **Every coding agent in one workspace:** Claude Code, Codex, Antigravity, Grok, Muse and OpenCode run as sessions with live terminal windows; close a window and the agent keeps working.
- **Agents drive agents:** a scoped MCP server lets any agent open other agents' sessions, send them work, wait for results and talk on durable threads.
- **Bring your own MCP client:** `bee mcp connect --name "Terminal Claude"` pairs a client through **Needs you** and prints Claude Code and Codex configuration once; **Sessions → MCP clients → Revoke** cuts access.
- **Apps built on demand:** ask in plain words and an agent builds a real Wippy application: a terminal UI for you, tools for agents, its own SQLite database with migrations, and Lua tests it runs inside Bee.
- **One approval, exact permissions:** an app asks for only what it needs, such as a database, agent tools, one HTTP origin or one command in a folder; **Needs you** shows what it can do and what data it changes, and nothing is decided twice.
- **Library:** apps and drivers your agents made, versions other bees share and Hub packages in one place, with updates, history, going back and removing while keeping data.
- **Bees on every machine:** `bee hive invite` and `bee hive join` connect machines across LAN, Tailscale and WSL; displays open any bee's desktops and apps install across the hive with each bee's own approval.
- **Agent-written drivers:** agents can add support for another CLI agent as a driver you approve.
- **Docs inside:** agents read Bee's documentation offline and search the live Wippy docs before they guess.
- **Local and in Docker:** agents run natively or in Docker as your own user, with private homes and granted folders only.
- **Durable:** sessions, threads, approvals and apps survive restarts; a session resumes where it stopped.
- **Single binary:** Linux and macOS, amd64 and arm64, verified install with one command.

## Install

Linux and macOS, amd64 and arm64:

```sh
curl -fsSL https://bee.wippy.ai/install.sh | sh
```

The installer requires `curl`, `tar`, and `sha256sum` or `shasum`. It takes the
latest stable release, verifies its SHA-256 checksum and puts `bee` in
`~/.local/bin`. Add that directory to your shell's command search path if needed.
To select a release, including an alpha version:

```sh
curl -fsSL https://bee.wippy.ai/install.sh | sh -s -- --version VERSION
```

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
| `bee hive invite` | Print a token that joins another machine to this hive; it is single use and valid ten minutes to join, and a joined machine stays in the hive. Keep it running until the other machine joins |
| `bee hive join TOKEN` | Join this machine to the hive the token names; bees already running restart themselves into it |
| `bee help` | Show the commands |
| `bee gov revert OWNER` | Restore an installed application's previous version from the command line |

### Agents working together

Every agent reaches Bee through a scoped MCP server. With it, an agent opens
other agents' sessions, sends them work, waits for or joins their results, and
closes them. Permission prompts and approvals from every session land in
**Needs you**.

### Applications made by agents

Ask an agent for a tool and it builds a real Wippy application: a terminal
window for you, tools other agents call, its own database with migrations, and
Lua tests it runs inside Bee. An application asks for exactly what it needs,
such as a database, agent tools, one HTTP origin or one exact command in a
folder. **Needs you** shows one install question that names who made it, what
it can do and what data it changes; approve it and the application opens from
Start → Apps. Agents can also write drivers for other CLI agents the same way.

**Library** lists everything you can install: applications and drivers your
agents made, versions other bees in your hive share, and Hub packages. It shows
updates and history, goes back to an earlier version, and removes an
application while keeping its data.

### Bee updates

Settings → About checks the installed Bee pack against Hub. Library reviews
and applies the update. Compatible Lua updates keep the running executable;
a different runtime or a newer required native module reports **needs a newer
Bee binary**. Install a newer binary with the installer when that happens.

Release packs use `0.2.0-alpha.N`.
Each GitHub release includes `bee-<version>.wapp` and its SHA-256 checksum,
containing the same pack the release binaries embed. On a publishing machine
with the pinned Wippy toolchain and an existing `wippy auth` login, run
`make hub-publish VERSION=<version>` to verify and publish that asset to
`bee/bee`.

### Bees on every machine

```sh
bee hive invite          # on a machine whose bees should be shared
bee hive join TOKEN      # on the other machine
```

The token is single use and valid ten minutes to join; the joined machine
stays in the hive and every bee on it joins on its own, across LAN, Tailscale
and WSL. Displays open any bee's desktops, and an application one bee shares
installs on another with that bee's own approval.

## Documentation

Bee carries its documentation inside the binary, so agents read it offline
through the `docs` MCP tool and can also search the live
[Wippy docs](https://wippy.ai/llm/toc). The same pages are in
[`src/corpus`](src/corpus); start with the
[documentation map](src/corpus/docs/readme.md). For building applications,
read [application contracts](src/corpus/docs/application_contracts.md),
[delivery](src/corpus/docs/distributed_app_delivery.md) and the
[terminal toolkit](src/corpus/toolkit.md).

## Build

Build on Linux or macOS with Git, Make, Python 3.10 or newer, Go, and a C/C++
compiler. The Go toolchain version is pinned in `wippy.build.json`; Go can
fetch that version automatically. Install the Python dependencies, then build:

```sh
python3 -m venv .wippy/venv
. .wippy/venv/bin/activate
python3 -m pip install -r tests/requirements.txt
make tools
make build
./dist/bee
```

`make tools` builds the pinned runtime, native modules and builder once per
platform and build configuration, then links the verified tools from
`~/.cache/bee-tools/<key>/` into `.wippy/bin`. `make tools-key` prints that key.
Cached tools also work from a source archive. `make build` lints and packs the
application, records its checksum and compiles `dist/bee`. Build identity
records Git HEAD, or `unknown` in a source archive. `make install` builds and
installs the binary in `~/.local/bin`, keeping the previous binary as `bee.prev`.

`make runtime-pin RUNTIME_VERSION=<commit>` changes the runtime pin and its
native Go requirement. `make native-pin NATIVE_VERSION=<commit>` selects a
published commit containing Bee's native packages. For a local runtime
checkout, use `make tools RUNTIME_SOURCE=<path>` and pass the same Make
variable to subsequent build commands.

## Test

The complete verification gate runs on Linux and requires Docker for the
container-placement suites. The process guard uses Linux `/proc` and subreaper
support. Fixture agents use isolated homes and fake provider values.

```sh
make lint
python3 -m unittest discover -s build -p '*_test.py'
python3 -m unittest discover -s tests -p '*_test.py'
make check SHARDS=8
```

`make lint` checks the documentation corpus, application source and fixture
composition. After documentation edits, regenerate with `make agent-corpus-local`.
`make check` runs lint, fixture lint, Python runner tests, boot checks and all
Lua suites, then prints one status line with timing and load. Without an
explicit `SHARDS` value it uses up to four shards, depending on available CPUs.
`make test TESTS=<substring>` selects Lua entries by ID; `make test-shard
SHARDS=8 SHARD=<1..8>` runs one partition of the eight-shard plan.

The public suites and runner live in `tests/`. `tests/compose.py` creates a
copy of the application with test-only seams. Each shard has its own state,
fixture executables, databases, home and gateway port. The harness pulls
required digest-pinned Docker images before starting suite deadlines and
records that preparation time separately. Each entry checks for leaked actors,
owned OS children, registry entries, durable work, subscriptions and demand
owners. Run `go test ./...` in `native/` when changing Go code.

GitHub CI checks pushes to `main`, pull requests and manual dispatches. It
prepares the application once, runs lint and release-build contract checks,
boot checks and eight Lua shards on Linux, and combines their results in the
Check gate. Platform jobs warm native build caches when required. macOS jobs
compile and verify release targets; they do not run the Linux process guard.

`python3 tests/run.py --update-durations` records entry body and hygiene costs.
`python3 tests/budgets.py <passing results.json>` refreshes measured budgets
within the existing deadline limits.

## Release

The release workflow runs for `v*` tags and requires successful main-branch CI
on the exact tagged commit. It uses CI's prepared application and pinned
platform caches, stamps the version, and builds Linux and macOS binaries for
amd64 and arm64. A manual dispatch with `dry_run` enabled validates the same
build and packaging path without publishing.

Each release includes binary tarballs and SHA-256 checksums, plus
`bee-<version>.wapp` and its checksum. The workflow verifies that every binary
embeds the same release pack before publishing. To publish that release pack
to Hub, use `make hub-publish VERSION=<version>` with the pinned toolchain and
an existing `wippy auth` login; it verifies and publishes the downloaded asset.

## License

Bee code and artwork are [MIT](LICENSE). Wippy is MPL-2.0; dependencies keep
their own licenses.
