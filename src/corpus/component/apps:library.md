# bee.apps.modules

`bee.apps.modules:app` (Modules) is the Hub client: it browses packages and
installs or updates them through the public Hub facade `bee.hub.binding:call`
under the `bee.hub.read`, `bee.hub.manage` and `bee.hub.self_update` permissions.
Package credentials, registry writes and execution authority stay inside
`component/hub`. Singleton, listed in `bee.shell:system_menu`. Its model and view
are the libraries `model`, `view` and `contents`.
