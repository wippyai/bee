-- MIT. Saved preferences select reviewed launch definitions, never host authority.
local bounds = require("bounds")
local M = {}
M.SCHEMA = "bee.agent-profile@1"
-- A Codex config profile name is a plain identifier: letters, digits, dash and
-- underscore, never empty, never a path. Codex rejects a leading dash and any
-- dot or separator in `--profile`, so this is the same admission Codex makes.
M.MAX_CONFIG_PROFILE_BYTES = 64
type Profile = {title: string, definition_ref: string, options: {[string]: string | number | boolean}, mcp_tools: {string}, instructions: string, config_profile: string?}
type Request = {operation: string, workspace_id: string, profile_id: string, profile: Profile?, expected_revision: integer, idempotency_key: string, after_key: string, expected_cursor: integer?, limit: integer}

function M.profile(value: unknown): (Profile?, string?)
    local object = bounds.object(value)
    if not object then return nil, "profile must be an object" end
    local extra = bounds.fields(object, {"title", "definition_ref", "options", "mcp_tools", "instructions", "config_profile"})
    if extra then return nil, extra end
    local title = bounds.line(object.title, 80)
    if not title or title:match("^%s*$") then return nil, "title must contain 1 to 80 printable bytes" end
    local definition_ref = bounds.id(object.definition_ref)
    if not definition_ref then return nil, "definition_ref must be an identifier" end
    local raw_options = bounds.object(object.options == nil and {} or object.options)
    if not raw_options then return nil, "options must be an object" end
    local options: {[string]: string | number | boolean} = {}
    local count = 0
    for key, item in pairs(raw_options) do
        count = count + 1
        if count > 8 then return nil, "profile exceeds 8 options" end
        if #key > 80 or not key:match("^[a-z][a-z0-9_]*$") then return nil, "invalid option name" end
        if type(item) == "string" then
            if #item > 512 or item:find("%c") then return nil, "option text must contain at most 512 printable bytes" end
        elseif type(item) == "number" then
            if item ~= item or item == math.huge or item == -math.huge then return nil, "option number must be finite" end
        elseif type(item) ~= "boolean" then
            return nil, "option values must be scalar"
        end
        options[key] = item
    end
    local tools, tools_error = bounds.ids(object.mcp_tools == nil and {} or object.mcp_tools, true)
    if not tools then return nil, tools_error end
    local instructions = bounds.text(object.instructions == nil and "" or object.instructions, 4096)
    if not instructions then return nil, "instructions must contain at most 4096 bytes" end
    for index = 1, #instructions do
        local byte = instructions:byte(index)
        if (byte < 32 and byte ~= 9 and byte ~= 10 and byte ~= 13) or byte == 127 then
            return nil, "instructions contain unsupported control bytes"
        end
    end
    local config_profile: string? = nil
    if object.config_profile ~= nil then
        local declared = bounds.text(object.config_profile, M.MAX_CONFIG_PROFILE_BYTES)
        if not declared or not declared:match("^[A-Za-z0-9_][A-Za-z0-9_-]*$") then
            return nil, "config_profile must be a plain Codex profile name"
        end
        config_profile = declared
    end
    return {title = title, definition_ref = definition_ref, options = options, mcp_tools = tools, instructions = instructions, config_profile = config_profile}, nil
end

function M.decode(value: unknown): (Request?, string?)
    local object = bounds.object(value)
    if not object then return nil, "request must be an object" end
    local operation = bounds.member(object.operation, {"get", "list", "put", "remove"})
    if not operation then return nil, "unknown profile operation" end
    local fields: {string}
    if operation == "get" then fields = {"operation", "workspace_id", "profile_id"}
    elseif operation == "list" then fields = {"operation", "workspace_id", "after_key", "expected_cursor", "limit"}
    elseif operation == "put" then fields = {"operation", "workspace_id", "profile_id", "expected_revision", "idempotency_key", "profile"}
    elseif operation == "remove" then fields = {"operation", "workspace_id", "profile_id", "expected_revision", "idempotency_key"}
    else return nil, "unknown profile operation" end
    local extra = bounds.fields(object, fields)
    if extra then return nil, extra end
    local workspace = bounds.id(object.workspace_id)
    if not workspace then return nil, "workspace_id must be an identifier" end
    local request: Request = {operation = operation, workspace_id = workspace, profile_id = "", expected_revision = 0, idempotency_key = "", after_key = "", limit = 32}
    if operation == "list" then
        local after_key = object.after_key == nil and "" or object.after_key
        if after_key ~= "" and not bounds.id(after_key) then return nil, "after_key must be an identifier" end
        local cursor = bounds.count(object.expected_cursor)
        local limit = bounds.count(object.limit == nil and 32 or object.limit)
        if object.expected_cursor ~= nil and not cursor then return nil, "expected_cursor must be a nonnegative safe integer" end
        if after_key ~= "" and not cursor then return nil, "continuation requires expected_cursor" end
        if not limit or limit < 1 or limit > 64 then return nil, "limit must be between 1 and 64" end
        request.after_key = after_key :: string
        request.expected_cursor = cursor
        request.limit = limit
        return request, nil
    end
    local id = bounds.id(object.profile_id)
    if not id then return nil, "profile_id must be an identifier" end
    request.profile_id = id
    if operation == "get" then return request, nil end
    local revision = bounds.count(object.expected_revision)
    local key = bounds.id(object.idempotency_key)
    if not revision then return nil, "expected_revision must be a nonnegative safe integer" end
    if not key then return nil, "idempotency_key must be an identifier" end
    request.expected_revision = revision
    request.idempotency_key = key
    if operation == "put" then
        local profile, profile_error = M.profile(object.profile)
        if not profile then return nil, profile_error end
        request.profile = profile
    end
    return request, nil
end
return M
