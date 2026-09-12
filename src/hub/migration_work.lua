-- MIT. A private, measured migration receipt captured from one Hub plan.
-- This module only carries definitions across publication/recovery; execution
-- remains owned by the host migration runner and package functions.
local bounds = require("bounds")
local canonical = require("canonical")
local plan = require("plan")
local migrations = require("migrations")
local hash = require("hash")
local M = {}

local MAX_WORK = migrations.MAX_MIGRATIONS
local MAX_PACKAGE_ENTRIES = 512
local MAX_STATE_ENTRIES = 16384

type Definition = {id: string, component: string, target_db: string, timestamp: string, digest: string}
type Work = {entries: {Definition}, rows: {migrations.Row}}

local function dense(raw: unknown, label: string, maximum: integer): ({unknown}?, string?)
    if type(raw) ~= "table" then return nil, label .. " must be a dense list" end
    local value = raw :: {[number]: unknown}
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return nil, label .. " must be a dense list"
        end
        count = count + 1
    end
    if count > maximum or count ~= #value then return nil, label .. " exceeds its bound or is sparse" end
    local result: {unknown} = {}
    for index = 1, count do
        if value[index] == nil then return nil, label .. " must be a dense list" end
        result[index] = value[index]
    end
    return result, nil
end

local function component(raw: unknown): string?
    local value = bounds.line(raw, bounds.MAX_ID_BYTES)
    if not value or not value:match("^[%w_%-%.]+/[%w_%-%.]+$") then return nil end
    local org, name = value:match("^([^/]+)/([^/]+)$")
    if org == "." or org == ".." or name == "." or name == ".." then return nil end
    return value
end

local function migration_id(raw: unknown): string?
    local value = bounds.id(raw)
    if not value or not value:match("^[^:%s]+:[^:%s]+$") then return nil end
    return value
end

local function target(raw: unknown): string?
    return bounds.id(raw)
end

local function timestamp(raw: unknown): string?
    return bounds.line(raw, 160)
end

local function digest(raw: unknown): string?
    if type(raw) ~= "string" or #raw ~= 64 or not raw:match("^[0-9a-f]+$") then return nil end
    return raw
end

local function measure(kind: string, meta: {[string]: unknown}, data: unknown): (string?, string?)
    local encoded, encode_error = canonical.encode({kind = kind, meta = meta, data = data})
    if not encoded then return nil, encode_error or "cannot encode migration definition" end
    local measured, hash_error = hash.sha256(encoded)
    if not measured then return nil, tostring(hash_error or "cannot measure migration definition") end
    return measured, nil
end

local function definition(raw: unknown, label: string): (Definition?, string?)
    local value = bounds.object(raw)
    if not value then return nil, label .. " must be an object" end
    local extra = bounds.fields(value, {"id", "component", "target_db", "timestamp", "digest"})
    if extra then return nil, label .. ": " .. extra end
    local id = migration_id(value.id)
    local owner = component(value.component)
    local target_db = target(value.target_db)
    local at = timestamp(value.timestamp)
    local measured = digest(value.digest)
    if not id then return nil, label .. ".id is not a migration identifier" end
    if not owner then return nil, label .. ".component is not an org/module name" end
    if not target_db then return nil, label .. ".target_db is not an identifier" end
    if not at then return nil, label .. ".timestamp is not a bounded line" end
    if not measured then return nil, label .. ".digest is not a SHA-256 digest" end
    return {id = id, component = owner, target_db = target_db, timestamp = at, digest = measured}, nil
end

local function decode_rows(raw: unknown, definitions: {[string]: Definition}): ({migrations.Row}?, string?)
    local supplied, list_error = dense(raw, "migration work rows", MAX_WORK)
    if not supplied then return nil, list_error end
    local rows: {migrations.Row} = {}
    local seen: {[string]: boolean} = {}
    for index, item in ipairs(supplied) do
        local label = "migration work rows[" .. tostring(index) .. "]"
        local value = bounds.object(item)
        if not value then return nil, label .. " must be an object" end
        local extra = bounds.fields(value, {"id", "target_db", "module", "status", "reason"})
        if extra then return nil, label .. ": " .. extra end
        local id = migration_id(value.id)
        local target_db = target(value.target_db)
        local owner = component(value.module)
        local status = bounds.member(value.status, {"skipped", "applied", "reverted"})
        local reason: string? = nil
        if value.reason ~= nil then reason = bounds.text(value.reason, 160) end
        local selected = id and definitions[id] or nil
        if not id or not selected then return nil, label .. ".id is outside captured migration work" end
        if seen[id] then return nil, label .. ".id is duplicated" end
        if not target_db or target_db ~= selected.target_db then return nil, label .. ".target_db differs from its definition" end
        if not owner or owner ~= selected.component then return nil, label .. ".module differs from its definition" end
        if not status then return nil, label .. ".status is invalid" end
        if value.reason ~= nil and not reason then return nil, label .. ".reason is not bounded text" end
        seen[id] = true
        rows[#rows + 1] = {id = id, target_db = target_db, module = owner, status = status, reason = reason}
    end
    return rows, nil
end

function M.decode(raw: unknown): (Work?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "migration work must be an object" end
    local extra = bounds.fields(value, {"entries", "rows"})
    if extra then return nil, extra end
    local supplied, list_error = dense(value.entries, "migration work entries", MAX_WORK)
    if not supplied then return nil, list_error end
    if #supplied == 0 then return nil, "migration work entries must not be empty" end
    local entries: {Definition} = {}
    local definitions: {[string]: Definition} = {}
    for index, item in ipairs(supplied) do
        local decoded, decode_error = definition(item, "migration work entries[" .. tostring(index) .. "]")
        if not decoded then return nil, decode_error end
        if definitions[decoded.id] then return nil, "migration work contains a duplicate definition" end
        definitions[decoded.id] = decoded
        entries[#entries + 1] = decoded
    end
    local rows, rows_error = decode_rows(value.rows, definitions)
    if not rows then return nil, rows_error end
    return {entries = entries, rows = rows}, nil
end

function M.capture(prepared: plan.Prepared): (Work?, string?)
    if type(prepared) ~= "table" or type(prepared.plan) ~= "table" or type(prepared.resolved) ~= "table" then
        return nil, "migration plan is incomplete"
    end
    local planned, planned_error = dense(prepared.plan.migrations, "displayed migrations", MAX_WORK)
    if not planned then return nil, planned_error end
    if #planned == 0 then return nil, "displayed migration work is empty" end
    local packages, package_error = dense(prepared.resolved.packages, "resolved packages", MAX_WORK)
    if not packages then return nil, package_error end
    local found: {[string]: {component: string, kind: string, meta: {[string]: unknown}, data: unknown}} = {}
    for package_index, raw_package in ipairs(packages) do
        local package = bounds.object(raw_package)
        if not package then return nil, "resolved package " .. tostring(package_index) .. " is invalid" end
        local owner = component(package.component)
        if not owner then return nil, "resolved package " .. tostring(package_index) .. " has an invalid component" end
        local package_entries, entries_error = dense(package.entries, "resolved package entries", MAX_PACKAGE_ENTRIES)
        if not package_entries then return nil, entries_error end
        for entry_index, raw_entry in ipairs(package_entries) do
            local entry = bounds.object(raw_entry)
            if not entry then return nil, "resolved package entry " .. tostring(entry_index) .. " is invalid" end
            local id = migration_id(entry.id)
            if id then
                local kind = bounds.id(entry.kind)
                local meta = bounds.object(entry.meta)
                if not kind or not meta then return nil, "resolved migration entry " .. id .. " is incomplete" end
                if found[id] then return nil, "resolved packages contain duplicate migration " .. id end
                found[id] = {component = owner, kind = kind, meta = meta, data = entry.data}
            end
        end
    end
    local entries: {Definition} = {}
    local seen: {[string]: boolean} = {}
    for index, raw_migration in ipairs(planned) do
        local label = "displayed migrations[" .. tostring(index) .. "]"
        local value = bounds.object(raw_migration)
        if not value then return nil, label .. " must be an object" end
        local extra = bounds.fields(value, {"id", "component", "target_db", "timestamp"})
        if extra then return nil, label .. ": " .. extra end
        local id = migration_id(value.id)
        local displayed_owner = component(value.component)
        local target_db = target(value.target_db)
        local at = timestamp(value.timestamp)
        if not id or not displayed_owner or not target_db or not at then
            return nil, label .. " is incomplete"
        end
        if seen[id] then return nil, "displayed migrations contain a duplicate migration" end
        local package_entry = found[id]
        if not package_entry then return nil, "displayed migration is missing from resolved packages: " .. id end
        if package_entry.component ~= displayed_owner then return nil, "migration owner differs from resolved package: " .. id end
        if package_entry.kind ~= "function.lua" then return nil, "migration is not a function.lua entry: " .. id end
        if package_entry.meta.type ~= "migration" or package_entry.meta.target_db ~= target_db
            or package_entry.meta.timestamp ~= at then
            return nil, "displayed migration metadata differs from its package entry: " .. id
        end
        local measured, measure_error = measure(package_entry.kind, package_entry.meta, package_entry.data)
        if not measured then return nil, measure_error end
        seen[id] = true
        entries[#entries + 1] = {id = id, component = package_entry.component, target_db = target_db,
            timestamp = at, digest = measured}
    end
    return {entries = entries, rows = {}}, nil
end

-- Removal captures installed definitions, including orphaned dependencies.
function M.capture_removed(state: unknown, components: {[string]: boolean}): (Work?, string?)
    local snapshot = bounds.object(state)
    if not snapshot then return nil, "registry snapshot is invalid" end
    local supplied, problem = dense(snapshot.entries, "registry snapshot entries", MAX_STATE_ENTRIES)
    if not supplied then return nil, problem end
    local entries: {Definition} = {}
    for _, raw in ipairs(supplied) do
        local entry = bounds.object(raw)
        local metadata = entry and bounds.object(entry.meta) or nil
        local ownership = entry and bounds.object(entry.registry) or nil
        local owner = ownership and component(ownership.owner) or nil
        if entry and metadata and metadata.type == "migration" and owner and components[owner] then
            if entry.kind ~= "function.lua" then return nil, "migration is not a function.lua entry" end
            local measured, measure_error = measure("function.lua", metadata, entry.data)
            if not measured then return nil, measure_error end
            local captured, capture_error = definition({id = entry.id, component = owner,
                target_db = metadata.target_db, timestamp = metadata.timestamp, digest = measured}, "removed migration")
            if not captured then return nil, capture_error end
            entries[#entries + 1] = captured
        end
    end
    if #entries == 0 then return nil, nil end
    return M.decode({entries = entries, rows = {}})
end

function M.entries(work: Work): {migrations.Entry}
    local result: {migrations.Entry} = {}
    for _, definition in ipairs(work.entries) do
        result[#result + 1] = {id = definition.id,
            meta = {type = "migration", target_db = definition.target_db, timestamp = definition.timestamp},
            registry = {owner = definition.component}}
    end
    return result
end

function M.verify(work: Work, state: unknown): (boolean, string?)
    local checked, work_error = M.decode(work)
    if not checked then return false, work_error end
    local snapshot = bounds.object(state)
    if not snapshot then return false, "registry snapshot is invalid" end
    local raw_entries, entries_error = dense(snapshot.entries, "registry snapshot entries", MAX_STATE_ENTRIES)
    if not raw_entries then return false, entries_error end
    local wanted: {[string]: Definition} = {}
    for _, definition in ipairs(checked.entries) do wanted[definition.id] = definition end
    local observed: {[string]: {[string]: unknown}} = {}
    for _, raw_entry in ipairs(raw_entries) do
        local entry = bounds.object(raw_entry)
        if entry then
            local id = migration_id(entry.id)
            if id and wanted[id] then
                if observed[id] then return false, "registry snapshot contains duplicate migration " .. id end
                observed[id] = entry
            end
        end
    end
    for _, definition in ipairs(checked.entries) do
        local entry = observed[definition.id]
        if not entry then return false, "registry snapshot is missing migration " .. definition.id end
        local registry = bounds.object(entry.registry)
        if not registry or registry.owner ~= definition.component then
            return false, "migration owner differs at runtime: " .. definition.id
        end
        if entry.kind ~= "function.lua" then return false, "migration kind differs at runtime: " .. definition.id end
        local meta = bounds.object(entry.meta)
        if not meta then return false, "migration metadata is invalid at runtime: " .. definition.id end
        if meta.type ~= "migration" then return false, "migration type differs at runtime: " .. definition.id end
        if meta.target_db ~= definition.target_db then return false, "migration target differs at runtime: " .. definition.id end
        if meta.timestamp ~= definition.timestamp then return false, "migration timestamp differs at runtime: " .. definition.id end
        local measured, measure_error = measure("function.lua", meta, entry.data)
        if not measured then return false, measure_error end
        if measured ~= definition.digest then return false, "migration definition digest differs at runtime: " .. definition.id end
    end
    return true, nil
end

return M
