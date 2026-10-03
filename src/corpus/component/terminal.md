# Terminal component

`bee/terminal` owns the replaceable presenter at `bee.terminal.service:main`,
asynchronous attachment delivery at `bee.terminal.service:delivery`, input
boundary decoding and shortcut values in `bee.terminal.types`, and desktop shell
rendering, chrome, menus, selection and dialogs at `bee.terminal`.

The host selects the component through `bee.deps:terminal` and supplies its
application, decoding and display-transfer boundary imports. The component
imports the public application SDK, shared UI helpers and desktop values directly. Host policies
select presenter spawning and viewport authority; metadata grants no authority.

The physical display remains in root launch at `bee.launch:display`. It owns the
surface and viewport lifetime, paints the initial boot frame, and retains the
last frame while a presenter is unavailable. A presenter receives a native
viewport grant. F12 retires and rejoins the presenter through the existing client
path, preserving application execution and committed desktop layout.

Delivery keeps serialized per-view input/resize queues and renders from its local
cache without blocking the input loop. Adjacent unsent resizes may coalesce;
failed or uncertain input is never retried automatically. Retiring a presenter
closes its delivery attachments through the existing cleanup lifecycle.

No store, applied migration, schema, topic or saved application definition changes
with extraction. M2 records the presenter and client requirement renames; a
composition restart selects the new definitions and host grants are reissued.
Presenter updates use F12; removal follows the host's required-root policy.
