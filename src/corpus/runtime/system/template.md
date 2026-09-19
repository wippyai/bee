# "Template Engine"

_Path: en/system/template_

> "Template rendering using CloudyKit Jet."

## Table of Contents

- Template Engine

## Content

# Template Engine

<secondary-label ref="external"/>

Template entries configure [CloudyKit Jet](https://github.com/CloudyKit/jet) sets and template sources.

This page is a configuration reference. Its YAML fences are fragments for an existing entry list; combine each template with the referenced `template.set` in the same project or installed module graph.



## Entry Kinds


| Kind | Description |
|------|-------------|
| `template.set` | Template set with shared configuration |
| `template.jet` | Individual template |



## Template Sets


A set is a namespace containing related templates. Templates within a set share configuration and can reference each other by name.

```yaml
- name: views
  kind: template.set
```

All template-set configuration is optional:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `engine.development_mode` | bool | false | Disable template caching |
| `engine.delimiters.left` | string | `{{` | Variable opening delimiter |
| `engine.delimiters.right` | string | `}}` | Variable closing delimiter |
| `engine.delimiters.comment_left` | string | `{*` | Validated only; comments always use Jet's `{*` |
| `engine.delimiters.comment_right` | string | `*}` | Validated only; comments always use Jet's `*}` |
| `engine.extensions` | string[] | `[.jet, .html.jet, .jet.html]` | Validated only; name lookup always tries Jet's built-in `.jet`, `.html.jet`, `.jet.html` |
| `engine.globals` | map | - | Variables available to all templates |

At runtime `development_mode`, the left and right expression delimiters, and
`globals` configure the Jet set. The comment-delimiter and extension fields are
accepted and validated in this release, but are not applied by the in-memory
Jet loader. Changing them does not alter parsing or discover templates.



## Templates


Templates belong to a set and are identified by name for internal resolution.

```yaml
- name: layout
  kind: template.jet
  set: app.views:views
  source: |
    <html>
    <body>{{ yield content() }}</body>
    </html>

- name: home
  kind: template.jet
  set: app.views:views
  source: |
    {{ extends "layout" }}
    {{ block content() }}
      <h1>Welcome, {{ name }}</h1>
    {{ end }}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `set` | reference | Yes | Parent template set |
| `source` | string | Yes | Inline template content or a manifest-relative `file://` reference |

A relative `file://` reference is loaded relative to the manifest containing
the entry and cannot escape that manifest filesystem. Environment placeholders
inside the resulting template source are preserved as template text rather than
resolved by the environment system.



## Template Resolution


Templates reference one another by name rather than registry ID. Names are resolved within the set:

1. By default, the registry entry name (`entry.ID.Name`) becomes the template name
2. Override with `meta.name` for custom naming:

```yaml
- name: email-welcome-v2
  kind: template.jet
  set: app.emails:templates
  meta:
    name: welcome
  source: |
    {{ include "header" }}
    Hello {{ user }}!
```

This template is registered as `welcome` in the set, so other templates use `{{ include "welcome" }}` or `{{ extends "welcome" }}`.



## Inheritance


Templates can extend parent templates and override blocks:

```yaml


# Parent defines yield points

- name: base
  kind: template.jet
  set: app.views:views
  source: |
    <html>
    <head><title>{{ yield title() }}</title></head>
    <body>{{ yield body() }}</body>
    </html>



# Child extends and fills blocks

- name: page
  kind: template.jet
  set: app.views:views
  source: |
    {{ extends "base" }}
    {{ block title() }}My Page{{ end }}
    {{ block body() }}<p>Content here</p>{{ end }}
```



## Lua API


See [Template Module](lua/text/template.md) for rendering operations.



## See Also


- [Template Module](lua/text/template.md) - Lua API reference
- [Filesystem](system/filesystem.md) - Loading templates from disk
- [HTTP Endpoint](http/endpoint.md) - Rendering templates from request handlers



## Navigation

Previous: "Environment System" (system/env)
Next: "Security Model" (system/security)
