-- MIT. Reconcile one exact decoded artifact into one owner-local registry
-- overlay. The caller chooses the owner from destination configuration; no
-- request field is consulted here. Overlay generations provide the write CAS.
local registry = require("registry")
local artifact = require("artifact")
local canonical = require("canonical")
local bounds = require("bounds")

local M = {}

type Entry = {[string]: unknown}
type Snapshot = {
    entries: (Snapshot) -> ({unknown}?, unknown?),
    changes: (Snapshot) -> unknown,
}
type Changes = {
    create: (Changes, Entry) -> (unknown?, unknown?),
    update: (Changes, Entry) -> (unknown?, unknown?),
    delete: (Changes, string) -> (unknown?, unknown?),
    apply: (Changes) -> (unknown?, unknown?),
}
type Open = (string) -> (unknown?, unknown?)
type Conflict = (unknown) -> boolean

local function encoded(value: unknown): (string?, string?)
    if type(value) ~= "table" then return nil, "registry entry is not an object" end
    local source = value :: Entry
    local normalized: Entry = {}
    for field, item in pairs(source) do normalized[field] = item end
    -- The registry's author-facing snapshot always emits an empty metadata
    -- object. Treat omitted metadata in an artifact as that same canonical
    -- default; every non-default field remains byte-for-byte significant.
    if normalized.meta == nil then normalized.meta = {} end
    local result, err = canonical.encode(normalized, artifact.MAX_BYTES)
    if not result then return nil, tostring(err or "cannot encode registry entry") end
    return result, nil
end

local function current_entries(snapshot: Snapshot): ({[string]: Entry}?, string?)
    local rows, err = snapshot:entries()
    if not rows then return nil, tostring(err or "read governance overlay") end
    local result: {[string]: Entry} = {}
    for _, raw in ipairs(rows) do
        if type(raw) ~= "table" then return nil, "governance overlay contains a malformed entry" end
        local row = raw :: Entry
        local id = bounds.id(row.id)
        if not id then return nil, "governance overlay contains an invalid entry id" end
        if result[id] then return nil, "governance overlay contains duplicate entry " .. id end
        result[id] = row
    end
    return result, nil
end

local function stage(snapshot: Snapshot, desired: {Entry}): (Changes?, boolean?, string?)
    local current, current_error = current_entries(snapshot)
    if not current then return nil, nil, current_error end
    local changes = snapshot:changes() :: Changes
    if not changes then return nil, nil, "open governance overlay changes" end
    local wanted: {[string]: boolean} = {}
    local changed = false
    for _, entry in ipairs(desired) do
        local id = entry.id :: string
        wanted[id] = true
        local present = current[id]
        if not present then
            local ok, err = changes:create(entry)
            if not ok then return nil, nil, tostring(err or "create governance overlay entry") end
            changed = true
        else
            local before, before_error = encoded(present)
            local after, after_error = encoded(entry)
            if not before or not after then return nil, nil, before_error or after_error end
            if before ~= after then
                local ok, err = changes:update(entry)
                if not ok then return nil, nil, tostring(err or "update governance overlay entry") end
                changed = true
            end
        end
    end
    for id in pairs(current) do
        if not wanted[id] then
            local ok, err = changes:delete(id)
            if not ok then return nil, nil, tostring(err or "delete governance overlay entry") end
            changed = true
        end
    end
    return changes, changed, nil
end

local function matches_snapshot(snapshot: Snapshot, desired: {Entry}): (boolean?, string?)
    local current, current_error = current_entries(snapshot)
    if not current then return nil, current_error end
    if #desired ~= 0 then
        local count = 0
        for _ in pairs(current) do count = count + 1 end
        if count ~= #desired then return false, nil end
    elseif next(current) then
        return false, nil
    end
    for _, entry in ipairs(desired) do
        local present = current[entry.id :: string]
        if not present then return false, nil end
        local before, before_error = encoded(present)
        local after, after_error = encoded(entry)
        if not before or not after then return nil, before_error or after_error end
        if before ~= after then return false, nil end
    end
    return true, nil
end

-- The injectable form keeps generation behavior testable without granting a
-- unit test registry authority. Production uses reconcile(), below.
function M.reconcile_with(open: Open, conflict: Conflict, owner_raw: unknown, entries_raw: unknown): ({[string]: unknown}?, string?)
    local owner = bounds.id(owner_raw)
    if not owner then return nil, "governance overlay owner is invalid" end
    local measured, artifact_error = artifact.create(entries_raw)
    if not measured then return nil, artifact_error end
    local wanted = measured.entries
    local raw_snapshot, open_error = open(owner)
    if not raw_snapshot then return nil, tostring(open_error or "open governance overlay") end
    local snapshot = raw_snapshot :: Snapshot
    local changes, changed, stage_error = stage(snapshot, wanted)
    if not changes or changed == nil then return nil, stage_error end
    if not changed then
        return {owner = owner, artifact_digest = measured.digest, entries = #wanted,
            changed = false, attempts = 1}, nil
    end
    local applied, apply_error = changes:apply()
    if applied then
        return {owner = owner, artifact_digest = measured.digest, entries = #wanted,
            changed = true, attempts = 1}, nil
    end
    if conflict(apply_error) then return nil, "governance overlay changed during apply; preflight again" end
    return nil, tostring(apply_error or "apply governance overlay")
end

function M.matches_with(open: Open, owner_raw: unknown, entries_raw: unknown): (boolean?, string?)
    local owner = bounds.id(owner_raw)
    if not owner then return nil, "governance overlay owner is invalid" end
    local measured, artifact_error = artifact.create(entries_raw)
    if not measured then return nil, artifact_error end
    local raw_snapshot, open_error = open(owner)
    if not raw_snapshot then return nil, tostring(open_error or "open governance overlay") end
    return matches_snapshot(raw_snapshot :: Snapshot, measured.entries)
end

local function open(owner: string): (unknown?, unknown?)
    return registry.overlay(owner)
end

local function conflict(err: unknown): boolean
    if (type(err) ~= "userdata" and type(err) ~= "table") or errors == nil or errors.CONFLICT == nil then return false end
    local value = err :: any
    return value:kind() == errors.CONFLICT
end

function M.reconcile(owner: unknown, entries: unknown): ({[string]: unknown}?, string?)
    return M.reconcile_with(open, conflict, owner, entries)
end


function M.matches(owner: unknown, entries: unknown): (boolean?, string?)
    return M.matches_with(open, owner, entries)
end

return M
