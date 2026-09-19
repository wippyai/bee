# "Filesystem"

_Path: en/system/filesystem_

> "Configure directory-backed and read-only embedded filesystems."

## Table of Contents

- Filesystem

## Content

# Filesystem


Filesystem entries expose directory-backed or read-only embedded storage to runtime modules. This page is a configuration reference; its YAML blocks are individual entry fragments rather than complete projects.



## Entry Kinds


| Kind | Description |
|------|-------------|
| `fs.directory` | Directory-based filesystem |
| `fs.embed` | Read-only embedded filesystem |



## Directory Filesystem


```yaml
- name: uploads
  kind: fs.directory
  directory: "/var/data/uploads"
  auto_init: true
  mode: "0755"
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `directory` | string | required | Root path |
| `auto_init` | bool | false | Create directory if missing |
| `mode` | string | 0755 | Unix permission mode (octal) |
| `base` | string | - | Relative-path base: `project` (process working directory) or `module` (owning module load root) |

Absolute paths are used as given, whatever `base` says.

For a relative path, `base: project` keeps it relative to the process working directory. Both `base: module` and an unset `base` resolve it against the load root of the module that owns the entry, looked up through the entry's registry owner. When the entry has no owning module, or that module has no resolvable resource root, the path stays relative to the process working directory.

Any other value is rejected with `invalid directory base`.

The mode restricts all file operations. Execute bits are added automatically when all read bits are set and no execute bit is.

<note>
Paths are normalized and validated. It is not possible to access files outside the configured root directory.
</note>



## Embedded Filesystem


```yaml
- name: static
  kind: fs.embed
```

Embedded filesystems load from pack resources using the entry ID. They are read-only.

<warning>
Embedded filesystems are used internally and normally do not require manual configuration.
</warning>



## Operations


Both filesystem types implement:

| Operation | Directory | Embed |
|-----------|-----------|-------|
| Open/Read | Yes | Yes |
| Stat | Yes | Yes |
| Lstat | Yes | Yes |
| ReadDir | Yes | Yes |
| OpenFile (write) | Yes | No |
| Remove | Yes | No |
| Mkdir | Yes | No |
| Rename | Yes | No |

Write operations on embedded filesystems return an error.



## Lua API


See [Filesystem Module](lua/storage/filesystem.md) for file operations.



## See Also


- [Filesystem Module](lua/storage/filesystem.md) - Lua API reference
- [Cloud Storage](system/cloudstorage.md) - S3-compatible object storage
- [Template](system/template.md) - Templates loaded from filesystems



## Navigation

Previous: "Network Overlays" (system/network)
Next: "Cloud Storage" (system/cloudstorage)
