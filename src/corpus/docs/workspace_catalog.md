# Workspace catalog

A workspace is a folder on the machine the node runs on. The folder the node
starts in is always one. The node keeps one row per workspace in
`bee_node_workspaces`: `id` (a UUIDv7 as 32 lowercase hex digits), `path`
(unique, normalized), `label` (the folder name unless given) and `created_at`.
`bee.node:workspaces` is the library over those rows (`list`, `ensure`,
`workspace`, `remove_workspace`, `normalize`, `label_of`, `absolute`); only the
node owner and the catalog backend open the node database.

## Operations

Applications read the catalog through three functions in `bee.node.binding`:

| Function | Request | Value |
|---|---|---|
| `bee.node.binding:read` | `{workspace_id}` | `{workspace = {workspace_id, label, root_ref, subpath}}` |
| `bee.node.binding:roots` | `{}` | `{roots = [{root_ref, access}]}` in name order |
| `bee.node.binding:folders` | `{root_ref, path?, after?, limit?}` | `{root_ref, path, access, workspace_id?, folders = [{name, workspace_id?}], next_after?}` |

Every reply is `{ok, value}` or `{ok = false, error = {code, message}}`. Codes:
`INVALID`, `UNAUTHENTICATED`, `DENIED`, `FORBIDDEN` (a root the node does not
admit), `NOT_FOUND`, `UNAVAILABLE`, `STORAGE` and `UNCERTAIN` (the outcome is
unknown; do not retry blindly).

`workspace_id` is 32 lowercase hex digits. `path` and `after` are relative
folder names without `.` or `..` segments; `limit` is 1 to 100, default 50.
`folders` returns folders in name order, leaves hidden ones (a leading `.`)
out, and marks a folder that a workspace holds with its `workspace_id`.

## Roots

A root is an `fs.directory` that a `registry.entry` with
`meta.type: bee.node.roots` admits for `read` or `write`:

```yaml
- name: roots
  kind: registry.entry
  meta:
    type: bee.node.roots
  data:
    roots:
    - {root_ref: bee.node:machine, access: write}
```

The node admits `bee.node:machine` (the machine's `/`). A workspace is listed
under the admitted root that holds its folder most closely, by the subpath
inside it. A workspace under no admitted root reads as `UNAVAILABLE`.

## Authority

Each function authorizes the caller, then calls the private backend
`bee.node.binding:catalog` under the scope `bee.node.security:workspace_catalog`;
the caller holds no database or folder grant. The actions are:

| Action | Resource | For |
|---|---|---|
| `bee.node.workspace.read` | the `workspace_id` | `read` |
| `bee.node.workspace.read` | `catalog` | `roots` |
| `bee.node.workspace.browse` | the `root_ref` | `folders` |

Policies in `bee.node.security` grant them: `workspace_folder_read_policy`
(`read`) and `workspace_folder_browse_policy` (`roots`, `folders`). An
application imports the grant it needs through its admission policies.
