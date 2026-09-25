-- MIT. Workspace extensions: components attach per-workspace data and search
-- to the catalog through bindings of bee.workspace.catalog:extension, never
-- through catalog columns. The catalog finds every binding, calls it for one
-- workspace and checks what it answers; one failing extension never hides
-- the others.
local contract = require("contract")
local bounds = require("bounds")

type Item = {label: string, detail: string}
type Described = {binding: string, title: string, items: {Item}, total: integer, error: string?}
type Found = {binding: string, title: string, hits: {Item}, error: string?}
type Instance = {describe: (Instance, unknown) -> (unknown, unknown), search: (Instance, unknown) -> (unknown, unknown)}

local M = {}
M.CONTRACT = "bee.workspace.catalog:extension"
M.MAX_BINDINGS = 16
M.MAX_ITEMS = 50
M.MAX_LABEL = 240
M.MAX_DETAIL = 512

-- The bindings in a stable order, bounded.
function M.bindings(): ({string}?, string?)
    local found, err = contract.find_implementations(M.CONTRACT)
    if err or not found then return nil, "find workspace extensions: " .. tostring(err) end
    local ids: {string} = {}
    for _, id in ipairs(found) do ids[#ids + 1] = id end
    table.sort(ids)
    local bounded: {string} = {}
    for index = 1, math.min(#ids, M.MAX_BINDINGS) do bounded[index] = ids[index] end
    return bounded, nil
end

-- One line, cut to limit bytes at a character boundary.
local function line(value: unknown, limit: integer): string?
    if type(value) ~= "string" or value:find("%c") then return nil end
    if #value <= limit then return value end
    local cut = limit
    while cut > 0 do
        local byte = value:byte(cut + 1)
        if not byte or byte < 128 or byte >= 192 then break end
        cut = cut - 1
    end
    return value:sub(1, cut)
end

local function items(value: unknown): {Item}?
    if type(value) ~= "table" then return nil end
    local list: {Item} = {}
    for index, item in ipairs(value :: {unknown}) do
        if index > M.MAX_ITEMS then break end
        if type(item) ~= "table" then return nil end
        local label, detail = line(item.label, M.MAX_LABEL), line(item.detail == nil and "" or item.detail, M.MAX_DETAIL)
        if not label or not detail then return nil end
        list[#list + 1] = {label = label, detail = detail}
    end
    return list
end

-- A binding answers with the owner reply envelope {ok, error, value}.
local function answered(raw: unknown, call_error: unknown): ({[string]: unknown}?, string?)
    if call_error then return nil, tostring(call_error) end
    local reply = bounds.object(raw)
    if not reply or type(reply.ok) ~= "boolean" then return nil, "invalid extension reply" end
    if not reply.ok then
        local failure = bounds.object(reply.error)
        return nil, failure and tostring(failure.message) or "extension refused"
    end
    local value = bounds.object(reply.value)
    if not value then return nil, "invalid extension value" end
    return value, nil
end

local function opened(binding: string): (Instance?, string?)
    local instance, err = contract.open(binding)
    if err or not instance then return nil, "open extension: " .. tostring(err) end
    return instance :: Instance, nil
end

function M.describe(binding: string, workspace_id: string): Described
    local instance, open_error = opened(binding)
    if not instance then return {binding = binding, title = binding, items = {}, total = 0, error = open_error} end
    local raw, call_error = instance:describe({workspace_id = workspace_id})
    local value, failure = answered(raw, call_error)
    if not value then return {binding = binding, title = binding, items = {}, total = 0, error = failure} end
    local title, list = line(value.title, M.MAX_LABEL), items(value.items)
    local total = bounds.count(value.total)
    if not title or not list or not total then return {binding = binding, title = binding, items = {}, total = 0, error = "invalid extension description"} end
    return {binding = binding, title = title, items = list, total = total, error = nil}
end

function M.search(binding: string, workspace_id: string, text: string, limit: integer): Found
    local instance, open_error = opened(binding)
    if not instance then return {binding = binding, title = binding, hits = {}, error = open_error} end
    local raw, call_error = instance:search({workspace_id = workspace_id, text = text, limit = limit})
    local value, failure = answered(raw, call_error)
    if not value then return {binding = binding, title = binding, hits = {}, error = failure} end
    local title, list = line(value.title, M.MAX_LABEL), items(value.hits)
    if not title or not list then return {binding = binding, title = binding, hits = {}, error = "invalid extension search result"} end
    return {binding = binding, title = title, hits = list, error = nil}
end

return M
