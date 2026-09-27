-- MIT. Per-CLI adapter argument rendering for extra writable roots.
-- Formats driver profile writable_roots / --add-dir arguments for active
-- permission modes.
local canonical = require("canonical")
local driver_types = require("driver_types")
local M = {}
type Adapter = driver_types.GitWritableRootsAdapter

local function codex_enabled(argv: {string}): boolean
    for index, argument in ipairs(argv) do
        if argument == "--sandbox=workspace-write" or (argument == "--sandbox" and argv[index + 1] == "workspace-write") then return true end
    end
    return false
end

local function claude_enabled(argv: {string}): boolean
    for index, argument in ipairs(argv) do
        if argument == "--permission-mode" then
            local mode = argv[index + 1]
            if mode == "default" or mode == "acceptEdits" or mode == "dontAsk" then return true end
        elseif argument:match("^%-%-permission%-mode=") then
            local mode = argument:match("=(.*)$")
            if mode == "default" or mode == "acceptEdits" or mode == "dontAsk" then return true end
        end
    end
    return false
end

local function agy_enabled(argv: {string}): boolean
    for _, argument in ipairs(argv) do
        if argument == "--sandbox" or argument == "--sandbox=true" then return true end
    end
    return false
end

local function codex_arguments(roots: {string}): ({string}?, string?)
    local encoded, encode_error = canonical.encode(roots)
    if not encoded then return nil, "encode Codex writable roots: " .. tostring(encode_error) end
    return {"--config", "sandbox_workspace_write.writable_roots=" .. encoded}, nil
end

local function add_directory_arguments(roots: {string}): ({string}?, string?)
    local result: {string} = {}
    for _, root in ipairs(roots) do
        result[#result + 1] = "--add-dir"
        result[#result + 1] = root
    end
    return result, nil
end

type AdapterHandler = {enabled: ({string}) -> boolean, arguments: ({string}) -> ({string}?, string?)}
local ADAPTERS: {[Adapter]: AdapterHandler} = {}
ADAPTERS[driver_types.GIT_WRITABLE_ROOTS_ADAPTERS.CODEX_WORKSPACE_WRITE] = {enabled = codex_enabled, arguments = codex_arguments}
ADAPTERS[driver_types.GIT_WRITABLE_ROOTS_ADAPTERS.CLAUDE_ADD_DIR] = {enabled = claude_enabled, arguments = add_directory_arguments}
ADAPTERS[driver_types.GIT_WRITABLE_ROOTS_ADAPTERS.AGY_ADD_DIR] = {enabled = agy_enabled, arguments = add_directory_arguments}

function M.enabled(adapter: Adapter, argv: {string}): boolean
    local handler = ADAPTERS[adapter]
    return handler ~= nil and handler.enabled(argv)
end

function M.arguments(adapter: Adapter, roots: {string}): ({string}?, string?)
    if #roots == 0 then return {}, nil end
    local handler = ADAPTERS[adapter]
    if not handler then return nil, "unsupported Git writable-roots adapter" end
    return handler.arguments(roots)
end

return M
