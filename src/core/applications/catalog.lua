-- Read only protected bindings; app metadata cannot select its own permissions.
local registry = require("registry")
local contract = require("contract")
local activation_profiles = require("activation_profiles")
local governed_admission = require("governed_admission")
local M = {}
type Object = {[string]: unknown}
type Entry = {id: string, kind: string, meta: Object?, data: Object}
type Profile = {workspace_id: string, source_node: string, source_workspace: string,
    overlay_owner: string, applications: {Object}?}
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
    if pinned then entry, entry_error = pinned:get("bee:application_admission")
    else entry, entry_error = registry.get("bee:application_admission") end
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

local function same_binding(left: Object, right: Object): boolean
    if left.definition_id ~= right.definition_id or left.thread_access ~= right.thread_access then return false end
    local left_policies, right_policies = left.policies, right.policies
    if type(left_policies) ~= "table" or type(right_policies) ~= "table" or #left_policies ~= #right_policies then return false end
    for index, policy in ipairs(left_policies) do if policy ~= right_policies[index] then return false end end
    return true
end

local function matching_profile(record: Object, profiles: {Profile}): (Profile?, string?)
    local selected: Profile? = nil
    for _, profile in ipairs(profiles) do
        if profile.workspace_id == record.workspace_id and profile.overlay_owner == record.overlay_owner
            and profile.source_node == record.source_node and profile.source_workspace == record.source_workspace then
            if selected then return nil, "application admission profile is ambiguous" end
            selected = profile
        end
    end
    return selected, nil
end

type Lookup = (string) -> Entry?
local function governed(lookup: Lookup, configuration: {profiles: {Profile}}, workspace_id: string): ({contract.Binding}, {string})
    local by_owner: {[string]: {Profile}} = {}
    for _, profile in ipairs(configuration.profiles) do
        if profile.workspace_id == workspace_id and profile.applications and #profile.applications > 0 then
            local rows = by_owner[profile.overlay_owner]
            if not rows then rows = {}; by_owner[profile.overlay_owner] = rows end
            rows[#rows + 1] = profile
        end
    end
    local owners: {string} = {}
    for owner in pairs(by_owner) do owners[#owners + 1] = owner end
    table.sort(owners)
    local result: {contract.Binding} = {}
    local evidence: {string} = {}
    for _, owner in ipairs(owners) do
        local owner_profiles = by_owner[owner]
        if not owner_profiles then error("Application admission owner disappeared") end
        local admission_id, id_error = governed_admission.id(owner)
        if not admission_id then error(tostring(id_error)) end
        local entry = lookup(admission_id)
        if entry then
            if entry.kind ~= "registry.entry" then error("Invalid governed application admission") end
            local measured, measured_error = governed_admission.measure(entry.data)
            if not measured or measured.id ~= admission_id then
                error("Invalid governed application admission: " .. tostring(measured_error))
            end
            local record: Object = measured.record
            if record.workspace_id == workspace_id then
                local profile, profile_error = matching_profile(record, owner_profiles)
                if profile_error then error(profile_error) end
                if profile and profile.applications then
                    local artifacts: {Object} = {}
                    local policies: {Object} = {}
                    local policy_ids: {[string]: boolean} = {}
                    local complete = true
                    for _, binding in ipairs(profile.applications) do
                        local definition = lookup(binding.definition_id :: string)
                        if not definition then complete = false; break end
                        artifacts[#artifacts + 1] = definition
                        for _, policy_id in ipairs(binding.policies :: {string}) do policy_ids[policy_id] = true end
                    end
                    if complete then
                        for policy_id in pairs(policy_ids) do
                            local policy = lookup(policy_id)
                            if not policy then complete = false; break end
                            policies[#policies + 1] = policy
                        end
                    end
                    local projected = complete and governed_admission.project({workspace_id = profile.workspace_id,
                        overlay_owner = profile.overlay_owner, source_node = profile.source_node,
                        source_workspace = profile.source_workspace, artifact_digest = record.artifact_digest,
                        bindings = profile.applications, artifact_entries = artifacts,
                        registry_entries = policies, overlay_ids = {}}) or nil
                    if projected and projected.bytes == measured.bytes then
                        for index, raw in ipairs(profile.applications) do
                            if not same_binding(raw, measured.record.bindings[index] :: Object) then
                                error("Governed application admission binding order changed")
                            end
                            local binding = contract.binding(raw)
                            if not binding then error("Invalid governed application binding") end
                            result[#result + 1] = binding
                        end
                        evidence[#evidence + 1] = measured.digest
                    end
                end
            end
        end
    end
    return result, evidence
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
    local profile_entry = lookup("bee.governance:activation_profiles")
    if not profile_entry or profile_entry.kind ~= "registry.entry" then error("Invalid activation profiles") end
    local configuration, configuration_error = activation_profiles.decode(profile_entry.data)
    if not configuration then error("Invalid activation profiles: " .. tostring(configuration_error)) end
    local bindings = static_bindings(lookup("bee:application_admission"))
    local dynamic, evidence = governed(lookup, configuration :: {profiles: {Profile}}, workspace_id)
    local seen: {[string]: boolean} = {}
    for _, binding in ipairs(bindings) do seen[binding.definition_id] = true end
    for _, binding in ipairs(dynamic) do
        if seen[binding.definition_id] then error("Duplicate application admission binding: " .. binding.definition_id) end
        if #bindings >= governed_admission.MAX_BINDINGS then error("Application admission capacity is exceeded") end
        seen[binding.definition_id] = true
        bindings[#bindings + 1] = binding
    end
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
