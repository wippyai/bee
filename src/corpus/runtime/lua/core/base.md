# "Standard Lua Libraries"

_Path: en/lua/core/base_

> "Core Lua libraries automatically available in all Wippy processes. No require() needed."

## Table of Contents

- Standard Lua Libraries

## Content

# Standard Lua Libraries

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="workflow"/>

These core Lua libraries are available in every executable Lua entry without `require()`.

This is an API reference. Signature blocks list available functions, while the longer blocks are isolated examples or partial patterns rather than complete entries. Names such as `check_health` and `process_request` represent application callbacks.



### Type and Conversion


```lua
type(value)         -- Returns: "nil", "number", "string", "boolean", "table", "function", "thread", "userdata"
tonumber(s [,base]) -- Convert to number, optional base (2-36)
tostring(value)     -- Convert to string, calls __tostring metamethod
```



### Assertions and Errors


```lua
assert(v [,msg])    -- Raises error if v is false/nil, returns v otherwise
error(msg [,level]) -- Raises error at specified stack level (default 1)
pcall(fn, ...)      -- Protected call, returns ok, result_or_error
xpcall(fn, errh)    -- Protected call with error handler function
```



### Table Iteration


```lua
pairs(t)            -- Iterate all key-value pairs
ipairs(t)           -- Iterate array portion (1, 2, 3, ...)
next(t [,index])    -- Get next key-value pair after index
```



### Metatables


```lua
getmetatable(obj)       -- Get metatable (or __metatable field if protected)
setmetatable(t, mt)     -- Set metatable, returns t
```



### Raw Table Access


Bypass metamethods for direct table access:

```lua
rawget(t, k)        -- Get t[k] without __index
rawset(t, k, v)     -- Set t[k]=v without __newindex
rawequal(a, b)      -- Compare without __eq
```



### Utilities


```lua
select(index, ...)  -- Return args from index onwards
select("#", ...)    -- Return number of args
unpack(t [,i [,j]]) -- Return t[i] through t[j] as multiple values
print(...)          -- Print values (uses structured logging in Wippy)
```



### Global Variables


```lua
_G        -- The global environment table
_VERSION  -- Lua version string
```



## Table Manipulation


The `table` library provides in-place array operations, sorting, concatenation, and unpacking:

```lua
table.insert(t, [pos,] value)  -- Insert value at pos (default: end)
table.remove(t [,pos])         -- Remove and return element at pos (default: last)
table.concat(t [,sep [,i [,j]]]) -- Concatenate array elements with separator
table.sort(t [,comp])          -- Sort in place, comp(a,b) returns true if a < b
table.unpack(t [,i [,j]])      -- Unpack table elements as multiple values
table.create(narr, nhash)      -- Preallocate table with array and hash capacity
table.freeze(t)                -- Make table immutable, returns t
table.isfrozen(t)              -- true if table is immutable
```

```lua
local items = {"a", "b", "c"}

table.insert(items, "d")           -- {"a", "b", "c", "d"}
table.insert(items, 2, "x")        -- {"a", "x", "b", "c", "d"}
table.remove(items, 2)             -- {"a", "b", "c", "d"}, returns "x"

local csv = table.concat(items, ",")  -- "a,b,c,d"

table.sort(items, function(a, b)
    return a > b  -- Descending order
end)
```



## String Operations


String functions are also available as methods on string values.



### Pattern Matching


```lua
string.find(s, pattern [,init [,plain]])   -- Find pattern, returns start, end, captures
string.match(s, pattern [,init])           -- Extract matching substring
string.gmatch(s, pattern)                  -- Iterator over all matches
string.gsub(s, pattern, repl [,n])         -- Replace matches, returns string, count
```



### Case Conversion


```lua
string.upper(s)   -- Convert to uppercase
string.lower(s)   -- Convert to lowercase
```



### Substrings and Characters


```lua
string.sub(s, i [,j])      -- Substring from i to j (negative indexes from end)
string.len(s)              -- String length (or use #s)
string.byte(s [,i [,j]])   -- Numeric codes of characters
string.char(...)           -- Create string from character codes
string.rep(s, n)           -- Repeat string n times
string.reverse(s)          -- Reverse string
```



### Formatting


```lua
string.format(fmt, ...)    -- Printf-style formatting
string.pack(fmt, ...)      -- Pack values into a binary string
string.unpack(fmt, s [,pos]) -- Unpack binary string, returns values and next position
string.packsize(fmt)       -- Size in bytes of a packed format
```

Format specifiers: `%d` (integer), `%f` (float), `%s` (string), `%q` (quoted), `%x` (hex), `%o` (octal), `%e` (scientific), `%%` (literal %)

```lua
local s = "Hello, World!"

-- Pattern matching
local start, stop = string.find(s, "World")  -- 8, 12
local word = string.match(s, "%w+")          -- "Hello"

-- Substitution
local new = string.gsub(s, "World", "Wippy") -- "Hello, Wippy!"

-- Method syntax
local upper = s:upper()                       -- "HELLO, WORLD!"
local part = s:sub(1, 5)                      -- "Hello"
```



### Patterns


| Pattern | Matches |
|---------|---------|
| `.` | Any character |
| `%a` | Letters |
| `%d` | Digits |
| `%w` | Alphanumeric |
| `%s` | Whitespace |
| `%p` | Punctuation |
| `%c` | Control characters |
| `%x` | Hexadecimal digits |
| `%z` | Zero (null) |
| `[set]` | Character class |
| `[^set]` | Negated class |
| `*` | 0 or more (greedy) |
| `+` | 1 or more (greedy) |
| `-` | 0 or more (lazy) |
| `?` | 0 or 1 |
| `^` | Start of string |
| `$` | End of string |
| `%b()` | Balanced pair |
| `(...)` | Capture group |

Uppercase versions (`%A`, `%D`, etc.) match the complement.



## Math Functions


The `math` library provides numeric constants and common mathematical operations.



### Constants {id="math-constants"}


```lua
math.pi       -- 3.14159...
math.huge     -- Largest representable float
math.mininteger  -- Minimum integer
math.maxinteger  -- Maximum integer
```



### Basic Operations


```lua
math.abs(x)           -- Absolute value
math.min(...)         -- Minimum of arguments
math.max(...)         -- Maximum of arguments
math.floor(x)         -- Round down
math.ceil(x)          -- Round up
math.modf(x)          -- Integer and fractional parts
math.fmod(x, y)       -- Floating-point remainder
```



### Powers and Roots


```lua
math.sqrt(x)          -- Square root
math.pow(x, y)        -- x^y (or use x^y operator)
math.exp(x)           -- e^x
math.log(x)           -- Natural log
math.log10(x)         -- Base-10 log
math.frexp(x)         -- Mantissa and exponent
math.ldexp(m, e)      -- m * 2^e
```



### Trigonometry


```lua
math.sin(x)   math.cos(x)   math.tan(x)    -- Radians
math.asin(x)  math.acos(x)  math.atan(x)
math.atan2(y, x)                            -- Arc tangent of y/x
math.sinh(x)  math.cosh(x)  math.tanh(x)   -- Hyperbolic
math.deg(r)   -- Radians to degrees
math.rad(d)   -- Degrees to radians
```



### Random Numbers


```lua
math.random()         -- Random float [0,1)
math.random(n)        -- Random integer [1,n]
math.random(m, n)     -- Random integer [m,n]
math.randomseed(x)    -- No effect; the generator is auto-seeded
```

`math.random` is nondeterministic. Do not use it for decisions that must replay identically in a workflow; `math.randomseed` cannot make it deterministic.



### Type Conversion


```lua
math.tointeger(x)     -- Convert to integer or nil
math.type(x)          -- "integer", "float", or nil
math.ult(m, n)        -- Unsigned less-than comparison
```



## Coroutines


The `coroutine` library provides coroutine creation and control. See [Channels and Coroutines](lua/core/channel.md) for channel-based concurrency patterns.

```lua
coroutine.create(fn)        -- Create coroutine from function
coroutine.resume(co, ...)   -- Start/continue coroutine
coroutine.yield(...)        -- Suspend coroutine, return values to resume
coroutine.status(co)        -- "running", "suspended", "normal", "dead"
coroutine.running()         -- Current coroutine (nil if main thread)
coroutine.wrap(fn)          -- Create coroutine as callable function
```



### Spawning Concurrent Coroutines


Wippy adds `coroutine.spawn` for scheduler-managed concurrent work:

```lua
coroutine.spawn(fn)         -- Spawn function as concurrent coroutine
```

```lua
local time = require("time")

-- Spawn background task
coroutine.spawn(function()
    while true do
        check_health()
        time.sleep("30s")
    end
end)

-- Continue main execution immediately
process_request()
```

This partial pattern assumes the entry lists `time` in `modules:` and provides the `check_health` and `process_request` functions. The spawned coroutine runs concurrently in the same Lua process; `process_request()` is reached immediately, and each health check is followed by a 30-second sleep.



## Error Handling


The global `errors` table creates and classifies structured errors. See [Error Handling](lua/core/errors.md) for the complete API.



### Constants {id="error-constants"}


```lua
errors.UNKNOWN           -- Unclassified error
errors.INVALID           -- Invalid argument or input
errors.NOT_FOUND         -- Resource not found
errors.ALREADY_EXISTS    -- Resource already exists
errors.PERMISSION_DENIED -- Permission denied
errors.TIMEOUT           -- Operation timed out
errors.CANCELED          -- Operation cancelled
errors.UNAVAILABLE       -- Service unavailable
errors.INTERNAL          -- Internal error
errors.CONFLICT          -- Conflict (e.g., concurrent modification)
errors.RATE_LIMITED      -- Rate limit exceeded
```



### Functions {id="error-functions"}


```lua
-- Create error from string
local err = errors.new("something went wrong")

-- Create error with metadata
local err = errors.new({
    message = "User not found",
    kind = errors.NOT_FOUND,
    retryable = false,
    details = {user_id = 123}
})

-- Wrap existing error with context
local wrapped = errors.wrap(err, "failed to load profile")

-- Check error kind
if errors.is(err, errors.NOT_FOUND) then
    -- handle not found
end

-- Get call stack from error
local stack = errors.call_stack(err)
```



### Error Methods


```lua
err:message()    -- Get error message string
err:kind()       -- Get error kind (e.g., "NOT_FOUND")
err:retryable()  -- true, false, or nil (unknown)
err:details()    -- Get details table or nil
err:stack()      -- Get stack trace as string
```



## Restricted Features


The following standard Lua features are unavailable in Wippy processes:

| Feature | Alternative |
|---------|-------------|
| `load`, `loadstring`, `loadfile`, `dofile` | Use [Dynamic Evaluation](lua/dynamic/eval.md) module |
| `collectgarbage` | Automatic GC |
| `rawlen` | Use `#` operator |
| Standard `io.*` file library | Use [File System](lua/storage/filesystem.md) module; the `io` module in Wippy is [Terminal I/O](lua/system/io.md) |
| `os.execute`, `os.exit`, `os.getenv`, `os.remove`, `os.rename`, `os.tmpname` | Use [Command Execution](lua/dynamic/exec.md), [Environment](lua/system/env.md) modules |
| `string.dump` | Not available |
| `debug.*` | Not available |
| `utf8.*` | Not available |
| `package.loadlib` | Native libraries not supported |



## See Also


- [Channels and Coroutines](lua/core/channel.md) - Go-style channels for concurrency
- [Error Handling](lua/core/errors.md) - Creating and handling structured errors
- [OS Time](lua/system/ostime.md) - System time functions



## Navigation

Previous: "Lua Entry Kinds" (lua/entries)
Next: "Errors" (lua/core/errors)
