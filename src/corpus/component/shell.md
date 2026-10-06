# bee.shell

The desktop shell process (`bee.shell:main`, the `bee` command): window chrome,
the Start panel, desktop context menu, dialogs and workspace menu, built on
`bee.ui`. An application author uses the shell only through menus.

A menu is a registry entry with `meta.type: bee.menu` and `data.title`,
`data.location` (`start` or `desktop`) and `data.order`. An application appears
in a menu by listing its id in `menus` of its `meta.application` record:

| Menu | Location |
|---|---|
| `bee.shell:apps_menu` | Start panel, Apps |
| `bee.shell:system_menu` | Start panel, System: apps that inspect and manage the node |
| `bee.shell:desktop_menu` | The desktop's context menu |

Menu entries open the application's definition (`open:<definition_id>`). The
shell draws through `bee.ui:appearance` and reaches the node through
`bee.node:client`; applications do not import shell libraries.
