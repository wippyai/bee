# wippy lint hid parse errors

Found 2026-09-08 while building `bee.hive`. Fix: runtime PR
https://github.com/wippyai/runtime/pull/691 (`fix/lint-report-parse-errors`).
Until the pinned runtime includes it, a syntax error shows only as a wrong
count in the summary line.

## Symptom

`interface` is a reserved word of the typed Lua grammar. An entry with
`local interface = ...` fails to parse; `wippy lint` counted that error in its
summary (`lint failed: 1 errors`) but printed `No issues found`, because the
parse-error path in `cmd/wippy/cmd/lint.go` filled the plain diagnostic list
and never the rendered one the terminal report iterates. The entry stayed
unchecked, its exports became `any` for importers, and the visible symptoms
were unrelated type errors in the importing files.

## Reproducer

```lua
local M = {}
local function pair(target: {[string]: unknown}): (string?, string?)
    local operation = tostring(target.operation_ref)
    local interface = tostring(target.interface_ref)
    return operation, interface
end
function M.bad(): string
    return 1
end
return M
```

Pinned binary: `No issues found`, exit 1. Fixed binary:

```
error[E0000]: syntax error
  --> app:broken:4:19
4 |     local interface = tostring(target.interface_ref)
```

## Rule for Bee code

Do not name a variable `interface`. Read the summary line of `make lint`,
not only the listed diagnostics, until the runtime pin carries PR 691.
