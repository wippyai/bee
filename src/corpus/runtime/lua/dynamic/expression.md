# "Expression Language"

_Path: en/lua/dynamic/expression_

> "Evaluate dynamic expressions using expr-lang syntax. Compile and execute safe expressions for filtering, validation, and rule evaluation without full…"

## Table of Contents

- Expression Language

## Content

# Expression Language

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="workflow"/>

The `expr` module compiles and evaluates [expr-lang](https://expr-lang.org/) expressions for filtering, validation, calculations, and rule evaluation without running Lua source code. This page is the canonical Lua API reference; its examples run inside an existing Wippy Lua process whose entry declares the `expr` module, but they are not standalone Wippy applications. See [Dynamic Evaluation](./eval.md) when choosing between expressions and capability-restricted Lua.



## Loading


```lua
local expr = require("expr")
```



## Caching


`expr.eval` keeps an internal LRU cache of compiled expressions (default capacity 1000). The cache is built into the module and requires no configuration.



## Evaluating Expressions


Evaluate an expression string and return its result. The function uses the internal cache of compiled expressions:

```lua
-- Simple math
local result, err = expr.eval("1 + 2 * 3")
if err then
    return nil, err
end
-- result == 7

-- With variables
local total, total_err = expr.eval("price * quantity", {
    price = 29.99,
    quantity = 3
})
if total_err then
    return nil, total_err
end
-- total == 89.97

-- Ternary operator
local label, label_err = expr.eval('score > 90 ? "A" : score > 80 ? "B" : "C"', {
    score = 85
})
if label_err then
    return nil, label_err
end
-- label == "B"
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `expression` | string | expr-lang syntax expression |
| `env` | `any` | Variable environment for the expression (optional; normally a table) |

**Returns:** `any, error`



## Compiling Expressions


Compile an expression into a reusable `Program` for repeated evaluation:

```lua
-- Compile once for repeated use
local discount_calc, err = expr.compile("price * (1 - discount_rate)")
if err then
    return nil, err
end

-- Reuse with different inputs
local price1, run_err = discount_calc:run({price = 100, discount_rate = 0.1})
if run_err then
    return nil, run_err
end

local price2, second_run_err = discount_calc:run({price = 50, discount_rate = 0.2})
if second_run_err then
    return nil, second_run_err
end
-- price1 == 90 and price2 == 40
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `expression` | string | expr-lang syntax expression |
| `env` | `any` | Type-hint environment for compilation (optional; normally a table) |

**Returns:** `Program, error`



## Running Compiled Programs


Run a compiled expression with the provided environment:

```lua
-- Validation rule
local validator, compile_err = expr.compile("len(password) >= 8 and len(password) <= 128")
if compile_err then
    return nil, compile_err
end

local valid, run_err = validator:run({password = "securepass123"})
if run_err then
    return nil, run_err
end
-- valid == true

-- Pricing rule
local pricer, pricing_compile_err = expr.compile([[
    base_price * quantity * (1 - bulk_discount) + shipping
]])
if pricing_compile_err then
    return nil, pricing_compile_err
end

local order_total, pricing_run_err = pricer:run({
    base_price = 25.00,
    quantity = 10,
    bulk_discount = 0.15,
    shipping = 12.50
})
if pricing_run_err then
    return nil, pricing_run_err
end
-- order_total == 225.00
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `env` | `any` | Variable environment for the expression (optional; normally a table) |

**Returns:** `any, error`



## Built-in Functions


Expr-lang includes built-in functions for common operations:

```lua
local maximum, max_err = expr.eval("max(1, 5, 3)")
if max_err then
    return nil, max_err
end

local uppercase, upper_err = expr.eval('upper("hello")')
if upper_err then
    return nil, upper_err
end

local total, sum_err = expr.eval("sum(values)", {values = {1, 2, 3, 4}})
if sum_err then
    return nil, sum_err
end
-- maximum == 5, uppercase == "HELLO", and total == 10
```

Other built-ins include `min`, `abs`, `ceil`, `floor`, `len`, `lower`, and
`trim`. Expr-lang also provides operators such as `contains` for strings and
`in` for membership tests.



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Expression is empty | `errors.INVALID` | no |
| Expression syntax invalid | `errors.INTERNAL` | no |
| Expression evaluation fails | `errors.INTERNAL` | no |
| Result conversion fails | `errors.INTERNAL` | no |

See [Error Handling](lua/core/errors.md) for working with errors.



## Navigation

Previous: "Command Execution" (lua/dynamic/exec)
Next: "WebAssembly Runtime" (wasm/overview)
