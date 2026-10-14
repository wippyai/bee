# "Entry Registry"

_Path: en/lua/core/registry_

> "Query and modify registered entries. Access metadata, snapshots, and version history."

## Table of Contents

- Entry Registry

## Content

# Entry Registry

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="permissions"/>

Query and modify registered entries. Access metadata, snapshots, and version history.



## Loading


```lua
local registry = require("registry")
```



## Entry Structure


```lua
{
    id = "app.lib:assert",     -- string: "namespace:name"
    kind = "function.lua",     -- string: entry type
    meta = {type = "test"},    -- table: searchable metadata
    data = {...}               -- any: entry payload
}
```

Entries read back from `registry.get`, `registry.find`, `snap:entries()`, `snap:get()`, `snap:namespace()` and `snap:find()` carry only these four author-facing fields.

`dependency_root` is a write-side field accepted by `changes:create()` and `changes:update()`. It is a boolean that marks an `ns.dependency` entry as a deployment root. It is never returned by the entry APIs; registry-owned state is read through [`snap:state()`](lua/core/registry.md#snapshot-state).



## Get Entry


```lua
local entry, err = registry.get("app.lib:assert")
```

**Permission:** `registry.get` on entry ID



## Find Entries


```lua
local entries, err = registry.find({[".kind"] = "function.lua"})
local entries, err = registry.find({[".kind"] = "http.endpoint", [".ns"] = "app.api"})
```

Keys prefixed with `.` match entry fields (`.kind`, `.ns`, `.name`, `.id`) and accept `*` globs. Keys prefixed with `meta.` match entry metadata; a leading `~`, `*`, `^` or `$` on a `meta.` key selects regex, contains, prefix or suffix matching. Keys with neither prefix are ignored.



## Parse ID


```lua
local id = registry.parse_id("app.lib:assert")
-- id.ns = "app.lib", id.name = "assert"
```



## Snapshots


Point-in-time view of the registry:

```lua
local snap, err = registry.snapshot()           -- current state
local snap, err = registry.snapshot_at(5)       -- at version 5
```



### Snapshot Methods


| Method | Returns | Description |
|--------|---------|-------------|
| `snap:entries()` | `Entry[], error` | All accessible entries |
| `snap:state()` | `State, error` | Entries with registry-owned metadata, plus the resolved module graph |
| `snap:get(id)` | `Entry, error` | Single entry by ID |
| `snap:find(filter)` | `Entry[]` | Filter entries |
| `snap:namespace(ns)` | `Entry[]` | Entries in namespace |
| `snap:version()` | `Version` | Snapshot version |
| `snap:changes()` | `Changes` | Create changeset |



### Snapshot State


`snap:state()` returns the entry state together with the module graph selected for the snapshot version. Registry-owned provenance is carried on each entry rather than merged into `meta`, so it cannot be confused with authored metadata.

```lua
local snap, err = registry.snapshot()
local state, err = snap:state()

for _, entry in ipairs(state.entries) do
    print(entry.id, entry.registry.owner, entry.registry.root)
end

if state.resolution then
    print(state.resolution.digest, state.resolution.input_digest)
    for _, module in ipairs(state.resolution.modules) do
        print(module.name, module.version)
    end
end
```

Each entry in `state.entries` has the four author-facing fields plus:

- `registry.owner` - deployment source that supplied the entry
- `registry.root` - `true` when the entry is a dependency declaration selected by the deployment

`state.resolution` describes the module graph of a `registry.snapshot()` view. It is absent on snapshots that carry no graph of their own, including `registry.snapshot_at()` and overlay snapshots:

| Field | Type | Description |
|-------|------|-------------|
| `digest` | string | Content digest of the complete immutable selection |
| `input_digest` | string | Digest of the declared root set |
| `baseline_digest` | string | Digest of the deployment baseline the graph was solved against; omitted when unbound |
| `roots` | array | Authored dependency declarations used as solver inputs |
| `references` | array | Root-shaped declarations folded into an existing root for the same component; omitted when empty |
| `modules` | array | Selected modules |

`roots` and `references` entries have `id`, `component` and `version`. `modules` entries have `name` and `version`, plus `version_id`, `source`, `digest`, `size_bytes` and `protected` when set.



## Versions


```lua
local version, err = registry.current_version()
local versions, err = registry.versions()

print(version:id())       -- numeric ID
print(version:string())   -- display string
local prev = version:previous()  -- previous version or nil
local next = version:next()      -- next version or nil
```



## History


```lua
local hist, err = registry.history()
local versions, err = hist:versions()
local version, err = hist:get_version(5)
local snap, err = hist:snapshot_at(version)
```



## Changesets


Build and apply modifications:

```lua
local snap, err = registry.snapshot()
local changes = snap:changes()

changes:create({
    id = "test:new_entry",
    kind = "test.kind",
    meta = {type = "test"},
    data = {config = "value"}
})

changes:update({
    id = "test:existing",
    kind = "test.kind",
    meta = {updated = true},
    data = {new_value = true}
})

changes:delete("test:old_entry")

local new_version, err = changes:apply()
```

**Permission:** `registry.apply` for `changes:apply()`



### Deleting Entries


`changes:delete()` accepts an ID string, a table with an `id` string, a table with `ns` and `name` strings, or an array of any of those. Arrays may nest, and duplicate IDs collapse into a single delete operation.

```lua
changes:delete("test:old_entry")
changes:delete({id = "test:old_entry"})
changes:delete({ns = "test", name = "old_entry"})
changes:delete({"test:a", {ns = "test", name = "b"}, {"test:c"}})
```

An empty list, a table that references itself, and a value that is neither a string nor a table are rejected with `errors.INVALID`.



### Changes Methods


| Method | Description |
|--------|-------------|
| `changes:create(entry)` | Add create operation |
| `changes:update(entry)` | Add update operation |
| `changes:delete(id)` | Add delete operation |
| `changes:ops()` | Get pending operations |
| `changes:apply()` | Apply changes, returns new Version |



## Apply Version


Roll back or forward to a specific version:

```lua
local prev = current_version:previous()
local ok, err = registry.apply_version(prev)
```

**Permission:** `registry.apply_version`



## Build Delta


Compute operations to transition between states:

```lua
local from = {{id = "test:a", kind = "test", meta = {}, data = {}}}
local to = {{id = "test:b", kind = "test", meta = {}, data = {}}}

local ops, err = registry.build_delta(from, to)
for _, op in ipairs(ops) do
    print(op.kind, op.entry.id)  -- "entry.create", "entry.update", "entry.delete"
end
```



## Overlays


An overlay is a process-local set of registry entries owned by a logical identity. Overlay entries take part in ordinary topology and handler transitions, so services start and stop for them exactly as for durable entries, but they never advance registry history and never appear in a version. They exist only in the running process and are empty after a cold boot, so the owning control service reconciles them on startup.

```lua
local snap, err = registry.overlay("data-sources:crm")
```

**Returns:** `Snapshot, error`

The snapshot exposes the owner's overlay entries through the usual methods and reports the current registry version from `snap:version()`. It also captures the overlay generation at the moment it is opened, which is what makes writes safe.

```lua
local snap, err = registry.overlay("data-sources:crm")
if err then return nil, err end

local changes = snap:changes()
changes:create({
    id = "data.crm:connection",
    kind = "registry.entry",
    meta = {},
    data = {endpoint = "https://crm.internal"}
})

local version, err = changes:apply()
```

`changes:apply()` on an overlay snapshot writes the overlay and returns the current registry version. No history version is created, so the returned version is unchanged unless a durable change happened concurrently.



### Concurrency


Each overlay carries a generation counter that increases on every successful apply. `changes:apply()` succeeds only if the generation still matches the one captured when the snapshot was opened. A concurrent apply to the same overlay fails with `errors.CONFLICT` marked retryable: reopen the overlay and rebuild the changeset.

```lua
local last_err
for _ = 1, 3 do
    local snap, err = registry.overlay("data-sources:crm")
    if err then return nil, err end

    local _, apply_err = snap:changes():delete("data.crm:connection"):apply()
    if not apply_err then return true end
    if not apply_err:retryable() then return nil, apply_err end
    last_err = apply_err
end
return nil, last_err
```



### Restrictions


- The owner string is required and must not be blank.
- A changeset must be non-empty and must not name the same entry twice.
- `create` fails when the ID already exists in durable state or in any overlay.
- `update` and `delete` only work on entries this owner created; any other ID fails with `errors.NOT_FOUND`.
- Overlay entries cannot set `dependency_root` or any other registry-owned metadata.
- Overlay entries cannot use kinds owned by a registry directive, such as `ns.dependency`.
- A delete that removes an entry a surviving entry depends on is rejected.
- Dependencies cannot cross overlay owner boundaries, and durable entries cannot depend on overlay entries.

The rest surface as `errors.CONFLICT` or `errors.INVALID`, and none are retryable: only the generation mismatch above is.

**Permissions:** `registry.overlay.get` on the owner to open and read, `registry.overlay.apply` on the owner to write, and `registry.overlay.<create|update|delete>.<kind>` on each entry ID in the changeset.



## Permissions


| Permission | Resource | Description |
|------------|----------|-------------|
| `registry.get` | entry ID | Read entry (also filters find/entries results) |
| `registry.apply` | - | Apply changeset |
| `registry.apply_version` | - | Apply/rollback version |
| `registry.overlay.get` | owner ID | Open and read an overlay snapshot |
| `registry.overlay.apply` | owner ID | Apply an overlay changeset |
| `registry.overlay.create.<kind>` | entry ID | Create an overlay entry of that kind |
| `registry.overlay.update.<kind>` | entry ID | Update an overlay entry of that kind |
| `registry.overlay.delete.<kind>` | entry ID | Delete an overlay entry of that kind |



## Errors


| Condition | Kind |
|-----------|------|
| Entry not found | `errors.NOT_FOUND` |
| Version not found | `errors.NOT_FOUND` |
| Permission denied | `errors.PERMISSION_DENIED` |
| Invalid parameter | `errors.INVALID` |
| No changes to apply | `errors.INVALID` |
| Overlay changed during apply | `errors.CONFLICT` (retryable) |
| Overlay entry owned elsewhere or conflicts with durable state | `errors.CONFLICT` |
| Registry not available | `errors.INTERNAL` |

See [Error Handling](lua/core/errors.md) for working with errors.



## Navigation

Previous: "Event Bus" (lua/core/events)
Next: "Contracts" (lua/core/contract)
