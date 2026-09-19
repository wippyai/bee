# "HTML Sanitization"

_Path: en/lua/http/html_

> "Sanitize untrusted HTML to prevent XSS attacks. Based on bluemonday."

## Table of Contents

- HTML Sanitization

## Content

# HTML Sanitization

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="workflow"/>

The `html` module sanitizes untrusted HTML with policies based on [bluemonday](https://github.com/microcosm-cc/bluemonday).

Sanitization parses an HTML fragment and filters it through an allowlist policy. Elements and attributes that the policy does not allow are removed, and the remaining fragment is normalized during serialization.

This is an API reference. Constructor blocks are self-contained policy snippets; later method blocks are partial configuration snippets that assume `policy` is an already-created policy. Sanitized output is suitable only for an HTML element-content context. It is not safe for JavaScript, CSS, URL, or HTML attribute interpolation; use an encoder for the actual output context.



## Loading


```lua
local html = require("html")
```

Add `html` to the executable entry's `modules:` list before requiring it.



## Preset Policies


The module provides three preset policy constructors:

| Policy | Use Case | Allows |
|--------|----------|--------|
| `new_policy` | Custom sanitization | Nothing (build from scratch) |
| `ugc_policy` | User comments, forums | Common formatting (`p`, `b`, `i`, `a`, lists, etc.) |
| `strict_policy` | Plain text extraction | Nothing (strips all HTML) |

All three constructors return `Policy, nil`; policy construction does not currently fail.



### Empty Policy


Create an empty policy, then add the elements and attributes it should allow:

```lua
local policy, err = html.sanitize.new_policy()
if err then return nil, err end

policy:allow_elements("p", "strong", "em")
policy:allow_attrs("class"):globally()

local clean = policy:sanitize(user_input)
```

**Returns:** `Policy, error`



### User Content Policy


Create a policy configured for common user-generated formatting:

```lua
local policy, err = html.sanitize.ugc_policy()
if err then return nil, err end

local safe = policy:sanitize('<p>Hello <strong>world</strong></p>')
-- '<p>Hello <strong>world</strong></p>'

local xss = policy:sanitize('<p>Hello <script>alert("xss")</script></p>')
-- '<p>Hello </p>'
```

**Returns:** `Policy, error`



### Strict Policy


Create a strict policy that removes HTML and returns plain text:

```lua
local policy, err = html.sanitize.strict_policy()
if err then return nil, err end

local text = policy:sanitize('<p>Hello <b>world</b>!</p>')
-- 'Hello world!'
```

**Returns:** `Policy, error`



### Allow Elements


Allow specific HTML elements:

```lua
local policy, err = html.sanitize.new_policy()
if err then return nil, err end
policy:allow_elements("p", "strong", "em", "br")
policy:allow_elements("h1", "h2", "h3")
policy:allow_elements("a", "img")

local result = policy:sanitize('<p>Hello <strong>world</strong></p>')
-- '<p>Hello <strong>world</strong></p>'
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `...` | string | Element tag names |

**Returns:** `Policy`



### Allow Attributes


Start an attribute rule, then apply it with `on_elements()` or `globally()`:

```lua
policy:allow_attrs("href"):on_elements("a")
policy:allow_attrs("src", "alt"):on_elements("img")
policy:allow_attrs("class", "id"):globally()
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `...` | string | Attribute names |

**Returns:** `AttrBuilder`



### On Specific Elements


Allow attributes only on specified elements:

```lua
policy:allow_elements("a", "img")
policy:allow_attrs("href", "target"):on_elements("a")
policy:allow_attrs("src", "alt", "width", "height"):on_elements("img")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `...` | string | Element tag names |

**Returns:** `Policy`



### On All Elements


Allow attributes on every permitted element:

```lua
policy:allow_attrs("class"):globally()
policy:allow_attrs("id"):globally()
```

**Returns:** `Policy`



### With Pattern Matching


Require attribute values to match a regular expression:

```lua
-- Only allow hex colors in style
local builder, err = policy:allow_attrs("style"):matching("^color:#[0-9a-fA-F]{6}$")
if err then
    return nil, err
end
builder:on_elements("span")

policy:sanitize('<span style="color:#ff0000">Red</span>')
-- '<span style="color:#ff0000">Red</span>'

policy:sanitize('<span style="background:red">Bad</span>')
-- '<span>Bad</span>'
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `pattern` | string | Go RE2-compatible regular expression |

**Returns:** `AttrBuilder, error`



### Standard URLs


Enable the standard URL-handling policy. It requires parseable URLs, permits relative URLs plus `mailto`, `http`, and `https`, and adds `rel="nofollow"` to allowed linking elements:

```lua
policy:allow_elements("a")
policy:allow_attrs("href"):on_elements("a")
policy:allow_standard_urls()
```

**Returns:** `Policy`



### URL Schemes


Allow specific URL schemes:

```lua
policy:allow_url_schemes("https", "mailto")

policy:sanitize('<a href="https://example.com">OK</a>')
-- '<a href="https://example.com">OK</a>'

policy:sanitize('<a href="javascript:alert(1)">XSS</a>')
-- '<a>XSS</a>'
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `...` | string | Schemes to allow |

**Returns:** `Policy`



### Relative URLs


Configure whether relative URLs are allowed:

```lua
policy:allow_relative_urls(true)

policy:sanitize('<a href="/page">Link</a>')
-- '<a href="/page">Link</a>'
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allow` | boolean | Allow relative URLs |

**Returns:** `Policy`



### Require Parseable URLs


Reject URLs that fail to parse cleanly. With `true`, attribute URLs that the HTML sanitizer cannot parse are stripped instead of passed through.

```lua
policy:require_parseable_urls(true)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `require` | boolean | Require URLs to be parseable |

**Returns:** `Policy`



### Nofollow Links


Add `rel="nofollow"` to links:

```lua
policy:allow_attrs("href", "rel"):on_elements("a")
policy:allow_url_schemes("https")
policy:require_parseable_urls(true)
policy:require_nofollow_on_links(true)

policy:sanitize('<a href="https://example.com">Link</a>')
-- '<a href="https://example.com" rel="nofollow">Link</a>'
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `require` | boolean | Add nofollow |

**Returns:** `Policy`



### Noreferrer Links


Add `rel="noreferrer"` to links:

```lua
policy:require_noreferrer_on_links(true)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `require` | boolean | Add noreferrer |

**Returns:** `Policy`



### External Links in New Tab


Add `target="_blank"` to fully qualified URLs:

```lua
policy:allow_attrs("href", "target"):on_elements("a")
policy:allow_url_schemes("https")
policy:require_parseable_urls(true)
policy:add_target_blank_to_fully_qualified_links(true)

policy:sanitize('<a href="https://example.com">Link</a>')
-- '<a href="https://example.com" target="_blank" rel="noopener">Link</a>'
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `add` | boolean | Add target blank |

**Returns:** `Policy`

When opening untrusted links in a new tab, also enable `require_noreferrer_on_links(true)` to suppress referrer leakage and mitigate opener access.



### Allow Images


Permit `<img>` with `align`, `alt`, `height`, `width`, and `src`. This helper also enables the standard URL policy but does not allow data URI images.

```lua
policy:allow_images()

policy:sanitize('<img src="photo.jpg" alt="Photo">')
-- '<img src="photo.jpg" alt="Photo">'
```

**Returns:** `Policy`



### Allow Data URI Images


Permit syntactically valid Base64-encoded `gif`, `jpeg`, `png`, `svg+xml`, or `webp` data URI images. The sanitizer validates the media type and Base64 encoding, not the decoded image contents. Data URIs can carry active content, so enable them only for content whose image data you trust:

```lua
policy:allow_elements("img")
policy:allow_attrs("src"):on_elements("img")
policy:allow_data_uri_images()

local input = '<img src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2O9sAAAAASUVORK5CYII=">'
policy:sanitize(input)
-- The data URI is preserved.
```

**Returns:** `Policy`



### Allow Lists


Permit `ul`, `ol`, `li`, `dl`, `dt`, and `dd`. The helper also allows validated `type` attributes on `ul`, `ol`, and `li`, plus an integer `value` attribute on `li`.

```lua
policy:allow_lists()

policy:sanitize('<ul><li>Item 1</li><li>Item 2</li></ul>')
-- '<ul><li>Item 1</li><li>Item 2</li></ul>'
```

**Returns:** `Policy`



### Allow Tables


Permit table elements: `table`, `caption`, `col`, `colgroup`, `thead`, `tbody`, `tfoot`, `tr`, `td`, `th`.

```lua
policy:allow_tables()

policy:sanitize('<table><tr><td>Cell</td></tr></table>')
-- '<table><tr><td>Cell</td></tr></table>'
```

**Returns:** `Policy`



### Allow Standard Attributes


Permit common attributes: `id`, `title`, `dir`, `lang`.

```lua
policy:allow_elements("p")
policy:allow_standard_attributes()

policy:sanitize('<p id="intro" class="text" title="Introduction">Hello</p>')
-- '<p id="intro" title="Introduction">Hello</p>'
```

**Returns:** `Policy`



## Sanitize


Apply a policy to an HTML string:

```lua
local policy, err = html.sanitize.ugc_policy()
if err then return nil, err end
policy:require_nofollow_on_links(true)

local dirty = '<p>Hello</p><script>alert("xss")</script>'
local clean = policy:sanitize(dirty)
-- '<p>Hello</p>'
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `html` | string | HTML to sanitize |

**Returns:** `string`

`sanitize` returns only a string. In runtime `v0.3.32a`, the underlying fragment parser can turn malformed input that it cannot parse into an empty string, and the Lua wrapper cannot distinguish that case from valid input whose content the policy removed. Treat sanitization as output filtering, not input validation; validate required content separately when an empty result matters.



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Invalid regex pattern | `errors.INVALID` | no |

See [Error Handling](lua/core/errors.md) for working with errors.



## Navigation

Previous: "WebSocket Client" (lua/http/websocket)
Next: "SQL Database" (lua/storage/sql)
