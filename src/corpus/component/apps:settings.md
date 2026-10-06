# bee.apps.settings

`bee.apps.settings:app` (Settings) holds the node's appearance and About.
Themes, backgrounds and tab style are node settings: choosing one asks the node,
which restyles every display and app (`component/ui` themes). About reads the installed
Bee packs and their Hub releases through `bee.hub.binding:call` when it opens, on
R, and after each registry commit. Edit mode asks the person, through the node's
dialogs, which namespaces this workspace may edit and for how long, and
Governance admits them as time-bounded super-edit profiles (`component/gov`).
Singleton, listed in `bee.shell:system_menu` and `bee.shell:desktop_menu`.
