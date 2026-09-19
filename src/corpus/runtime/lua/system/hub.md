# "Hub"

_Path: en/lua/system/hub_

> "Browse Wippy Hub metadata and artifacts, manage credentials, and inspect the local artifact cache from Lua."

## Table of Contents

- Hub

## Content

# Hub


The `hub` module reads Wippy Hub modules, versions, dependencies, files, artifacts, and READMEs. It also manages the runtime's Hub credential override and can remove unpinned artifacts from the local cache.

This is an API reference. Catalog coordinates are illustrative; artifact, authentication, and cache operations require matching network access, credentials, lock state, and security policies.



## Loading


```lua
local hub = require("hub")
```



## Per-call Options


Network-backed catalog and artifact calls accept an optional options table with these common keys:

| Key | Type | Description |
|-----|------|-------------|
| `registry` | string | Registry URL override |
| `token` | string | API token override |
| `timeout` | duration/number | Request timeout (e.g. `"3m"` or seconds) |

Pagination-aware calls also accept `page` and `page_size`.

Authentication calls take a registry URL directly. Cache calls and package-handle methods use their own options described below.



## Modules


```lua
local result, err = hub.modules.list({
    org = "wippy",
    visibility = "public",
    type = "library",
    sort_order = "downloads_desc",
    page = 1,
    page_size = 20,
})
-- result = { items, total, page, page_size }
```

| Function | Description |
|----------|-------------|
| `hub.modules.list(opts?)` | List modules with filters |
| `hub.modules.search(query, opts?)` | Search by query string |
| `hub.modules.get(module, opts?)` | Fetch module by `org/name` or module id |
| `hub.modules.readme(module, opts?)` | Fetch README; returns `{content, filename, version}` |



### List/Search Options


| Option | Values |
|--------|--------|
| `organization_id` / `org` | string |
| `visibility` | `public`, `private`, `internal` |
| `type` | `library`, `application`, `agent`, `plugin` |
| `sort_order` | `name_asc`, `name_desc`, `created_desc`, `updated_desc`, `downloads_desc` |
| `keywords` (search) | array of strings |
| `license` (search) | string |
| `include_deprecated` (search) | boolean |



### README


```lua
local readme, err = hub.modules.readme("wippy/terminal", {
    version = "1.2.3"
})
if err then return nil, err end
print(readme.content)
```

The `version` option accepts either a version string or a table like `{id, version, label}`.



## Versions


```lua
local versions, err = hub.versions.list("wippy/terminal", {
    include_yanked = false,
    page_size = 50,
})

local v, err = hub.versions.get("wippy/terminal", "1.0.0")
```

| Function | Description |
|----------|-------------|
| `hub.versions.list(module, opts?)` | List versions for a module |
| `hub.versions.get(module, version, opts?)` | Fetch a specific version |
| `hub.versions.inspect(module, version, opts?)` | Inspect a version's artifact (downloads and reads the bundle) |
| `hub.versions.open(module, version, opts?)` | Open a version's artifact as a package handle |



### Package Handle


`hub.versions.open` downloads an artifact and returns a handle with the fields `version`, `digest`, and `packed`:

```lua
local pkg, err = hub.versions.open("wippy/terminal", "1.2.3")
if err then return nil, err end

local entries, entries_err = pkg:entries({
    kind = "function.lua",       -- string or string[], omit for all kinds
    include_data = false,        -- default true
})
-- each entry: { id = "ns:name", kind = "...", meta = {...}, data = <any> }
local _, close_err = pkg:close()
if entries_err then return nil, entries_err end
if close_err then return nil, close_err end
return entries
```

| Method | Description |
|--------|-------------|
| `pkg:metadata()` | Pack metadata map |
| `pkg:entries(opts?)` | Registry entries in the artifact; `opts.kind` filters, `opts.include_data` (default true) controls the `data` field |
| `pkg:resources()` | Embedded resources list |
| `pkg:fs(resource)` | Filesystem handle for an embedded resource |
| `pkg:close()` | Release the handle |

Entry `data` is returned without resolving `${env:...}` references.



## Local Artifact Cache


```lua
local entries, err = hub.cache.list()

local removed, err = hub.cache.remove("wippy/terminal", "1.2.3", {
    force = false,
})

local candidates, err = hub.cache.prune({
    dry_run = true,
})
```

| Function | Description |
|----------|-------------|
| `hub.cache.list()` | List cached artifacts as `{module, version, size, pinned}` records |
| `hub.cache.remove(module, version, opts?)` | Remove one cached artifact; `opts.force = true` permits removal when the lock file pins it |
| `hub.cache.prune(opts?)` | Remove artifacts not referenced by the lock file; `opts.dry_run = true` only reports candidates |

`hub.cache.remove` and `hub.cache.prune` delete files from the lock-resolved vendor directory unless their dry-run or pin protections apply.



## Dependencies


```lua
local deps, err = hub.dependencies.get("wippy/terminal", "1.0.0")
local users, err = hub.dependents.get("wippy/terminal")
```

| Function | Description |
|----------|-------------|
| `hub.dependencies.get(module, version?, opts?)` | Dependencies for a module version |
| `hub.dependents.get(module, opts?)` | Modules that depend on this one |



## Files


```lua
local files, err = hub.files.list("wippy/terminal", "1.0.0")
```

| Function | Description |
|----------|-------------|
| `hub.files.list(module, version, opts?)` | List files for a version (`version` required); returns `{items, total, page, page_size}` |



## Cache


```lua
local cached, err = hub.cache.list()
-- each entry: { module, version, size, pinned }

local ok, err = hub.cache.remove("wippy/terminal", "1.2.3", { force = true })
local pruned, err = hub.cache.prune({ dry_run = true })
```

| Function | Description |
|----------|-------------|
| `hub.cache.list(opts?)` | List cached artifacts under the vendor directory; `pinned` is `true` when the lock file references the artifact |
| `hub.cache.remove(module, version, opts?)` | Remove one cached artifact; refuses a lock-pinned artifact (kind `errors.CONFLICT`) unless `opts.force` is `true`; returns `true` |
| `hub.cache.prune(opts?)` | Remove every cached artifact the lock file does not reference; with `opts.dry_run = true` nothing is deleted; returns the pruned (or would-be-pruned) entries |

**Permissions:** `hub.cache.list`, `hub.cache.remove` (resource: module name), `hub.cache.prune`



## Authentication


Install a registry token as a runtime override. Hub consumers use it on subsequent calls without requiring a restart:

```lua
local status, err = hub.auth.authenticate("wpy_xxx")          -- default registry
local status, err = hub.auth.authenticate("wpy_xxx", "https://hub.example.com")

local status, err = hub.auth.status()
local ok, err = hub.auth.logout()
```

The token strings above are placeholders. Load real credentials from a secret-backed environment entry or another protected source; do not commit them in Lua or registry YAML.

| Function | Description |
|----------|-------------|
| `hub.auth.authenticate(token, registry?)` | Validate the token against the registry and, on success, install it as the runtime override |
| `hub.auth.status(registry?)` | Live-validate the current credential |
| `hub.auth.logout(registry?)` | Clear the runtime token override |

`status` contains `authenticated`, `registry`, and `orgs`. Identity fields (`username`, `user_id`, `scope`, `expires_at`, `expired`) are present only when authenticated. A token that fails validation is not stored; `authenticate` returns `authenticated = false`. The runtime override takes precedence over `WIPPY_TOKEN` and stored credentials.



## Permissions


Each top-level `hub.*` operation checks the matching action name, such as `hub.modules.list`, `hub.versions.open`, `hub.dependencies.get`, `hub.files.list`, `hub.auth.status`, or `hub.cache.prune`. Actions that address a module use the supplied module reference as the security resource; authentication actions use the registry URL. Package-handle methods do not perform another permission check after the authorized `hub.versions.open` call.



## See Also


- [CLI Reference](guides/cli.md) — `wippy readme`, `wippy search`, `wippy publish`
- [Publishing Guide](guides/publishing.md)



## Navigation

Previous: "TTY" (lua/system/tty)
Next: "Text Processing" (lua/text/text)
