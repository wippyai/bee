# Workspace state and application restoration

The node owner (`bee.node.service:owner`) keeps what a restart needs in the
node database (see `docs/storage`): the node's workspaces, its desktops and
the app instances each desktop runs. Application data belongs to the
application.

## Desktops and instances

| Table | Row |
|---|---|
| `bee_node_workspaces` | a workspace folder (see `docs/workspace_catalog`) |
| `bee_node_desktops` | `id`, the `workspace_id` it works in, `title` ("Desktop N" unless given) |
| `bee_node_instances` | `id`, `desktop_id`, `workspace_id`, `app` (definition id), `args` (JSON) |

A desktop works in one workspace; apps opened on it start there unless the
open names another. Removing a desktop removes its instances. The node's own
folder is always a workspace and cannot be removed; a workspace a desktop works
in cannot be removed either. `bee.node:workspaces` offers the operations
(`ensure`, `create_desktop`, `use_workspace`, `rename_desktop`, `remove_desktop`,
`keep`, `remember`, `move_instance`, `forget`, `instances`).

An instance is kept when an app opens and forgotten when it exits. On start the
owner reopens every kept instance under its own id, desktop and workspace, with
the `args` it was opened with. A kept app that fails to reopen is forgotten.
A node with no desktop creates the first one, working in the folder the node
runs in.

## Application checkpoints

An application declares recovery in `meta.application`:

- `resume_schema`: a name of up to 80 bytes for the checkpoint format;
- `restart_policy`: `never` (default), `automatic` or `manual`; the latter two
  need a `resume_schema`.

The launch carries `resume_schema` and `resume_state`, the last saved string
(empty on a first open). The app saves with `client.checkpoint(launch, state)`
from `bee.app:client`, which returns a request id; `state` is at most 64 KiB and
the call fails when the app declares no schema. The owner accepts the checkpoint
when its `resume_schema` equals the declared one, stores it as `resume_state` in
the instance's `args` and answers with `bee.app.checkpoint_result`, whose
`error_code` is empty on success, `invalid_checkpoint` on a schema mismatch and
`storage` when the write fails. Only a successful result means the state is
stored. The state is opaque to the node; the app owns its interpretation.

The Sessions app (`bee.harness.app`, `bee.agent.window@1`, `automatic`) and the
Inbox app (`inbox.v1`, `manual`) declare recovery. Process ids, launch tokens,
terminal viewports and capabilities are recreated at every start and are never
stored.
