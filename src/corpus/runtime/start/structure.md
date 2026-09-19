# "YAML & Project Structure"

_Path: en/start/structure_

> "Project layout, YAML definition files, and naming conventions."

## Table of Contents

- YAML & Project Structure

## Content

## Directory Layout


```
myapp/
├── .wippy.yaml          # Runtime configuration
├── wippy.lock           # Source directories and locked modules
├── .wippy/              # Installed modules
└── src/                 # Application source
    ├── _index.yaml      # Entry definitions
    ├── api/
    │   ├── _index.yaml
    │   └── *.lua
    └── workers/
        ├── _index.yaml
        └── *.lua
```



## YAML Definition Files


<note>
YAML definitions are loaded into the registry at startup. The registry is the source of truth; YAML files are one way to populate it. Entries can also come from other sources or be created programmatically.
</note>



### Definition File Format


A definition file contains a `namespace` and either an `entries` array or top-level `name` and `kind` fields. The optional `version` marker is conventionally `"1.0"`; the v0.3.32a loader does not require it.

```yaml
version: "1.0"
namespace: app.api

entries:
  - name: get_user
    kind: function.lua
    meta:
      comment: Fetches user by ID
    source: file://get_user.lua
    method: handler
    modules:
      - sql
      - json

  - name: get_user.endpoint
    kind: http.endpoint
    meta:
      comment: User API endpoint
    method: GET
    path: /users/{id}
    func: get_user
```

| Field | Required | Description |
|-------|----------|-------------|
| `version` | No | Manifest version marker (conventionally `"1.0"`) |
| `namespace` | Yes | Entry namespace for this file |
| `entries` | Conditional | Array of entry definitions; omit only when using top-level `name` and `kind` |



### Naming Convention


Use dots (`.`) for semantic separation and underscores (`_`) for words:

```yaml


# Function and its endpoint

- name: get_user              # The function
- name: get_user.endpoint     # Its HTTP endpoint



# Multiple endpoints for same function

- name: list_orders
- name: list_orders.endpoint.get
- name: list_orders.endpoint.post



# Routers

- name: api.public            # Public API router
- name: api.admin             # Admin API router
```

<tip>
Pattern: <code>base_name.variant</code> — dots separate semantic parts, while underscores separate words within a part.
</tip>



### Namespaces


Namespaces are dot-separated identifiers:

```
app
app.api
app.api.v2
app.workers
```

Entry full ID combines namespace and name: `app.api:get_user`



### The Lock File


`wippy.lock` records where Wippy loads definitions from and which module versions are selected:

```yaml
directories:
  modules: .wippy
  src: ./src
options:
  unpack_modules: false
modules:
  - name: acme/http
    version: v1.2.0
    hash: 4ea816fe84ca58a1f0869e5ca6afa93d6ddd72fa09e1162d9e600a7fbf39f0a2
```

| Field | Description |
|-------|-------------|
| `directories.src` | Application source directory, scanned recursively for YAML definition files |
| `directories.modules` | Base directory for vendored modules; packs land under `<modules>/vendor/` |
| `options.unpack_modules` | Extract each `.wapp` into a directory beside it instead of loading the pack directly (default `false`) |
| `modules[].name` | Module identifier in `org/module` form |
| `modules[].version` | Selected version |
| `modules[].hash` | Artifact digest the vendored pack must match |
| `modules[].root` | Marks the selected deployment root; at most one module may carry it |

Vendored packs are kept as `.wapp` files. With `unpack_modules: true`, each module is also extracted into a directory, and the verified `.wapp` stays beside it — installation looks for the pack, so a directory whose pack is missing is downloaded again.

A `replacements:` section in `wippy.lock` is deprecated. It still loads, with a warning; declare local module overrides under `workspace.replacements` in a runtime config file instead. See [Dependency Management](guides/dependency-management.md#local-development-with-replacements).



## Entry Definitions


Each item in the `entries` array defines one entry. Kind-specific fields can appear beside `name`, `kind`, and `meta`, as in this example:

```yaml
entries:
  - name: hello
    kind: function.lua
    meta:
      comment: Returns hello world
    source: file://hello.lua
    method: handler
    modules:
      - http
      - json

  - name: hello.endpoint
    kind: http.endpoint
    meta:
      comment: Hello endpoint
    method: GET
    path: /hello
    func: hello
```

An explicit `data:` field is also supported. When present, its value is the complete kind-specific payload, so do not mix it with sibling kind-specific fields:

```yaml
entries:
  - name: config
    kind: registry.entry
    data:
      environment: production
      features:
        dark_mode: true
```



### Metadata


Use `meta` for UI-friendly information:

```yaml
- name: payment_handler
  kind: function.lua
  meta:
    title: Payment Processor
    comment: Handles Stripe payments
  source: file://payment.lua
```

Use `meta.title` and `meta.comment` for descriptive information that registry consumers and management interfaces can display.



### Application Entries


Use `registry.entry` kind for application-level configuration:

```yaml
- name: config
  kind: registry.entry
  meta:
    title: Application Settings
    type: application
  environment: production
  features:
    dark_mode: true
    beta_access: false
```



## Common Entry Kinds


| Kind | Purpose |
|------|---------|
| `registry.entry` | General-purpose data stored without normal event dispatch |
| `function.lua` | Callable Lua function |
| `process.lua` | Long-running process |
| `http.service` | HTTP server |
| `http.router` | Route group |
| `http.endpoint` | HTTP handler |
| `process.host` | Process execution host |

See the [Entry Kinds Guide](guides/entry-kinds.md) for the entry-kind reference.



### .wippy.yaml


Runtime configuration at project root:

```yaml
version: "1.0"

logger:
  encoding: json

logmanager:
  min_level: 0

supervisor:
  host:
    worker_count: 16
```

See the [Configuration Guide](guides/configuration.md) for runtime configuration fields.



### wippy.lock


Source directories and the selected module graph — see [The Lock File](#the-lock-file) above.



## Referencing Entries


Reference entries by full ID or relative name where the entry kind supports it. HTTP routers and endpoints attach through `meta.server` and `meta.router`, rather than through parent-side child lists:

```yaml


# Router declares itself against a server

- name: api
  kind: http.router
  meta:
    server: app:gateway
  prefix: /api



# Endpoint references router by registry ID (cross-namespace works the same way)

- name: get_user.endpoint
  kind: http.endpoint
  meta:
    router: app.api:api
  method: GET
  path: /users/{id}
  func: app.api:get_user
```



## Example Project


```
myapp/
├── .wippy.yaml
├── wippy.lock
└── src/
    ├── _index.yaml           # namespace: app
    ├── api/
    │   ├── _index.yaml       # namespace: app.api
    │   ├── users.lua
    │   └── orders.lua
    ├── lib/
    │   ├── _index.yaml       # namespace: app.lib
    │   └── database.lua
    └── workers/
        ├── _index.yaml       # namespace: app.workers
        └── email_sender.lua
```



## See Also


- [Application Architecture](concepts/architecture.md) — Organize an application into slices and layers
- [Entry Kinds Guide](guides/entry-kinds.md) — Review available entry kinds
- [Configuration Guide](guides/configuration.md) — Configure runtime options
- [Custom Entry Kinds](internals/kinds.md) — Implement handlers (advanced)



## Navigation

Previous: "Installation" (start/installation)
Next: "CLI Reference" (guides/cli)
