# bee.shell

The desktop shell process (`bee.shell:main`, the `bee` command): window chrome,
the Start panel, desktop context menu, dialogs and workspace menu, built on
`bee.ui`. An application author uses the shell only through menus.

A menu is a registry entry with `meta.type: bee.menu` and `data.title`,
`data.location` (`start` or `desktop`) and `data.order`. An application appears
in a placement by listing its id in `menus` of its `meta.application` record:

| Menu | Location |
|---|---|
| `bee.shell:apps_menu` | Start list, after stock applications |
| `bee.shell:system_menu` | Start list, management applications: apps that inspect and manage the node |
| `bee.shell:desktop_menu` | The desktop's context menu |

Start flattens placements in `data.order`, showing each application once. Stock
applications declare their own placements at orders 10–60; extension placements
follow them. The default list is Agents, Needs you, Library, Terminal, Settings,
Processes, Bees, Exit. Keyboard help and MCP clients appear in the desktop context menu.

Menu entries open the application's definition (`open:<definition_id>`). The
shell draws through `bee.ui:appearance` and reaches the node through
`bee.node:client`; applications do not import shell libraries.

The shell copies text out of windows for every application: a left drag inside
a window body copies on release, a double click copies a word and a triple
click a line, Alt+Q (`bee.shell:hints`) labels the focused window's copyable
tokens, and Alt+C or the window menu's Select text opens copy mode
(`bee.shell:copy`) with cursor keys, `v`/`V`, `/` search and `y` to copy. Copy
works on a frozen snapshot of the window's visible rows and writes the
terminal clipboard through OSC 52. An application that uses left drags itself
declares `meta.application.drags: true`. Paste reaches the focused window as
one `paste` event.
