-- MIT. Reconcile one exact decoded artifact into one owner-local registry
-- overlay. The caller chooses the owner from destination configuration; no
-- request field is consulted here. Overlay generations provide the write CAS.
local registry = require("registry")
local artifact = require("artifact")
local canonical = require("canonical")
local hash = require("hash")
local bounds = require("bounds")
local application_admission = require("application_admission")
local capability_grants = require("capability_grants")

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
    if normalized.meta == nil
        or (type(normalized.meta) == "table" and next(normalized.meta :: table) == nil) then
        normalized.meta = table.create(0, 1)
    end
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

-- Empty is a valid desired overlay state used for cleanup, although it is not
-- a publishable application artifact. Measure it with the artifact envelope
-- without weakening artifact.create's nonempty publication contract.
local function desired(raw: unknown): ({Entry}?, string?, string?)
    if type(raw) == "table" and next(raw :: table) == nil then
        local entries: {Entry} = {}
        local bytes, encode_error = canonical.encode({schema_revision = artifact.SCHEMA,
            entries = canonical.empty_like(raw)}, artifact.MAX_BYTES)
        if not bytes then return nil, nil, tostring(encode_error or "measure empty governance overlay") end
        local digest, digest_error = hash.sha256(bytes)
        if not digest then return nil, nil, tostring(digest_error or "measure empty governance overlay") end
        return entries, digest, nil
    end
    local measured, artifact_error = artifact.create(raw)
    if not measured then return nil, nil, artifact_error end
    for _, entry in ipairs(measured.entries) do
        if application_admission.reserved(entry.id) then
            return nil, nil, "portable artifact entry uses a reserved application admission identity"
        end
    end
    return measured.entries, measured.digest, nil
end

-- A governed application admission is one derived registry entry beside the
-- portable artifact.  Measure its bytes separately so adding it does not turn
-- a valid 512-entry artifact into an invalid 513-entry artifact or alter the
-- bytes that replication publishes.
local function composed(raw: unknown, admission_raw: unknown, generated_raw: unknown?): ({Entry}?, {Entry}?, string?, string?)
    local portable, artifact_digest, portable_error = desired(raw)
    if not portable or not artifact_digest then return nil, nil, nil, portable_error end
    local complete: {Entry} = table.create(#portable + (admission_raw == nil and 0 or 1), 0)
    for index, entry in ipairs(portable) do complete[index] = entry end
    if admission_raw ~= nil then
        local blob = bounds.object(admission_raw)
        if not blob or bounds.fields(blob, {"bytes", "digest"}) then
            return nil, nil, nil, "application admission blob is invalid"
        end
        local derived, derived_error = application_admission.entry(blob.bytes, blob.digest)
        if not derived then return nil, nil, nil, derived_error end
        complete[#complete + 1] = derived
    end
    if generated_raw ~= nil then
        local generated = bounds.object(generated_raw)
        local policies = generated and generated.policies
        local bindings = generated and generated.bindings
        local record = generated and bounds.object(generated.record) or nil
        if not generated or type(policies) ~= "table" or type(bindings) ~= "table"
            or not record or not capability_grants.reserved(record.id)
            or record.kind ~= "registry.entry" or #policies ~= #bindings or #policies > 8 then
            return nil, nil, nil, "generated capability entries are invalid"
        end
        local policy_ids: {[string]: boolean} = {}
        for _, raw_policy in ipairs(policies :: {unknown}) do
            local policy = bounds.object(raw_policy)
            local id = policy and bounds.id(policy.id) or nil
            if not id or not id:match("^bee%.governance%.grants:policy%.[0-9a-f]+$")
                or policy.kind ~= "security.policy" or policy_ids[id] then
                return nil, nil, nil, "generated capability policy is invalid"
            end
            policy_ids[id] = true
            complete[#complete + 1] = policy
        end
        local requirement_ids: {[string]: boolean} = {}
        for _, raw_binding in ipairs(bindings :: {unknown}) do
            local binding = bounds.object(raw_binding)
            local requirement_id = binding and bounds.id(binding.requirement_id) or nil
            local policy_id = binding and bounds.id(binding.policy_id) or nil
            if not requirement_id or not policy_id or not policy_ids[policy_id]
                or requirement_ids[requirement_id] then
                return nil, nil, nil, "generated requirement binding is invalid"
            end
            local found = false
            for index, entry in ipairs(complete) do
                if entry.id == requirement_id then
                    if entry.kind ~= "ns.requirement" then
                        return nil, nil, nil, "capability binding target is not a requirement"
                    end
                    local original = bounds.object(entry.data)
                    if not original or original.default ~= nil then
                        return nil, nil, nil, "capability requirement already has a default"
                    end
                    local next_data: Entry = {}
                    for key, value in pairs(original) do next_data[key] = value end
                    next_data.default = policy_id
                    local next_entry: Entry = {}
                    for key, value in pairs(entry) do next_entry[key] = value end
                    next_entry.data = next_data
                    complete[index] = next_entry
                    found = true
                    break
                end
            end
            if not found then return nil, nil, nil, "generated requirement is absent from artifact" end
            requirement_ids[requirement_id] = true
        end
        complete[#complete + 1] = record
    end
    return portable, complete, artifact_digest, nil
end

-- The injectable form keeps generation behavior testable without granting a
-- unit test registry authority. Production uses reconcile(), below.
local function reconcile_wanted_with(open: Open, conflict: Conflict, owner_raw: unknown,
    wanted: {Entry}, artifact_digest: string, portable_count: integer): ({[string]: unknown}?, string?)
    local owner = bounds.id(owner_raw)
    if not owner then return nil, "governance overlay owner is invalid" end
    local raw_snapshot, open_error = open(owner)
    if not raw_snapshot then return nil, tostring(open_error or "open governance overlay") end
    local snapshot = raw_snapshot :: Snapshot
    local changes, changed, stage_error = stage(snapshot, wanted)
    if not changes or changed == nil then return nil, stage_error end
    if not changed then
        return {owner = owner, artifact_digest = artifact_digest, entries = portable_count,
            overlay_entries = #wanted,
            changed = false, attempts = 1}, nil
    end
    local applied, apply_error = changes:apply()
    if applied then
        return {owner = owner, artifact_digest = artifact_digest, entries = portable_count,
            overlay_entries = #wanted,
            changed = true, attempts = 1}, nil
    end
    if conflict(apply_error) then return nil, "governance overlay changed during apply; preflight again" end
    return nil, tostring(apply_error or "apply governance overlay")
end

local function matches_wanted_with(open: Open, owner_raw: unknown, wanted: {Entry}): (boolean?, string?)
    local owner = bounds.id(owner_raw)
    if not owner then return nil, "governance overlay owner is invalid" end
    local raw_snapshot, open_error = open(owner)
    if not raw_snapshot then return nil, tostring(open_error or "open governance overlay") end
    return matches_snapshot(raw_snapshot :: Snapshot, wanted)
end

function M.reconcile_with(open: Open, conflict: Conflict, owner_raw: unknown, entries_raw: unknown): ({[string]: unknown}?, string?)
    local wanted, artifact_digest, artifact_error = desired(entries_raw)
    if not wanted or not artifact_digest then return nil, artifact_error end
    return reconcile_wanted_with(open, conflict, owner_raw, wanted, artifact_digest, #wanted)
end

function M.matches_with(open: Open, owner_raw: unknown, entries_raw: unknown): (boolean?, string?)
    local wanted, _, artifact_error = desired(entries_raw)
    if not wanted then return nil, artifact_error end
    return matches_wanted_with(open, owner_raw, wanted)
end

function M.reconcile_composed_with(open: Open, conflict: Conflict, owner_raw: unknown,
    entries_raw: unknown, admission_raw: unknown, generated_raw: unknown?): ({[string]: unknown}?, string?)
    local portable, complete, artifact_digest, compose_error = composed(entries_raw, admission_raw, generated_raw)
    if not portable or not complete or not artifact_digest then return nil, compose_error end
    return reconcile_wanted_with(open, conflict, owner_raw, complete, artifact_digest, #portable)
end

function M.matches_composed_with(open: Open, owner_raw: unknown, entries_raw: unknown,
    admission_raw: unknown, generated_raw: unknown?): (boolean?, string?)
    local _, complete, _, compose_error = composed(entries_raw, admission_raw, generated_raw)
    if not complete then return nil, compose_error end
    return matches_wanted_with(open, owner_raw, complete)
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

function M.reconcile_composed(owner: unknown, entries: unknown,
    admission_raw: unknown, generated_raw: unknown?): ({[string]: unknown}?, string?)
    return M.reconcile_composed_with(open, conflict, owner, entries, admission_raw, generated_raw)
end

function M.matches_composed(owner: unknown, entries: unknown,
    admission_raw: unknown, generated_raw: unknown?): (boolean?, string?)
    return M.matches_composed_with(open, owner, entries, admission_raw, generated_raw)
end

return M
