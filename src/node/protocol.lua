-- MIT. User-editable descriptions are separate from node identity and grants.
local bounds = require("bounds")
local appearance = require("appearance")
local M = {}
M.SCHEMA = "bee.node-description@1"
type Metadata = {display_name: string, description: string, labels: {[string]: string}}
type Update = {expected_revision: integer, idempotency_key: string, metadata: Metadata}

local function line(value: unknown, limit: integer, empty: boolean): string?
    if type(value) ~= "string" or #value > limit or value:find("%c") then return nil end
    if not empty and value:match("^%s*$") then return nil end
    return value
end

function M.metadata(value: unknown): (Metadata?, string?)
    local object = bounds.object(value)
    if not object then return nil, "metadata must be an object" end
    local extra = bounds.fields(object, {"display_name", "description", "labels"})
    if extra then return nil, extra end
    local name = line(object.display_name, 80, false)
    if not name then return nil, "display_name must contain 1 to 80 printable bytes" end
    local description = line(object.description == nil and "" or object.description, 512, true)
    if not description then return nil, "description must contain at most 512 printable bytes" end
    local raw = bounds.object(object.labels == nil and {} or object.labels)
    if not raw then return nil, "labels must be an object" end
    local labels: {[string]: string} = {}
    local count = 0
    for key, item in pairs(raw) do
        count = count + 1
        if count > 16 then return nil, "metadata exceeds 16 labels" end
        if #key > 40 or not key:match("^[a-z][a-z0-9_.-]*$") then return nil, "invalid label key" end
        local text = line(item, 80, true)
        if not text then return nil, "label values must contain at most 80 printable bytes" end
        labels[key] = text
    end
    return {display_name = name, description = description, labels = labels}, nil
end

function M.update(value: unknown): (Update?, string?)
    local object = bounds.object(value)
    if not object then return nil, "request must be an object" end
    local extra = bounds.fields(object, {"expected_revision", "idempotency_key", "metadata"})
    if extra then return nil, extra end
    local revision = bounds.count(object.expected_revision)
    if not revision then return nil, "expected_revision must be a nonnegative safe integer" end
    local key = bounds.id(object.idempotency_key)
    if not key then return nil, "idempotency_key must be an identifier" end
    local metadata, err = M.metadata(object.metadata)
    if not metadata then return nil, err end
    return {expected_revision = revision, idempotency_key = key, metadata = metadata}, nil
end

-- Defaults belong to this node, independently of descriptive metadata.
type AppearanceUpdate = {expected_revision: integer, idempotency_key: string, preferences: appearance.Preferences}
function M.preferences(value: unknown): (appearance.Preferences?, string?)
    local object = bounds.object(value)
    if not object then return nil, "preferences must be an object" end
    local extra = bounds.fields(object, {"theme", "background", "taskbar"})
    if extra then return nil, extra end
    if object.theme == nil or object.background == nil or object.taskbar == nil then
        return nil, "theme, background and taskbar are required"
    end
    local decoded = appearance.decode(object)
    if not decoded then return nil, "invalid appearance preferences" end
    return decoded, nil
end
function M.appearance_update(value: unknown): (AppearanceUpdate?, string?)
    local object = bounds.object(value)
    if not object then return nil, "request must be an object" end
    local extra = bounds.fields(object, {"expected_revision", "idempotency_key", "preferences"})
    if extra then return nil, extra end
    local revision = bounds.count(object.expected_revision)
    if not revision then return nil, "expected_revision must be a nonnegative safe integer" end
    local key = bounds.id(object.idempotency_key)
    if not key then return nil, "idempotency_key must be an identifier" end
    local preferences, err = M.preferences(object.preferences)
    if not preferences then return nil, err end
    return {expected_revision = revision, idempotency_key = key, preferences = preferences}, nil
end

function M.empty(value: unknown): string?
    local object = bounds.object(value)
    if not object then return "request must be an object" end
    return bounds.fields(object, {})
end

function M.page(value: unknown): (integer?, integer?, string?)
    local object = bounds.object(value)
    if not object then return nil, nil, "request must be an object" end
    local extra = bounds.fields(object, {"cursor", "limit"})
    if extra then return nil, nil, extra end
    local cursor = bounds.count(object.cursor)
    local limit = bounds.count(object.limit == nil and 32 or object.limit)
    if not cursor then return nil, nil, "cursor must be a nonnegative safe integer" end
    if not limit or limit < 1 or limit > 64 then return nil, nil, "limit must be between 1 and 64" end
    return cursor, limit, nil
end

return M
