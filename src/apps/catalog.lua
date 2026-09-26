-- Read only protected bindings; app metadata cannot select its own permissions.
local registry = require("registry")
local system = require("system")
local contract = require("contract")
local application_admissions = require("application_admissions")
local M = {}
type Object = {[string]: unknown}
type Entry = {id: string, kind: string, meta: Object?, data: Object}
type Selection = {revision: string, evidence: string, bindings: {contract.Binding}, items: {contract.Descriptor}}

local function static_bindings(entry: Entry?): {contract.Binding}
    if not entry or entry.kind ~= "registry.entry" then error("Invalid application admission") end
    local data: unknown = entry.data
    if type(data) ~= "table" or type(data.bindings) ~= "table" then error("Invalid application admission") end
    local result: {contract.Binding} = {}
    local count = 0
    for key in pairs(data.bindings) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > 64 then error("Invalid admission array") end
        count = count + 1
    end
    local seen: {[string]: boolean} = {}
    for i = 1, count do
        local binding = contract.binding(data.bindings[i])
        if not binding or seen[binding.definition_id] then error("Invalid or duplicate admission binding") end
        seen[binding.definition_id] = true; result[#result + 1] = binding
    end
    return result
end

-- Command discovery has no workspace owner. Keep its historical surface
-- limited to shipped static admission; the broker uses read(workspace_id).
function M.bindings(pinned: registry.Snapshot?): {contract.Binding}
    local entry, entry_error
    if pinned then entry, entry_error = pinned:get("bee.security:application_admission")
    else entry, entry_error = registry.get("bee.security:application_admission") end
    if entry_error or not entry then error("Invalid application admission: " .. tostring(entry_error)) end
    return static_bindings(entry :: Entry)
end

local function descriptor(id: string, entries: {[string]: Entry}): contract.Descriptor?
    local entry = entries[id]
    if not entry or entry.kind ~= "process.lua" or type(entry.meta) ~= "table"
        or entry.meta.type ~= "bee.application" then return nil end
    return contract.descriptor(id, entry.meta.application)
end


function M.descriptor(id: string, pinned: registry.Snapshot?): contract.Descriptor?
    local entry, entry_error
    if pinned then entry, entry_error = pinned:get(id) else entry, entry_error = registry.get(id) end
    if entry_error or not entry then return nil end
    return descriptor(id, {[id] = entry :: Entry})
end

local function items(bindings: {contract.Binding}, pinned: registry.Snapshot): {contract.Descriptor}
    local result: {contract.Descriptor} = {}
    for _, binding in ipairs(bindings) do
        local item = M.descriptor(binding.definition_id, pinned)
        if item then result[#result + 1] = item end
    end
    table.sort(result, function(a, b)
        if a.group ~= b.group then return a.group < b.group end
        if a.title ~= b.title then return a.title < b.title end
        return a.definition_id < b.definition_id
    end)
    return result
end

local function record_bindings(raw: unknown): {contract.Binding}
    if type(raw) ~= "table" then error("Invalid protected application admission bindings") end
    local count = 0
    for key in pairs(raw :: table) do
        if type(key) ~= "number" or key ~= math.floor(key :: number)
            or (key :: number) < 1 or (key :: number) > 64 then
            error("Invalid protected application admission bindings")
        end
        count = count + 1
    end
    if count == 0 then error("Invalid protected application admission bindings") end
    local result: {contract.Binding} = {}
    local seen: {[string]: boolean} = {}
    for index = 1, count do
        local binding = contract.binding((raw :: table)[index])
        if not binding or seen[binding.definition_id] then
            error("Invalid or duplicate protected application admission binding")
        end
        seen[binding.definition_id] = true
        result[#result + 1] = binding
    end
    return result
end

-- Overlays change the effective catalog without advancing registry history.
-- Compare the bounded admission/presentation values captured in one snapshot;
-- source code and unrelated registry entries are not serialized here.
function M.read(workspace_id: string): Selection
    if not contract.workspace_id(workspace_id) then error("Invalid application catalog workspace") end
    local pinned = assert(registry.snapshot())
    local revision = pinned:version():string()
    local function lookup(id: string): Entry?
        local entry = pinned:get(id)
        return entry and entry :: Entry or nil
    end
    local node_id, node_error = system.node.id()
    if not node_id or node_error then error("Node identity is unavailable: " .. tostring(node_error)) end
    local published, publication_error = application_admissions.read(pinned, revision, workspace_id, node_id)
    if not published then error(tostring(publication_error)) end
    local bindings = static_bindings(lookup("bee.security:application_admission"))
    local seen: {[string]: boolean} = {}
    for _, binding in ipairs(bindings) do seen[binding.definition_id] = true end
    local evidence: {string} = {}
    local function consume(records: {application_admissions.Measurement}, packaged: boolean)
        for _, published_record in ipairs(records) do
            local record = published_record.record
            if record.schema_revision ~= "bee.governance-application-admission@1"
                or record.workspace_id ~= workspace_id
                or type(published_record.digest) ~= "string"
                or #published_record.digest ~= 64 or not published_record.digest:match("^[0-9a-f]+$") then
                error("Invalid protected application admission record")
            end
            local admitted = false
            for _, binding in ipairs(record_bindings(record.bindings)) do
                if packaged and seen[binding.definition_id] then
                    -- An explicitly delivered record for the same definition wins.
                else
                    if seen[binding.definition_id] then
                        error("Duplicate application admission binding: " .. binding.definition_id)
                    end
                    if #bindings >= 64 then error("Application admission capacity is exceeded") end
                    seen[binding.definition_id] = true
                    bindings[#bindings + 1] = binding
                    admitted = true
                end
            end
            if admitted then evidence[#evidence + 1] = published_record.digest end
        end
    end
    consume(published.governed, false)
    consume(published.packages, true)
    table.sort(bindings, function(left: contract.Binding, right: contract.Binding): boolean
        return left.definition_id < right.definition_id
    end)
    table.sort(evidence)
    return {revision = revision, evidence = table.concat(evidence, ":"), bindings = bindings,
        items = items(bindings, pinned)}
end
-- These are bounded, decoded records, not arbitrary registry data. Compare
-- values directly: JSON object field order is not a catalog revision.
function M.same(a: Selection, b: Selection): boolean
    if a.revision ~= b.revision or a.evidence ~= b.evidence
        or #a.bindings ~= #b.bindings or #a.items ~= #b.items then return false end
    for i, left in ipairs(a.bindings) do
        local right = b.bindings[i]
        if left.definition_id ~= right.definition_id or left.appearance_write ~= right.appearance_write
            or left.application_stop ~= right.application_stop
            or left.scope_management ~= right.scope_management or left.close_grace_ms ~= right.close_grace_ms
            or left.thread_access ~= right.thread_access
            or #left.policies ~= #right.policies then return false end
        for j, policy in ipairs(left.policies) do
            if policy ~= right.policies[j] then return false end
        end
    end
    for i, left in ipairs(a.items) do
        local right = b.items[i]
        if left.definition_id ~= right.definition_id or left.definition_revision ~= right.definition_revision
            or left.title ~= right.title or left.icon ~= right.icon or left.group ~= right.group
            or left.role ~= right.role or left.singleton ~= right.singleton
            or left.resume_schema ~= right.resume_schema or left.restart_policy ~= right.restart_policy then return false end
    end
    return true
end
-- Only an exact compatible automatic definition update may replace a running
-- application through recovery. Incompatible checkpoints stay live until the
-- person closes them; the catalog itself grants no destructive authority.
function M.replaces(running: contract.Descriptor, replacement: contract.Descriptor?): boolean
    return replacement ~= nil and running.restart_policy == "automatic"
        and replacement.restart_policy == "automatic"
        and replacement.resume_schema == running.resume_schema
        and replacement.definition_revision ~= running.definition_revision
end
return M
