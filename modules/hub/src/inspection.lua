-- MIT. Pure exact-artifact request and inspection values.
local bounds = require("bounds")
local requirements = require("requirements")
local M = {}
type Request = {component: string, version: string, parameters: {requirements.Parameter},
    entry_offset: integer, entry_limit: integer, include_data: boolean}
type Entry = {id: string, kind: string, meta: {[string]: unknown}, data: unknown}
type Summary = {id: string, kind: string}
type Inspection = {component: string, version: string, digest: string, requirements: requirements.Result,
    entries: {Entry}, next_offset: integer?, eof: boolean}
M.MAX_ENTRIES_PER_PAGE = 32

function M.decode(raw: unknown): (Request?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "package request must be an object" end
    local extra = bounds.fields(value, {"component", "version", "parameters", "entry_offset", "entry_limit", "include_data"})
    if extra then return nil, extra end
    local component = bounds.line(value.component, 160)
    if not component or not component:match("^[%w_%-%.]+/[%w_%-%.]+$") then return nil, "component must be an org/module name" end
    local org, name = component:match("^([^/]+)/([^/]+)$")
    if org == "." or org == ".." or name == "." or name == ".." then return nil, "component must be an org/module name" end
    local version = bounds.line(value.version, 128)
    if not version or not version:match("^v?%d+%.%d+%.%d+[%w%.%+%-]*$") then return nil, "an exact package version is required" end
    local supplied: unknown = value.parameters
    if supplied == nil then supplied = {} end
    local parameters, parameter_error = requirements.parameters(supplied)
    if not parameters then return nil, parameter_error end
    local entry_offset = 0
    if value.entry_offset ~= nil then
        local declared = bounds.count(value.entry_offset)
        if not declared then return nil, "entry_offset must be a nonnegative integer" end
        entry_offset = declared
    end
    local entry_limit = M.MAX_ENTRIES_PER_PAGE
    if value.entry_limit ~= nil then
        local declared = bounds.integer(value.entry_limit)
        if not declared or declared < 1 or declared > M.MAX_ENTRIES_PER_PAGE then
            return nil, "entry_limit must be between 1 and " .. tostring(M.MAX_ENTRIES_PER_PAGE)
        end
        entry_limit = declared
    end
    -- Summaries travel first: entry source crosses only on explicit request
    -- or through files and read_file windows.
    local include_data = false
    if value.include_data ~= nil then
        if type(value.include_data) ~= "boolean" then return nil, "include_data must be a boolean" end
        include_data = value.include_data
    end
    return {component = component, version = version, parameters = parameters,
        entry_offset = entry_offset, entry_limit = entry_limit, include_data = include_data}, nil
end
-- Summaries first: one page of entry identities without data, with the cursor
-- for the next page. A summary keeps the entry shape with no payload, so
-- planners that need source request it explicitly or read selected entries
-- through files and read_file.
function M.page(entries: {Entry}, offset: integer, limit: integer, include_data: boolean): {entries: {Entry}, next_offset: integer?, eof: boolean}
    local page: {Entry} = {}
    for index = offset + 1, math.min(offset + limit, #entries) do
        local entry = entries[index]
        if include_data then page[#page + 1] = entry
        else page[#page + 1] = {id = entry.id, kind = entry.kind, meta = {}, data = nil} end
    end
    local consumed = offset + #page
    return {entries = page, next_offset = consumed < #entries and consumed or nil, eof = consumed >= #entries}
end

return M
