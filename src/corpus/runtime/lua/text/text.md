# "Text Processing"

_Path: en/lua/text/text_

> "Regular expressions, text diffing, and semantic text splitting."

## Table of Contents

- Text Processing

## Content

# Text Processing

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="workflow"/>

The `text` module provides regular expressions, text comparison and patching, and document splitting. This page is an API reference. Its short blocks are isolated calls; longer splitting blocks are partial recipes whose documents, configured filesystem resources, and downstream processing belong to the surrounding application.



## Loading


```lua
local text = require("text")
```



### `text.regexp.compile`


Compile an RE2-compatible regular expression.

```lua
local re, err = text.regexp.compile("[0-9]+")
if err then
    return nil, err
end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `pattern` | string | RE2 compatible regex pattern |

**Returns:** `Regexp, error`



### `re:match_string`


Match a string against the compiled expression.

```lua
local ok = re:match_string("abc123")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `s` | string | String to match |

**Returns:** `boolean`



### `re:find_string`


Find the first matching substring.

```lua
local match = re:find_string("abc123def")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `s` | string | String to search |

**Returns:** `string | nil`

At this runtime pin, an empty-string match is also represented as `nil`; use a pattern that consumes at least one character when an empty match must be distinguished from no match.



### `re:find_all_string`


Find all matching substrings.

```lua
local matches = re:find_all_string("a1b2c3")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `s` | string | String to search |

**Returns:** `string[]`



### `re:find_string_submatch`


Find the first match and its capture groups.

```lua
local match = re:find_string_submatch("user@example.com")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `s` | string | String to search |

**Returns:** `string[] | nil` (full match + capture groups)



### `re:find_all_string_submatch`


Find all matches and their capture groups.

```lua
local matches = re:find_all_string_submatch("a=1 b=2")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `s` | string | String to search |

**Returns:** `string[][]`



### `re:find_string_index`


Find the 1-based bounds of the first match.

```lua
local pos = re:find_string_index("abc123")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `s` | string | String to search |

**Returns:** `table | nil` ({start, end}, 1-based)



### `re:find_all_string_index`


Find the bounds of all matches.

```lua
local positions = re:find_all_string_index("a1b2c3")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `s` | string | String to search |

**Returns:** `table[] | nil` (nil when there are no matches)



### `re:replace_all_string`


Replace every matching substring.

```lua
local result = re:replace_all_string("a1b2", "X")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `s` | string | Input string |
| `repl` | string | Replacement string |

**Returns:** `string`



### `re:split`


Split a string at matches of the compiled expression.

```lua
local parts = re:split("a,b,c", -1)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `s` | string | String to split |
| `n` | integer | Max parts, -1 for all |

**Returns:** `string[]`



### `re:num_subexp`


Return the number of capturing subexpressions.

```lua
local count = re:num_subexp()
```

**Returns:** `number`



### `re:subexp_names`


Return the names of capturing subexpressions.

```lua
local names = re:subexp_names()
```

**Returns:** `string[]`



### `re:string`


Return the compiled pattern string.

```lua
local pattern = re:string()
```

**Returns:** `string`



## Text Diffing


Compare text versions and generate patches with [go-diff](https://github.com/sergi/go-diff), an implementation of Google's diff-match-patch algorithm.



### `text.diff.new`


Create a text differ with default or custom options.

```lua
local diff, err = text.diff.new()
local diff, err = text.diff.new(options)
```

**Returns:** `Differ, error`



#### Options {id="diff-options"}


| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `diff_timeout` | number | 1.0 | Timeout in seconds |
| `diff_edit_cost` | integer | 4 | Cost of an empty edit |
| `match_threshold` | number | 0.5 | Match tolerance 0-1 |
| `match_distance` | integer | 1000 | Distance to search for match |
| `patch_delete_threshold` | number | 0.5 | Delete threshold |
| `patch_margin` | integer | 4 | Context margin |



### `diff:compare`


Compare two strings and return operations that transform `text1` into `text2`.

```lua
local diff, diff_err = text.diff.new()
if diff_err then
    return nil, diff_err
end
local diffs, err = diff:compare("hello world", "hello there")
if err then
    return nil, err
end

-- diffs contains:
-- {operation = "equal", text = "hello "}
-- {operation = "delete", text = "world"}
-- {operation = "insert", text = "there"}
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `text1` | string | Original text |
| `text2` | string | Modified text |

**Returns:** `table, error` (array of {operation, text})

Operations: `"equal"`, `"delete"`, `"insert"`



### `diff:summarize`


Count the unchanged, inserted, and deleted UTF-8 bytes. For non-ASCII text, these totals are not Unicode code-point or grapheme counts.

```lua
-- `diffs` is the checked result from diff:compare.
local summary = diff:summarize(diffs)

-- summary.equals = 6 (bytes unchanged)
-- summary.deletions = 5 (bytes removed)
-- summary.insertions = 5 (bytes added)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `diffs` | table | Diff array from compare |

**Returns:** `table` ({insertions, deletions, equals})



### `diff:pretty_text`


Format a diff with ANSI colors for terminal output.

```lua
local formatted, err = diff:pretty_text(diffs)
if err then
    return nil, err
end
print(formatted)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `diffs` | table | Diff array from compare |

**Returns:** `string, error`



### `diff:pretty_html`


Format a diff as HTML with `<del>` and `<ins>` elements.

```lua
local html, err = diff:pretty_html(diffs)
if err then
    return nil, err
end
-- `html` is an HTML fragment with equal, deleted, and inserted spans.
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `diffs` | table | Diff array from compare |

**Returns:** `string, error`



### `diff:patch_make`


Create patches that transform one string into another. The patches can be serialized and applied later.

```lua
local text1 = "The quick brown fox jumps over the lazy dog"
local text2 = "The quick red fox jumps over the lazy cat"

local patches, err = diff:patch_make(text1, text2)
if err then
    return nil, err
end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `text1` | string | Original text |
| `text2` | string | Modified text |

**Returns:** `table, error`



### `diff:patch_apply`


Apply patches to a string and return the result and whether every patch succeeded.

```lua
local result, success = diff:patch_apply(patches, text1)
-- result = "The quick red fox jumps over the lazy cat"
-- success = true
```

Check `success` before treating `result` as the requested transformation. Pass patch tables produced by `patch_make`; at this runtime pin, malformed serialized patch text inside a hand-built table can be skipped rather than reported separately.

| Parameter | Type | Description |
|-----------|------|-------------|
| `patches` | table | Patches from patch_make |
| `text` | string | Text to apply patches to |

**Returns:** `string, boolean`



## Text Splitting


Split documents into chunks while preserving semantic boundaries. The splitters are based on the [langchaingo](https://github.com/tmc/langchaingo) implementation.



### `text.splitter.recursive`


The recursive splitter tries double newlines, single newlines, spaces, and then individual characters. It moves to the next separator when a chunk exceeds the size limit.

```lua
local splitter, err = text.splitter.recursive({
    chunk_size = 1000,
    chunk_overlap = 100
})
if err then
    return nil, err
end

local long_text = "This is a long text that needs splitting..."
local chunks, split_err = splitter:split_text(long_text)
if split_err then
    return nil, split_err
end
```

**Returns:** `Splitter, error`



#### Options {id="recursive-splitter-options"}


| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `chunk_size` | integer | 4000 | Max characters per chunk |
| `chunk_overlap` | integer | 200 | Characters repeated between adjacent chunks |
| `keep_separator` | boolean | false | Keep separators in output |
| `separators` | string[] | nil | Custom separator list |



### `text.splitter.markdown`


The Markdown splitter can keep headings with their content, preserve code blocks, and group table rows.

```lua
local splitter, err = text.splitter.markdown({
    chunk_size = 2000,
    code_blocks = true,
    heading_hierarchy = true
})
if err then
    return nil, err
end

local readme = fs.get("app:docs"):readfile("README.md")
local chunks, err = splitter:split_text(readme)
```

This partial recipe requires the entry to enable both `text` and `fs`, a configured `app:docs` filesystem resource, and a readable `README.md` within that resource.

**Returns:** `Splitter, error`



#### Options {id="markdown-splitter-options"}


| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `chunk_size` | integer | 4000 | Max characters per chunk |
| `chunk_overlap` | integer | 200 | Characters repeated between adjacent chunks |
| `code_blocks` | boolean | false | Keep code blocks together |
| `reference_links` | boolean | false | Preserve reference links |
| `heading_hierarchy` | boolean | false | Respect heading levels |
| `join_table_rows` | boolean | false | Keep table rows together |
| `separators` | string[] | nil | Custom separator list |



### `splitter:split_text`


Split a single document into an array of chunks.

```lua
local chunks, err = splitter:split_text(document)
if err then
    return nil, err
end

for i, chunk in ipairs(chunks) do
    -- Process each chunk (e.g., create embedding, send to LLM)
    process(chunk)
end
```

Here, `splitter` is a successfully created splitter, while `document` and `process` are supplied by the application.

| Parameter | Type | Description |
|-----------|------|-------------|
| `text` | string | Text to split |

**Returns:** `string[], error`



### `splitter:split_batch`


Split multiple documents while preserving their metadata. One input document can produce several chunks, each with the source document's metadata.

```lua
-- Input: pages from a PDF with page numbers
local pages = {
    {content = "First page content...", metadata = {page = 1}},
    {content = "Second page content...", metadata = {page = 2}}
}

local chunks, err = splitter:split_batch(pages)
if err then
    return nil, err
end

-- Output: each chunk knows which page it came from
for _, chunk in ipairs(chunks) do
    print("Page " .. chunk.metadata.page .. ": " .. chunk.content:sub(1, 50))
end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `pages` | table | Array of {content, metadata} |

**Returns:** `table, error` (array of {content, metadata})

`split_batch` silently skips an item when the item is not a table, its `content` field is missing, empty, or not a string, or splitting that item fails. It still returns the remaining chunks with a `nil` error. Validate every input item before the call and verify any cardinality requirements in application code; do not treat a successful call as proof that every input was represented.



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Invalid pattern syntax | `errors.INVALID` | no |
| Internal error | `errors.INTERNAL` | no |

See [Error Handling](lua/core/errors.md) for working with errors.



## Navigation

Previous: "Hub" (lua/system/hub)
Next: "Template Engine" (lua/text/template)
