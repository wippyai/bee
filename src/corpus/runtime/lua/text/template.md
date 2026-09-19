# "Template Engine"

_Path: en/lua/text/template_

> "Render dynamic content using the Jet template engine. Build HTML pages, emails, and documents with template inheritance and includes."

## Table of Contents

- Template Engine

## Content

# Template Engine

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="external"/>

The `templates` module renders [Jet](https://github.com/CloudyKit/jet) templates from configured sets. Templates can use inheritance and includes. This page is an API reference with isolated rendering examples, not a standalone template deployment. The registry IDs and template sources must already be configured, and the executable entry must enable `templates` and have `template.get` permission for the requested set.

For template set configuration, see [Template Engine](system/template.md).



## Loading


```lua
local templates = require("templates")
```



## `templates.get`


Acquire a template set by registry ID:

```lua
local set, err = templates.get("app.views:emails")
if err then
    return nil, err
end

-- Use the set...

return set:release()
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | string | Template set registry ID |

**Returns:** `Set, error`



## `set:render`


Render a template by name with data:

```lua
local set, get_err = templates.get("app.views:emails")
if get_err then
    return nil, get_err
end

local html, err = set:render("welcome", {
    user = {name = "Alice", email = "alice@example.com"},
    activation_url = "https://example.invalid/activate"
})

set:release()
if err then
    return nil, err
end

return html
```

The caller owns every acquired set until `release()` is called. Release it after the final render, including checked error paths; repeated releases are safe. Rendering does not make application-provided values safe for every output context. Keep secrets and one-time URLs out of logs, and apply the escaping or sanitization required where the rendered string is consumed.

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | string | Template name within the set |
| `data` | table | Variables to pass to template (optional) |

**Returns:** `string, error`



## Set Method Summary


The set handle provides these methods:

| Method | Returns | Description |
|--------|---------|-------------|
| `render(name, data?)` | `string, error` | Render template with data |
| `release()` | `boolean` | Release set back to pool |



## Jet Syntax Reference


Jet uses `{{ }}` for expressions and control structures and `{* *}` for comments.



### Variables


```html
{{ user.name }}
{{ user.email }}
{{ items[0].price }}
```



### Conditionals


```html
{{ if order.shipped }}
    <p>Shipped!</p>
{{ else if order.processing }}
    <p>Processing...</p>
{{ else }}
    <p>Received.</p>
{{ end }}
```



### Loops


```html
{{ range items }}
    <li>{{ .name }} - ${{ .price }}</li>
{{ end }}

{{ range i, item := items }}
    <p>{{ i }}. {{ item.name }}</p>
{{ end }}
```



### Inheritance


```html
{* Parent: layout.jet *}
<html>
<head><title>{{ yield title() }}</title></head>
<body>{{ yield body() }}</body>
</html>

{* Child: page.jet *}
{{ extends "layout" }}
{{ block title() }}My Page{{ end }}
{{ block body() }}<p>Content</p>{{ end }}
```



### Includes


```html
{{ include "partials/header" }}
<main>Content</main>
{{ include "partials/footer" }}
```



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Empty ID | `errors.INVALID` | no |
| Empty template name | `errors.INVALID` | no |
| Permission denied | `errors.PERMISSION_DENIED` | no |
| Template set missing, unavailable, or wrong resource type | `errors.INTERNAL` | no |
| Template not found | `errors.NOT_FOUND` | no |
| Render error | `errors.INTERNAL` | no |
| Render attempted after the set was released | `errors.INTERNAL` | no |

See [Error Handling](lua/core/errors.md) for working with errors.



## Navigation

Previous: "Text Processing" (lua/text/text)
Next: "Tree-sitter Parsing" (lua/text/treesitter)
