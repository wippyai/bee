# Bee

An extensible terminal workspace built on Wippy. MIT licensed.

```sh
./run.sh
```

A new workspace starts with an empty desktop. Preferences and opted-in apps
(such as Settings) resume from the workspace database. **BEE / F1 → Tools** opens Settings or
Process Manager or Test Status; **BEE / F1 → Terminal** opens a normal shell. Each application runs in its own process.

Settings offers 16 themes and 11 backgrounds. Process Manager shows live process
and service state, heap and scheduler charts, GC counters and queue depth. It can
end workspace applications through the broker; core processes remain protected.
Settings → Tabs switches between labeled tabs and compact application icons.
The choice is saved with workspace preferences.

Test Status runs shared-UI checks in a separate worker and replays recorded results
after its view closes. `./run.sh --app bee.test_status:app desktop-checks first-run`
selects a thread and starts a run; repeating that run ID replays without rerunning.
See [threads](docs/THREADS.md) for the local journal's API and scheduling limits.

| Interaction | Action |
|---|---|
| Title controls | Minimize, maximize/restore, close |
| Title drag / corner drag | Move / resize |
| Right-click a title or app tab | Window actions, rename and accent |
| Right-click the desktop | Appearance and desktop actions |
| Alt+Tab / Alt+Shift+Tab | Switch applications; restore minimized tabs |
| Alt+F9 / F11 | Minimize / maximize |
| Ctrl+W / Ctrl+Q | Close application / exit Bee |
| F12 | Replace the presenter, retaining live apps and desktop state |

Terminal asks before closing its shell and running commands. When quitting Bee,
guarded applications share one confirmation; Cancel leaves them running. Typing
`exit` inside Terminal exits that shell directly. Apps may also request shell-owned
confirmation or text dialogs; see [application contracts](docs/APPLICATION_CONTRACTS.md).

Start supports nested groups, hover selection and keyboard navigation. No app is
autostarted in a new workspace. There is one application/status bar and no reserved desktop footer.

## Source organization

| Directory | Responsibility |
|---|---|
| `src/core/workspace` | Stable workspace lifetime and physical terminal ownership |
| `src/core/applications` | App admission, instances, producer lifecycle and delegated view mounts |
| `src/core/session` | Committed scene, tabs and preferences |
| `src/core/desktop` | Pure scene model and shared hit/draw geometry |
| `src/core/terminal` | Replaceable presenter, rendering, menus and input routing |
| `src/core/protocol` | Validation at process boundaries |
| `src/core/storage` | Workspace state and verified migrations |
| `src/ui` | App lifecycle helper, appearance tokens and wallpaper rendering |
| `src/apps` | Default on-demand Terminal, Settings, Process Manager and Test Status |
| `src/threads` | Native journal contract, typed consumer and owned SQLite storage |
| `examples/fixtures` | Acceptance apps, excluded from production |
| `tests` | Unit, registry and terminal acceptance checks |

Registry identities remain independent of folder paths. The current production
lock has no external dependencies. Bundling an app does not start it or give it
ambient authority; admission and capabilities are explicit.

## Development

Build the pinned runtime first (`Go 1.27.0`, Git, a C compiler and Python required):

```sh
make setup
python3 -m pip install -r tests/requirements.txt
```

The ignored `.wippy/bin/wippy` is the default. `BEE_RUNTIME` overrides the launcher;
`make WIPPY=/path/to/wippy check` selects another compatible test runtime.

```sh
make check
make pack
```

Python test dependencies are listed in `tests/requirements.txt`. Tests stage
isolated temporary workspaces and resolve their pinned test dependency from cache
or Hub. They inspect both the actual source registry and the portable pack, then
exercise real terminal sessions, colors, geometry, input isolation and recovery.

`dist/bee.wapp` runs without the source checkout. `make native-tools standalone`
assembles a single native `bee` executable; see [native distribution](docs/NATIVE_DISTRIBUTION.md)
for checks, update modes and release limits. Hub publication as `bee/bee` is still
planned; no stable native release is published.

## Current boundary

Presenter replacement preserves live app processes, their viewports, layout and
appearance. Workspace state is persisted in `.wippy/workspace.db`, separately
from registry history in `.wippy/registry.db`. Installation,
Hub discovery, workspace overlays, self-editing, agent/MCP adapters and workspace filesystem resource discovery are planned.
The optional native I/O events module is implemented with explicit resource permissions. The current broker is not yet an
untrusted-code host.

See the [documentation map](docs/README.md),
[foundation status](docs/FOUNDATION_STATUS.md),
[package boundaries](docs/PACKAGE_BOUNDARIES.md),
[workspace state](docs/WORKSPACE_STATE.md), and
[agent development guide](docs/AGENT_GUIDE.md).

The previous POC is archived outside the source tree and is neither loaded nor
packed. Native runtime code and third-party dependencies retain their own licenses.

See [current foundation status](docs/FOUNDATION_STATUS.md) and
[application contracts](docs/APPLICATION_CONTRACTS.md) for ownership and security.
Terminal requires Bash at `/bin/bash` and runs `/bin/bash -i` with local user
permissions; it is not an OS sandbox. Bash supplies interactive line editing and
history navigation; a minimal POSIX shell such as Dash does not.

Workspace state defaults to `.wippy/workspace.db`; set `BEE_WORKSPACE_DB` to
select another local workspace store. This is separate from Wippy registry history.
