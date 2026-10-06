# bee.apps.processes

`bee.apps.processes:app` (Process Manager) observes this node's runtime and the
hive. While open it samples processes, services and memory each second, and on
its Hive pane each node's numbers from its owner over `bee.hive:protocol`
(`component/hive`); nothing is sampled while it is closed. Service titles come from
the services' registry entries (`meta.title`). Stopping an app asks the node.
Singleton, listed in `bee.shell:system_menu` and `bee.shell:desktop_menu`.
