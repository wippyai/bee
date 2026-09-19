# "Type System"

_Path: en/lua/types_

> "Syntax and runtime behavior for Wippy's gradual type system, including unions, records, generics, validation, and reflection."

## Table of Contents

- Type System

## Content

# Type System


> **Experimental.** The type system is still evolving, and some limitations are expected.

Wippy's gradual type system supports incremental annotations and flow-sensitive checking. Types are non-nullable by default.

This page is a language reference, not a complete program. Each code block is an isolated type-checking example, and alternatives within a block are not necessarily meant to be combined. Names such as `get_data`, `get_user`, `call`, and `User` represent application code; lines marked `ERROR` intentionally demonstrate diagnostics. These examples use language syntax and built-in type values, so they do not require runtime modules.



## Primitives


```lua
local n: number = 3.14
local i: integer = 42         -- integer is subtype of number
local s: string = "hello"
local b: boolean = true
local a: any = "anything"     -- dynamic member and method access
local u: unknown = { source = "example" }  -- must narrow before use
```



### `any` and `unknown`


```lua
-- any: dynamic member and method access
local a: any = get_data()
a.foo.bar.baz()              -- no error, may crash at runtime
local s: string = a          -- ERROR: any is not assignable to string

-- unknown: safe unknown, must narrow before use as a concrete type
local u: unknown = get_data()
u.foo                        -- no error: member access on unknown behaves like any
local n: number = u          -- ERROR: unknown not assignable to number, narrow first
if type(u) == "table" then
    -- u narrowed to table here
end
```



## Nil Safety


Types are non-nullable by default. Use `?` for optional values:

```lua
local x: number = nil         -- ERROR: nil not assignable to number
local y: number? = nil        -- OK: number? means "number or nil"
local z: number? = 42         -- OK
```



### Control Flow Narrowing


The type checker tracks control flow:

```lua
local function process(x: number?): number
    if x ~= nil then
        return x              -- x is number here
    end
    return 0
end

-- Early return pattern
local user, err = get_user(123)
if err then return nil, err end
-- user narrowed to non-nil here

-- Or default
local val = get_value() or 0  -- val: number
```



## Union Types


```lua
local val: number | string = get_value()

if type(val) == "number" then
    print(val + 1)            -- val: number
else
    print(val:upper())        -- val: string
end
```



### Literal Types


```lua
type Status = "pending" | "active" | "done"

local s: Status = "pending"   -- OK
local s: Status = "invalid"   -- ERROR
```



## Function Types


```lua
local function add(a: number, b: number): number
    return a + b
end

-- Multiple returns
local function div_mod(a: number, b: number): (number, number)
    return math.floor(a / b), a % b
end

-- Error returns (Lua idiom)
local function fetch(url: string): (string?, error?)
    -- returns (data, nil) or (nil, error)
end

-- First-class function types
local double: (number) -> number = function(x: number): number
    return x * 2
end
```



### Variadic Functions


```lua
local function sum(...: number): number
    local total: number = 0
    for _, v in ipairs({...}) do
        total = total + v
    end
    return total
end
```



## Record Types


```lua
type User = {name: string, age: number}

local u: User = {name = "alice", age = 25}
```



### Optional Fields


```lua
type Config = {
    host: string,
    port: number,
    timeout?: number,
    debug?: boolean
}

local cfg: Config = {host = "localhost", port = 8080}  -- OK
```



## Generics


```lua
local function identity<T>(x: T): T
    return x
end

local n: number = identity(42)
local s: string = identity("hello")
```



### Constrained Generics


```lua
type HasName = {name: string}

local function greet<T: HasName>(obj: T): string
    return "Hello, " .. obj.name
end

greet({name = "Alice"})       -- OK
greet({age = 30})             -- ERROR: missing 'name'
```



## Intersection Types


Combine multiple types:

```lua
type Named = {name: string}
type Aged = {age: number}
type Person = Named & Aged

local p: Person = {name = "Alice", age = 30}
```



## Tagged Unions


```lua
type Result<T, E> =
    {ok: true, value: T}
    | {ok: false, error: E}

type LoadState =
    {status: "loading"}
    | {status: "loaded", data: User}
    | {status: "error", message: string}

local function render(state: LoadState): string
    if state.status == "loading" then
        return "Loading..."
    elseif state.status == "loaded" then
        return "Hello, " .. state.data.name
    elseif state.status == "error" then
        return "Error: " .. state.message
    end
end
```



## The `never` Type


`never` is the bottom type: it has no possible values.

```lua
function fail(msg: string): never
    error(msg)
end
```



## Error Handling Pattern


The checker understands the common Lua `value, error` return pattern:

```lua
local value, err = call()
if err then
    -- value is nil here
    return nil, err
end
-- value is non-nil here, err is nil
print(value)
```



## Non-Nil Assertion


Use `!` to assert an expression is non-nil:

```lua
local user: User? = get_user()
local name = (user!).name            -- assert user is non-nil
```

`!` is a type-checker assertion only - it narrows the type to non-nil but emits no runtime check. If the value is actually nil, the following operation fails with the usual error (e.g. indexing nil). Use when you know a value cannot be nil but the type checker cannot prove it.



### Runtime Validation


Call a type as a function to validate a value. Validation returns the original value with the requested static type; it does not convert or coerce the value:

```lua
local data: any = get_json()
local user = User(data)              -- validates and returns User
local name = user.name               -- safe field access
```

This works with primitives and custom types:

```lua
local x: any = get_value()
local s = string(x)                  -- requires an existing string
local n = integer(x)                 -- requires an existing integer
local b = boolean(x)                 -- requires an existing boolean

type Point = {x: number, y: number}
local p = Point(data)                -- validates record structure
```

For example, `string(42)` raises a validation error; use `tostring(42)` when conversion is intended.



### Type:is() Method


`Type:is` validates without throwing and returns either `(value, nil)` or `(nil, error)`:

```lua
type Point = {x: number, y: number}
local data: any = get_input()

local p, err = Point:is(data)
if p then
    local sum = p.x + p.y            -- p is valid Point
else
    return nil, err                  -- validation failed
end
```

The result narrows in conditionals:

```lua
if Point:is(data) then
    local p: Point = data            -- data narrowed to Point
end
```



### Unsafe Cast


Use `::` or `as` for unchecked casts:

```lua
local data: any = get_data()
local user = data :: User            -- no runtime check
local user = data as User            -- same as ::
```

Use sparingly. Unsafe casts bypass validation and can cause runtime errors if the value doesn't match the type.



## Type Reflection


Types are first-class values that provide introspection methods.



### Kind and Name


```lua
type Num = number

print(Num:kind())                    -- "number"
print(Point:kind())                  -- "record"
print(Point:name())                  -- "Point"
```



### Record Fields


Iterate over record fields:

```lua
type User = {name: string, age: number}

for name, typ in User:fields() do
    print(name, typ:kind())
end
-- name    string
-- age     number
```

Access individual field types:

```lua
local nameType = User.name           -- type of 'name' field
print(nameType:kind())               -- "string"
```



### Collection Types


```lua
type NumberList = {number}
print(NumberList:elem():kind())      -- "number"

type ScoreMap = {[string]: number}
print(ScoreMap:key():kind())         -- "string"
print(ScoreMap:val():kind())         -- "number"
```



### Optional Types


```lua
type MaybeNumber = number?
print(MaybeNumber:kind())            -- "optional"
print(MaybeNumber:inner():kind())    -- "number"
```



### Union Types


```lua
type Status = "pending" | "active" | "done"

for variant in Status:variants() do
    print(variant)
end
```



### Function Types


```lua
type Predicate = (number, string) -> boolean

for param in Predicate:params() do
    print(param:kind())
end
print(Predicate:ret():kind())        -- "boolean"
```

`typeof(expression)` is type syntax, not a runtime reflection function. Use it in an alias such as `type Config = typeof(default_config)`; the resulting alias is the runtime type value.



### Type Comparison


```lua
type Num = number
type Int = integer

print(Num == Num)                    -- true
print(Int <= Num)                    -- true (subtype)
print(Int < Num)                     -- true (strict subtype)
```



### Types as Table Keys


```lua
type Point = {x: number, y: number}
type Line = {from: Point, to: Point}

local handlers = {}
handlers[Point] = function() return "point handler" end
handlers[Line] = function() return "line handler" end

local h = handlers[Point]
if h then h() end
```



## Type Annotations


Add types to function signatures:

```lua
-- Parameter and return types
local function process(input: string): number
    return #input
end

-- Local variable types
local count: number = 0

-- Type aliases
type StringArray = {string}
type StringMap = {[string]: number}
```



## Type Validators


Attach validation constraints to type aliases with annotations, then call the type or use `Type:is()` to enforce them at runtime:

```lua
type NonNegative = number @min(0)
type Percentage = number @min(0) @max(100)
type Email = string @pattern("^.+@.+$")

local x = NonNegative(1)
local percent, err = Percentage:is(50)
local email = Email("test@example.com")
```

An annotation on a local variable is checked statically by the linter. It does not insert an automatic runtime check at assignment; runtime enforcement occurs when a type value validates a value.



### Built-in Validators


| Validator | Applies to | Example |
|-----------|------------|---------|
| `@min(n)` | number | `type Positive = number @min(1)` |
| `@max(n)` | number | `type Percentage = number @max(100)` |
| `@min_len(n)` | string, array | `type NonEmpty = string @min_len(1)` |
| `@max_len(n)` | string, array | `type ShortName = string @max_len(10)` |
| `@pattern(regex)` | string | `type Email = string @pattern("^.+@.+$")` |



### Record Field Validators


```lua
type User = {
    age: number @min(0) @max(150),
    name: string @min_len(1) @max_len(100)
}
```



### Array Element Validators


```lua
local scores: {number @min(0) @max(100)} = {85, 90}
```



### Union Member Validators


```lua
local id: number @min(1) | string @min_len(1) = 1
```



## Variance Rules


| Position | Variance | Description |
|----------|----------|-------------|
| Readonly field | Covariant | Can use subtype |
| Mutable field | Quasi-invariant | Normally invariant; fresh literals and refinements may widen to their base type |
| Function parameter | Contravariant | Can use supertype |
| Function return | Covariant | Can use subtype |



## Subtyping


- `integer` is a subtype of `number`
- `never` is a subtype of all types
- All types are subtypes of `any`
- Union subtyping: `A` is subtype of `A | B`



## Gradual Adoption


Types can be added incrementally; untyped code continues to work:

```lua
-- Existing code works unchanged
function old_function(x)
    return x + 1
end

-- New code gets types
function new_function(x: number): number
    return x + 1
end
```

Useful starting points include:

1. Function signatures at API boundaries
2. HTTP handlers and queue consumers
3. Critical business logic



## Type Checking


Run the type checker with:

```bash
wippy lint
```

The command reports type errors without executing the code.



## Navigation

Previous: "Why Wippy Uses Lua" (lua/why-lua)
Next: "Lua Entry Kinds" (lua/entries)
