# "Environment System"

_Path: en/system/env_

> "Define environment variables backed by memory, files, the operating system, static values, or storage routers."

## Table of Contents

- Environment System

## Content

# Environment System


Environment entries let runtime code reference configuration by public variable name or registry entry ID.

This page is a configuration reference. Its YAML fences are entry fragments unless they show an enclosing document.



## Storage and Access


The model separates storage from access:

- **Storages** - Where values are stored (OS, files, memory)
- **Variables** - Named references to values in storages

Variables can be referenced by:
- **Public name** - The `variable` field value
- **Entry ID** - Full `namespace:name` reference

Omit the `variable` field when a variable should be accessible only by entry ID.
The first variable to claim a public name keeps that shortcut. A later variable
with the same public name is still registered and remains accessible by entry ID,
but does not replace the existing shortcut.



## Entry Kinds


| Kind | Description |
|------|-------------|
| `env.storage.memory` | In-memory key-value storage |
| `env.storage.file` | File-based storage (.env format) |
| `env.storage.os` | Read-only OS environment access |
| `env.storage.static` | Read-only static key-value storage |
| `env.storage.router` | Chains multiple storages |
| `env.variable` | Named variable referencing a storage |



### Memory Storage


Volatile in-memory storage.

```yaml
- name: runtime_env
  kind: env.storage.memory
```



### File Storage


Persistent storage using a simple `KEY=VALUE` format. Blank lines and lines that
start with `#` are ignored; text after `#` on a value line is treated as a comment.
Quoted values and escape sequences are not parsed specially.

```yaml
- name: app_config
  kind: env.storage.file
  file_path: /etc/app/config.env
  auto_create: true
  file_mode: 0600
  dir_mode: 0700
```

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `file_path` | string | required | Path to .env file |
| `auto_create` | boolean | false | Create file if missing |
| `file_mode` | integer | 0644 | File permissions |
| `dir_mode` | integer | 0755 | Directory permissions |



### OS Storage


Read-only access to operating system environment variables.

```yaml
- name: os_env
  kind: env.storage.os
```

Always read-only. Set operations return `PERMISSION_DENIED`.



### Static Storage


Static storage defines values directly in configuration. The values are part of the entry, are read-only at runtime, and can hold public constants shipped with a module or pack.

```yaml
- name: defaults
  kind: env.storage.static
  values:
    PUBLIC_API_HOST: "https://api.example.com"
    PUBLIC_WS_HOST: "wss://api.example.com/ws"
    APP_ENV: "production"
```

| Property | Type | Description |
|----------|------|-------------|
| `values` | map | Key-value pairs (string to string) |

Always read-only. Set operations return `PERMISSION_DENIED`.



### Router Storage


A router chains several storages. On a cache miss, reads search them in order until a value is found; a successful value is cached by the router, so direct changes in a backing storage are not visible through that router afterward. An error other than `NOT_FOUND` stops the fallback search. Writes target only the first storage.

```yaml
- name: config
  kind: env.storage.router
  storages:
    - app.config:memory    # Primary (writes here)
    - app.config:file      # Fallback
    - app.config:os        # Fallback
```

| Property | Type | Description |
|----------|------|-------------|
| `storages` | array | Required, non-empty ordered list of storage references |



## Variables


Variables map public names or entry IDs to values in a storage backend.

```yaml
- name: DATABASE_URL
  kind: env.variable
  variable: DATABASE_URL
  storage: app.config:file
  default: postgres://localhost/app
  readonly: false
```

| Property | Type | Description |
|----------|------|-------------|
| `variable` | string | Optional public variable name |
| `storage` | string | Required storage reference (`namespace:name`) |
| `default` | string | Default value if not found |
| `readonly` | boolean | Prevent modifications |



### Variable Naming


Variable names must contain only: `a-z`, `A-Z`, `0-9`, `_`



### Access Patterns


```yaml


# Public variable - accessible by name "PORT"

- name: port_var
  kind: env.variable
  variable: PORT
  storage: app.config:os
  default: "8080"



# Private variable - accessible only by ID "app.config:internal_key"

- name: internal_key
  kind: env.variable
  storage: app.config:secrets
```



## Placeholder Interpolation


Registered variables are pulled into entry configuration with `${env:NAME}` placeholders, resolved centrally at decode time against this registry. Entry configuration strings are resolved unless their entry kind marks a field as opaque. Source fields such as `template.jet.source` are opaque so template or program text is not rewritten.

| Syntax | Meaning |
|--------|---------|
| `${env:NAME}` | Resolve `NAME` through the env registry; error if unset and no default |
| `${env:NAME\|default}` | Resolve `NAME`, falling back to `default` when unset |
| `${NAME\|default}` | Shorthand; `NAME` must be upper-snake (`A-Z0-9_`) and the `\|default` is required — bare `${VAR}` is left untouched so embedded shell/template spans are not mistaken for references |
| `$${` | Literal `${` (escape) |

`NAME` is a registered variable's public name or its entry ID (registry-id form with dots/colons, e.g. `app.env:tls_cert`). It is **not** a raw OS environment variable: an OS value is reachable only when an `env.storage.os`-backed variable is registered under that name.

```yaml
- name: api
  kind: http.service
  addr: ":443"
  tls:
    mode: manual
    cert: ${env:app.env:tls_cert}
    key:  ${env:app.env:tls_key}
```

A field whose entire value is a single placeholder takes the type of its inline default. For example, `${env:PORT|8080}` produces an integer and coerces a stored value to an integer, while `${env:PORT|"8080"}` remains a string. A placeholder mixed with surrounding text always produces a string. A variable's own `default` is honored before the placeholder's inline `|default`. A reference that resolves to nothing and has no default fails decoding.

Resolution happens at decode time only: the stored registry entry keeps the raw placeholders, so resolved secrets never appear in `registry.get` results or persisted state. Entries referencing a variable by entry ID (`${env:ns:name}`) automatically order after that variable at boot; a reference by public name creates no dependency edge.

<note>
Older configurations use a sibling <code>&lt;field&gt;_env</code> directive (for example <code>cert_env: app.env:tls_cert</code>) that resolves the same way. This form is <b>deprecated</b> — migrate it to the <code>${env:NAME}</code> placeholder. A <code>&lt;field&gt;_env</code> key naming an unregistered variable is not treated as a directive and is left as-is; one naming a registered but empty variable keeps the inline <code>&lt;field&gt;</code> value. Only an explicit <code>${env:NAME}</code> without a default hard-fails on a missing variable.
</note>



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Variable not found | `errors.NOT_FOUND` | no |
| Storage not found | `errors.NOT_FOUND` | no |
| Variable is read-only | `errors.PERMISSION_DENIED` | no |
| Storage is read-only | `errors.PERMISSION_DENIED` | no |
| Invalid variable name | `errors.INVALID` | no |



## Runtime Access


- [env module](lua/system/env.md) - Lua runtime access



## See Also


- [Security Model](system/security.md) - Access control for environment variables
- [Configuration Guide](guides/configuration.md) - Application configuration patterns



## Navigation

Previous: "Cloud Storage" (system/cloudstorage)
Next: "Template Engine" (system/template)
