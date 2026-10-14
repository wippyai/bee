# Desktop

Bee separates the node that runs applications from the shell that displays
them. The node (`bee.node`) owns workspaces, desktops and app instances; a
shell (`bee.shell`) is one display of a node and can be started, replaced or
closed while the node and its apps keep running.

## Commands

| Command | Process | Purpose |
|---|---|---|
| `bee` | `bee.shell:main` | Open the shell of this folder's node, or with an app command name (`bee claude`) open that app full-pane |
| `bee node` | `bee.node:headless` | Run this folder's node without a display |
| `bee client` | `bee.shell:client` | Display a running node's apps from an in-memory client node |

Each folder runs its own node with its own state.

## Identities

| Identity | Owner | Meaning |
|---|---|---|
| Node | Node owner | The runtime that hosts services, workspaces, desktops and app instances |
| Workspace | Node | A folder on this machine; the folder the node runs in is always one |
| Desktop | Node | A set of app instances working in one workspace; a node has several, each shown on at most one display |
| Instance | Node owner | One running app with its viewport; kept with its desktop so a starting node reopens it |
| Window | Shell | One display's placement, stacking, mode and name for an instance; two displays can show the same desktop differently |

A PID, viewport mount or launch token is an execution address, never a durable
identity. Application lifecycle, checkpoints and admission are described in
[application contracts](application_contracts.md).

## Shell

The shell shows one desktop of a node at a time and places that desktop's apps
as windows. Each window is a mount of its app's viewport.

| Key | Action |
|---|---|
| F1 | Start panel: apps grouped by the menus they name (Apps, System) |
| F3 | Workspaces: switch the shown desktop or workspace, add a workspace, rename or close a desktop |
| Alt+Tab | Next window (Shift reverses) |
| Ctrl+W | Close the focused app |
| F11 | Full pane |
| Alt+F9 | Minimize |
| F12 | Reload the display; instances and desktop stay |
| Ctrl+Q | Quit the display; apps keep running |

The mouse focuses, moves and resizes windows by their frame, uses their
controls, and opens context menus on a window, a tab or the desktop (apps
listed in `bee.shell:desktop_menu`). A user can rename a window and pick an
accent; applications cannot set those. An app's own title (`client.title`)
is shown unless the user named the window.

The shell follows the node's owner process and closes when it stops. The shell
is upgradable: on new code it hands its desktop and windows to the new
version, which reattaches their viewports and redraws.

## Node owner and displays

A display calls the node through `bee.node:client` over the Hive and watches
its events: opened and moved instances, closed instances, appearance,
workspaces and desktops, the installed app catalog, title changes, app
dialogs and attention requests. Apps ask the person confirm or text questions
through `client.query`; the node shows the dialog on the displays watching the
desktop and returns the answer to the app. A display that starts watching
receives the pending dialogs. An app that needs the person raises an
attention event and the display brings it forward.

Opening an app on a desktop starts it in that desktop's workspace. A running
singleton on the same desktop is focused instead and receives any open
arguments as navigation.

## Provider homes

A managed agent window that uses the host home runs the provider with the
operating-system user's `HOME` and the provider's own home variable,
`CODEX_HOME` for Codex and `CLAUDE_CONFIG_DIR` for Claude. Bee reads those
variables from the environment of the node owner, which inherits the
environment of the `bee` invocation that started it. A later `bee` invocation
joins the running node and does not change them. Sign in with the provider's
own CLI in that home before opening the window (for example `codex login`).
When Bee finds no login evidence in the home selected for a window, Sessions
shows a `LOGIN_REQUIRED` view with the provider's sign-in command. Bee checks
for files without opening them, so the view does not prove whether a provider
account is valid.

## Limits

- A display presents one desktop at a time.
- A node owns its workspaces and desktops. Nodes join one hive (`bee hive
  init`); each node's displays follow that node's owner.
- The node stores desktops, workspaces and instances. It does not replicate
  application data, credentials, live processes or grants across nodes.

See [component/node](../component/node.md) and
[component/shell](../component/shell.md).
