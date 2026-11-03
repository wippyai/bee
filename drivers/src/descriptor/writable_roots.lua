-- MIT. A CLI descriptor's writable_roots declaration: the argv token
-- sequences that put the CLI in a mode that honors extra writable roots, and
-- the arguments that name them. argv renders once with {roots} as the roots'
-- canonical JSON list; argv_each renders once per root with {root}.
local bounds = require("bounds")
local canonical = require("canonical")
local M = {}

M.MAX_SEQUENCES = 16
M.MAX_TOKENS = 8

type Declaration = {when_argv: {{string}}, argv: {string}?, argv_each: {string}?}

local function tokens(raw: unknown, label: string, minimum: integer): ({string}?, string?)
    local list = bounds.array(raw, M.MAX_TOKENS)
    if not list or #list < minimum then return nil, label .. " must list " .. tostring(minimum) .. " to " .. tostring(M.MAX_TOKENS) .. " tokens" end
    local result: {string} = {}
    for index, item in ipairs(list) do
        local token = bounds.line(item, 256)
        if not token or token == "" then return nil, label .. " token " .. tostring(index) .. " is not one line of text" end
        result[index] = token
    end
    return result, nil
end

-- placeholders refuses a template that names any placeholder but the one its
-- form renders, or never names it.
local function placeholders(template: {string}, allowed: string, label: string): string?
    local named = false
    for _, token in ipairs(template) do
        for name in token:gmatch("{([^{}]*)}") do
            if name ~= allowed then return label .. " names unknown placeholder {" .. name .. "}" end
            named = true
        end
    end
    if not named then return label .. " never names {" .. allowed .. "}" end
    return nil
end

function M.decode(raw: unknown): (Declaration?, string?)
    local item = bounds.object(raw)
    if not item then return nil, "writable_roots must be an object" end
    local extra = bounds.fields(item, {"when_argv", "argv", "argv_each"})
    if extra then return nil, "writable_roots: " .. extra end
    if (item.argv == nil) == (item.argv_each == nil) then return nil, "writable_roots renders roots with exactly one of argv or argv_each" end
    local sequences = bounds.array(item.when_argv, M.MAX_SEQUENCES)
    if not sequences or #sequences == 0 then return nil, "writable_roots.when_argv must list 1 to " .. tostring(M.MAX_SEQUENCES) .. " token sequences" end
    local when_argv: {{string}} = {}
    for index, sequence in ipairs(sequences) do
        local selected, sequence_error = tokens(sequence, "writable_roots.when_argv[" .. tostring(index) .. "]", 1)
        if not selected then return nil, sequence_error end
        when_argv[index] = selected
    end
    local result: Declaration = {when_argv = when_argv}
    if item.argv ~= nil then
        local argv, argv_error = tokens(item.argv, "writable_roots.argv", 1)
        if not argv then return nil, argv_error end
        local placeholder_error = placeholders(argv, "roots", "writable_roots.argv")
        if placeholder_error then return nil, placeholder_error end
        result.argv = argv
    else
        local argv_each, each_error = tokens(item.argv_each, "writable_roots.argv_each", 1)
        if not argv_each then return nil, each_error end
        local placeholder_error = placeholders(argv_each, "root", "writable_roots.argv_each")
        if placeholder_error then return nil, placeholder_error end
        result.argv_each = argv_each
    end
    return result, nil
end

-- enabled: the launch argv holds one of the declared token sequences.
function M.enabled(declaration: Declaration, argv: {string}): boolean
    for _, sequence in ipairs(declaration.when_argv) do
        for start = 1, #argv - #sequence + 1 do
            local matched = true
            for offset, token in ipairs(sequence) do
                if argv[start + offset - 1] ~= token then matched = false; break end
            end
            if matched then return true end
        end
    end
    return false
end

local function substitute(template: {string}, name: string, value: string): {string}
    local result: {string} = {}
    for index, token in ipairs(template) do
        result[index] = (token:gsub("{" .. name .. "}", function(): string return value end))
    end
    return result
end

-- arguments renders the declared arguments for the roots; no roots render
-- nothing.
function M.arguments(declaration: Declaration, roots: {string}): ({string}?, string?)
    if #roots == 0 then return {}, nil end
    if declaration.argv then
        local encoded, encode_error = canonical.encode(roots)
        if not encoded then return nil, "encode writable roots: " .. tostring(encode_error) end
        return substitute(declaration.argv, "roots", encoded), nil
    end
    local result: {string} = {}
    for _, root in ipairs(roots) do
        for _, token in ipairs(substitute(assert(declaration.argv_each), "root", root)) do result[#result + 1] = token end
    end
    return result, nil
end

return M
