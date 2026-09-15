-- MIT. Fixture instruction builders for driver configuration tests.
local M = {}

function M.build_ok(args: unknown): string
    local tag = "default"
    if type(args) == "table" and type((args :: {[string]: unknown}).tag) == "string" then
        tag = (args :: {[string]: unknown}).tag :: string
    end
    return "Dynamic memory rules from " .. tag
end

function M.build_bad_output(_: unknown): {[string]: unknown}
    return {invalid = "not a string"}
end

function M.build_control_chars(_: unknown): string
    return "invalid\27escape"
end

function M.build_oversized(_: unknown): string
    return string.rep("x", 4097)
end

function M.build_error(_: unknown): string
    error("intentional builder failure")
end

function M.build_empty(_: unknown): string
    return ""
end

return M
