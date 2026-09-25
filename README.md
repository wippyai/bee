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
curl -fsSL https://bee.wippy.ai/install.sh | sh
```

The installer takes the latest release, or the one `--version VERSION` names.
It verifies the archive's SHA-256 checksum and puts `bee` in
`~/.local/bin`. Archives are also on
[GitHub Releases](https://github.com/wippyai/bee/releases).

## Use

```sh
cd my-project
bee
```

Each project directory gets its own state and background owner. The first frame
is an empty desktop; **F1** opens Start. **Alt+Tab** switches apps, **F11**
maximizes, **F12** replaces the presenter, and **Ctrl+Q** detaches with the
message `Bee is still running; bee stop ends it`. Stop the owner with:

```sh
bee stop
```

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
bee client                    # join with control
bee attach WORKSPACE DISPLAY  # take control of one display
```

Use the workspace and display IDs from `bee desktops` for `bee attach`.
`bee observe` and `bee client` join a running node without starting one. After
`bee stop`, `bee daemon` runs the node in the foreground without a folder
workspace. From another terminal in that directory, `bee client` opens its
workspace picker; **Ctrl+]** returns to the picker.

Manage the running node's workspaces from another terminal:

```sh
bee workspace roots                                   # roots the host admits
bee workspace create Api bee:workspace_root/api --new-folder
bee workspace list
bee workspace archive WORKSPACE
bee workspace restore WORKSPACE
```

`bee workspace list --archived` shows archived IDs; `--after CURSOR` pages longer
lists. Archive only when the workspace host is stopped.

Join another Bee's Hive:

```sh
bee hive invite               # on the hive node: prints a single-use invite
bee hive join INVITE          # on the joining node, with its owner stopped
bee hive peers                # on either node: show the peer session
```

For nodes on different machines, start each owner with `BEE_MESH_ADDRESS` set
to an IP address assigned to that machine and reachable by the other node.
Set it for `bee hive join` on the joining machine as well. Bee listens on all
interfaces of that IP family so local loopback clients can attach, and
advertises only the selected address to peers.

`bee --help` lists the remaining Hive, process and runtime commands and their
arguments. The [native command grammar](docs/operations/native.md#command-grammar)
explains the launch routes.

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

Read the [agent guide](docs/development/agent-guide.md) and
[conventions](docs/development/conventions.md) before changing code.

## License

Bee code and artwork are [MIT](LICENSE). Wippy is MPL-2.0; dependencies keep
their own licenses. See [SECURITY.md](SECURITY.md) to report a vulnerability.
