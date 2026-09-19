# "Tree-sitter Parsing"

_Path: en/lua/text/treesitter_

> "Parse source code into concrete syntax trees using Tree-sitter. Based on go-tree-sitter bindings."

## Table of Contents

- Tree-sitter Parsing

## Content

# Tree-sitter Parsing

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="workflow"/>

The `treesitter` module parses source code into concrete syntax trees with [Tree-sitter](https://tree-sitter.github.io/tree-sitter/) through the [go-tree-sitter](https://github.com/tree-sitter/go-tree-sitter) bindings.

This page is an API reference with partial parsing recipes. Source strings and query patterns are application input, and node-level snippets assume a live tree from an earlier checked parse. Parsers, trees, queries, and cursors are owned resources: close every successfully created handle when its last dependent operation is complete.

The resulting syntax trees:
- Represent the full structure of source code
- Update incrementally as code changes
- Are robust to syntax errors (partial parsing)
- Support pattern-based queries using S-expressions



## Loading


```lua
local treesitter = require("treesitter")
```

<note>
The `treesitter` module is optional and is present only in builds that include the `treesitter` build tag. Official Wippy binaries include it. Source builds can use `make build-wippy` or `go build -tags treesitter`; without the tag, `require("treesitter")` is unavailable.
</note>



## Supported Languages


| Language | Aliases | Root Node |
|----------|---------|-----------|
| Go | `go`, `golang` | `source_file` |
| JavaScript | `js`, `javascript` | `program` |
| TypeScript | `ts`, `typescript` | `program` |
| TSX | `tsx` | `program` |
| Python | `python`, `py` | `module` |
| Lua | `lua` | `chunk` |
| PHP | `php` | `program` |
| C# | `csharp`, `cs`, `c#` | `compilation_unit` |
| HTML | `html`, `html5` | `document` |
| Markdown | `markdown`, `md` | `document` |
| SQL | `sql` | - |

```lua
local langs = treesitter.supported_languages()
-- {go = true, javascript = true, python = true, ...}
```



### Parse Code


```lua
local code = [[
func hello() {
    return "Hello!"
}
]]

local tree, err = treesitter.parse("go", code)
if err then
    return nil, err
end

local root, root_err = tree:root_node()
if root_err then
    tree:close()
    return nil, root_err
end
print(root:kind())        -- "source_file"
print(root:child_count()) -- number of top-level declarations
tree:close()
```



### Query Syntax Tree


```lua
local code = [[
func hello() {}
func world() {}
]]

local tree, parse_err = treesitter.parse("go", code)
if parse_err then
    return nil, parse_err
end
local root, root_err = tree:root_node()
if root_err then
    tree:close()
    return nil, root_err
end

-- Find all function names
local query, query_err = treesitter.query("go", [[
    (function_declaration name: (identifier) @func_name)
]])
if query_err then
    tree:close()
    return nil, query_err
end

local captures, captures_err = query:captures(root, code)
if captures_err then
    query:close()
    tree:close()
    return nil, captures_err
end
for _, capture in ipairs(captures) do
    print(capture.name, capture.text)
end
-- "func_name"  "hello"
-- "func_name"  "world"
query:close()
tree:close()
```



### Simple Parse


Parse source code with a temporary internal parser.

```lua
local tree, err = treesitter.parse("go", code)
if err then
    return nil, err
end
-- Use the tree, then call tree:close().
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `language` | string | Language name or alias |
| `code` | string | Source code |

**Returns:** `Tree, error`



### Reusable Parser


Create a reusable parser for repeated parsing or incremental updates.

```lua
local parser, parser_err = treesitter.parser()
if parser_err then
    return nil, parser_err
end
local _, language_err = parser:set_language("go")
if language_err then
    parser:close()
    return nil, language_err
end

local tree1, first_err = parser:parse("package main")
if first_err then
    parser:close()
    return nil, first_err
end

-- Parse another source with the reusable parser. For an incremental update,
-- edit the old tree first as shown in the complete recipe below.
local tree2, second_err = parser:parse("package main\nfunc foo() {}")
if second_err then
    tree1:close()
    parser:close()
    return nil, second_err
end

tree2:close()
tree1:close()
parser:close()
```

**Returns:** `Parser, error`



### Parser Methods


| Method | Description |
|--------|-------------|
| `set_language(lang)` | Set parser language, returns `boolean, error` |
| `get_language()` | Get current language name |
| `parse(code, old_tree?)` | Parse code, optionally with old tree for incremental parsing |
| `set_timeout(duration)` | Set parse timeout (string like `"1s"` or nanoseconds) |
| `set_ranges(ranges)` | Set byte ranges to parse |
| `reset()` | Reset parser state |
| `close()` | Release parser resources |

Trees created by a reusable parser and the parser itself are independently owned; close each successful handle. Nodes borrow their tree's storage and must not be used after that tree is closed. Cursors borrow a tree as well, so close them before the tree. Queries own separate native resources and also require `close()`; close a query after its captures or matches are no longer needed. Explicit cleanup is deterministic, while the process resource store is only a fallback for handles left open at process teardown.



### Get Root Node


```lua
local tree, err = treesitter.parse("go", "package main")
if err then
    return nil, err
end
local root, root_err = tree:root_node()
if root_err then
    tree:close()
    return nil, root_err
end

print(root:kind())  -- "source_file"
local source_text, text_err = root:text()
if text_err then
    tree:close()
    return nil, text_err
end
print(source_text)  -- "package main"
tree:close()
```



### Tree Methods


| Method | Description |
|--------|-------------|
| `root_node()` | Get root node of tree |
| `root_node_with_offset(bytes, point)` | Get root with offset applied |
| `language()` | Get tree's language object |
| `copy()` | Create deep copy of tree |
| `walk()` | Create cursor for traversal |
| `edit(edit_table)` | Apply incremental edit |
| `changed_ranges(other_tree)` | Get ranges that changed |
| `included_ranges()` | Get ranges included during parsing |
| `dot_graph()` | Get DOT graph representation |
| `close()` | Release tree resources |



### Incremental Editing


Apply an edit before reparsing changed source code:

```lua
local code = "func main() { x := 1 }"
local tree, parse_err = treesitter.parse("go", code)
if parse_err then
    return nil, parse_err
end

-- Mark edit: changed "1" to "100" at byte 19
local _, edit_err = tree:edit({
    start_byte = 19,
    old_end_byte = 20,
    new_end_byte = 22,
    start_row = 0,
    start_column = 19,
    old_end_row = 0,
    old_end_column = 20,
    new_end_row = 0,
    new_end_column = 22
})
if edit_err then
    tree:close()
    return nil, edit_err
end

-- Re-parse with edited tree (faster than full parse)
local parser, parser_err = treesitter.parser()
if parser_err then
    tree:close()
    return nil, parser_err
end
local _, language_err = parser:set_language("go")
if language_err then
    parser:close()
    tree:close()
    return nil, language_err
end
local new_tree, new_tree_err = parser:parse("func main() { x := 100 }", tree)
if new_tree_err then
    parser:close()
    tree:close()
    return nil, new_tree_err
end

new_tree:close()
parser:close()
tree:close()
```



## Nodes


Nodes represent elements in the syntax tree. In the isolated snippets below, `root`, `node`, and `func_decl` are application-selected nodes borrowed from a still-open tree.



### Node Types


```lua
local node = root:child(0)

-- Type information
print(node:kind())        -- "package_clause"
print(node:type())        -- same as kind()
print(node:is_named())    -- true for significant nodes
print(node:grammar_name()) -- grammar rule name
```



### Navigation


```lua
-- Children
local child = node:child(0)           -- by index (0-based)
local named = node:named_child(0)     -- named children only
local count = node:child_count()
local named_count = node:named_child_count()

-- Siblings
local next = node:next_sibling()
local prev = node:prev_sibling()
local next_named = node:next_named_sibling()
local prev_named = node:prev_named_sibling()

-- Parent
local parent = node:parent()

-- By field name
local name_node = func_decl:child_by_field_name("name")
local field = node:field_name_for_child(0)
```



### Position Information


```lua
-- Byte offsets
local start = node:start_byte()
local end_ = node:end_byte()

-- Row/column positions (0-based)
local start_pt = node:start_point()  -- {row = 0, column = 0}
local end_pt = node:end_point()      -- {row = 0, column = 12}

-- Source text
local source_text, err = node:text()
if err then
    return nil, err
end
```



### Error Detection


```lua
if root:has_error() then
    -- Tree contains syntax errors
end

if node:is_error() then
    -- This specific node is an error
end

if node:is_missing() then
    -- Parser inserted this to recover from error
end

if node:is_extra() then
    -- Node is an "extra" (e.g. a comment) not required by the grammar
end
```

Other node methods: `descendant_count()` and `named_descendant_for_point_range(start_pt, end_pt)`.



### S-Expression


```lua
local sexp = node:to_sexp()
-- "(source_file (package_clause (package_identifier)))"
```



## Queries


Tree-sitter queries match syntax-tree patterns written as S-expressions.



### Create Query


```lua
local query, err = treesitter.query("go", [[
    (function_declaration
        name: (identifier) @func_name
        parameters: (parameter_list) @params
    )
]])
if err then
    return nil, err
end
-- The owner calls query:close() after the final query operation.
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `language` | string | Language name |
| `pattern` | string | Query pattern in S-expression syntax |

**Returns:** `Query, error`



### Execute Query


```lua
-- Get all captures (flattened)
local captures, captures_err = query:captures(root, source_code)
if captures_err then
    query:close()
    tree:close()
    return nil, captures_err
end
for _, capture in ipairs(captures) do
    print(capture.name)   -- "func_name"
    print(capture.text)   -- actual text
    print(capture.index)  -- capture index
    -- capture.node is the Node object
end

-- Get matches (grouped by pattern)
local matches, matches_err = query:matches(root, source_code)
if matches_err then
    query:close()
    tree:close()
    return nil, matches_err
end
for _, match in ipairs(matches) do
    print(match.id, match.pattern)
    for _, capture in ipairs(match.captures) do
        local captured_text, text_err = capture.node:text()
        if text_err then
            query:close()
            tree:close()
            return nil, text_err
        end
        print(capture.name, captured_text)
    end
end

query:close()
tree:close()
```

Passing userdata of the wrong type instead of a Tree-sitter `Node` returns `nil, error`; passing a primitive or table raises a Lua argument error before that check. `root`, `source_code`, and `query` here must come from a still-open tree and a successfully created query. The snippet uses the owning `tree` handle to close both resources before it returns.



### Query Control


```lua
-- Limit query scope
query:set_byte_range(0, 1000)
query:set_point_range({row = 0, column = 0}, {row = 10, column = 0})

-- Limit matches
query:set_match_limit(100)
if query:did_exceed_match_limit() then
    -- More matches exist
end

-- Timeout (string duration or nanoseconds)
query:set_timeout("500ms")
query:set_timeout(1000000000)  -- 1 second in nanoseconds

-- Disable patterns/captures
query:disable_pattern(0)
query:disable_capture("func_name")
```



### Query Inspection


```lua
local pattern_count = query:pattern_count()
local capture_count = query:capture_count()
local name = query:capture_name_for_id(0)
local id = query:capture_index_for_name("func_name")
```

Further inspection methods: `string_count()`, `start_byte_for_pattern(i)`, `end_byte_for_pattern(i)`, `get_match_limit()`, `get_timeout()`, `is_pattern_rooted(i)`, `is_pattern_non_local(i)`, `is_pattern_guaranteed(i)`, `capture_quantifier(pattern, capture)`, `set_max_start_depth(n)`, `get_property_predicates(i)`, `get_property_settings(i)`, `get_text_predicates(i)`.



## Tree Cursor


A tree cursor traverses a tree without creating a node object at every step.



### Basic Traversal


```lua
local cursor, err = tree:walk()
if err then
    return nil, err
end

-- Start at root
print(cursor:current_node():kind())  -- "source_file"
print(cursor:current_depth())        -- 0

-- Navigate
if cursor:goto_first_child() then
    print(cursor:current_node():kind())
    print(cursor:current_depth())  -- 1
end

if cursor:goto_next_sibling() then
    -- moved to next sibling
end

cursor:goto_parent()  -- back to parent

cursor:close()
```



### Cursor Methods


| Method | Returns | Description |
|--------|---------|-------------|
| `current_node()` | `Node` | Node at cursor position |
| `current_depth()` | `integer` | Depth (0 = root) |
| `current_field_name()` | `string?` | Field name if any |
| `current_field_id()` | `integer` | Field ID (0 if none) |
| `current_descendant_index()` | `integer` | Descendant index of current node |
| `goto_parent()` | `boolean` | Move to parent |
| `goto_first_child()` | `boolean` | Move to first child |
| `goto_last_child()` | `boolean` | Move to last child |
| `goto_next_sibling()` | `boolean` | Move to next sibling |
| `goto_previous_sibling()` | `boolean` | Move to previous sibling |
| `goto_descendant(index)` | - | Move to descendant by index |
| `goto_first_child_for_byte(n)` | `integer?` | Move to child containing byte |
| `goto_first_child_for_point(pt)` | `integer?` | Move to child containing point |
| `reset(node)` | - | Reset cursor to node |
| `reset_to(cursor)` | - | Reset cursor to another cursor's position |
| `copy()` | `Cursor` | Create copy of cursor |
| `close()` | - | Release resources |



## Language Metadata


```lua
local lang, err = treesitter.language("go")
if err then
    return nil, err
end

print(lang:version())           -- ABI version
print(lang:node_kind_count())   -- number of node types
print(lang:field_count())       -- number of fields
print(lang:parse_state_count()) -- number of parse states

-- Node kind lookup
local kind = lang:node_kind_for_id(1)
local id = lang:id_for_node_kind("identifier", true)
local is_named = lang:node_kind_is_named(1)

-- Field lookup
local field_name = lang:field_name_for_id(1)
local field_id = lang:field_id_for_name("name")
```



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Language not supported | `errors.INVALID` | no |
| Language has no binding | `errors.INVALID` | no |
| Invalid query pattern | `errors.INVALID` | no |
| Invalid positions | `errors.INVALID` | no |
| Parse failed | `errors.INTERNAL` | no |
| No execution context | `errors.INTERNAL` | no |

Closing an already closed parser, tree, query, or cursor is safe. Calling any other method on a closed handle raises a Lua argument error.

See [Error Handling](lua/core/errors.md) for working with errors.



## Query Syntax Reference


Tree-sitter queries use S-expression patterns:

```
; Match a node type
(identifier)

; Match with field names
(function_declaration name: (identifier))

; Capture with @name
(function_declaration name: (identifier) @func_name)

; Multiple patterns
[
  (function_declaration)
  (method_declaration)
] @declaration

; Wildcards
(_)           ; any node
(identifier)+ ; one or more
(identifier)* ; zero or more
(identifier)? ; optional

; Predicates
((identifier) @var
  (#match? @var "^_"))  ; regex match
```

See [Tree-sitter Query Syntax](https://tree-sitter.github.io/tree-sitter/using-parsers#query-syntax) for complete documentation.



## Navigation

Previous: "Template Engine" (lua/text/template)
Next: "Security & Access Control" (lua/security/security)
