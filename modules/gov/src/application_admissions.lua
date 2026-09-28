-- MIT. Select the protected application admission records for one workspace.
-- Governance owns activation selection and package grant projection; callers
-- receive the same measured record shape for both sources.
local registry = require("registry")
local logger = require("logger")
local activation_profiles = require("activation_profiles")
local capability_grants = require("capability_grants")
local capability_model = require("capability_model")
local workspace_applications = require("workspace_applications")
local governed_admission = require("governed_admission")

local M = {}
local log = logger:named("bee.gov.application_admission")
type Object = {[string]: unknown}
type Entry = {id: string, kind: string, meta: Object?, data: Object}
type Lookup = (string) -> Entry?
type Measurement = governed_admission.Measurement
type Selection = {governed: {Measurement}, packages: {Measurement}}
type PackageCache = {revision: string, workspace_id: string, node_id: string,
    admissions: {Measurement}, error: string?}

local package_cache: PackageCache? = nil

local function same_binding(left: Object, right: governed_admission.Binding): boolean
    if left.definition_id ~= right.definition_id or left.thread_access ~= right.thread_access then return false end
    if (left.appearance_write == true) ~= (right.appearance_write == true)
        or (left.application_stop == true) ~= (right.application_stop == true)
        or (left.scope_management == true) ~= (right.scope_management == true) then return false end
    local left_grace = left.close_grace_ms == nil and 250 or left.close_grace_ms
    local right_grace = right.close_grace_ms == nil and 250 or right.close_grace_ms
    if left_grace ~= right_grace then return false end
    local left_policies = left.policies
    if type(left_policies) ~= "table" or #left_policies ~= #right.policies then return false end
    for index, policy in ipairs(left_policies) do if policy ~= right.policies[index] then return false end end
    return true
end

-- A governed record joins the catalog only while the destination's selected
-- activation profile still projects the same measured artifacts and policies.
local function governed(pinned: registry.Snapshot, lookup: Lookup,
    configuration: activation_profiles.DecodedConfiguration, workspace_id: string,
    node_id: string): {Measurement}
    local records: {Measurement} = {}
    local by_owner: {[string]: Measurement} = {}
    for _, namespace in ipairs({governed_admission.NAMESPACE, "bee.governance"}) do
        for _, raw_entry in ipairs(pinned:find({[".kind"] = "registry.entry", [".ns"] = namespace})) do
            local entry = raw_entry :: Entry
            if governed_admission.reserved(entry.id) then
                local measured, measured_error = governed_admission.measure(entry.data)
                if not measured or (measured.id ~= entry.id
                    and governed_admission.prior_id(measured.record.overlay_owner) ~= entry.id) then
                    error("Invalid governed application admission: " .. tostring(measured_error))
                end
                if measured.record.workspace_id == workspace_id then
                    local prior = by_owner[measured.record.overlay_owner]
                    if prior and prior.digest ~= measured.digest then error("Conflicting governed application admissions") end
                    measured.id = entry.id
                    if not prior or namespace == governed_admission.NAMESPACE then
                        by_owner[measured.record.overlay_owner] = measured
                    end
                end
            end
        end
    end
    for _, item in pairs(by_owner) do records[#records + 1] = item end
    table.sort(records, function(left: Measurement, right: Measurement): boolean return left.id < right.id end)

    local result: {Measurement} = {}
    for _, item in ipairs(records) do
        local record = item.record
        local identity = workspace_applications.identity(workspace_id, record.source_workspace)
        local grant_id = identity and identity.overlay_owner == record.overlay_owner
            and capability_grants.record_id(record.overlay_owner) or nil
        local installed = grant_id and lookup(grant_id) or nil
        if not installed and identity and identity.overlay_owner == record.overlay_owner then
            local old_grant = capability_grants.prior_record_id(record.overlay_owner)
            installed = old_grant and lookup(old_grant) or nil
        end
        local application_id = identity and identity.definition_id or nil
        if not installed and not identity then
            local package_entry = configuration.packages
                and activation_profiles.find_package(configuration.packages, record.source_workspace) or nil
            local package_owner = package_entry
                and activation_profiles.package_owner(workspace_id, package_entry.component) or nil
            if package_entry and package_owner == record.overlay_owner then
                application_id = package_entry.definition_id
                local package_grant = capability_grants.record_id(package_owner)
                installed = package_grant and lookup(package_grant) or nil
            end
        end
        local vocabulary: capability_model.Vocabulary? = nil
        if installed then
            vocabulary = capability_model.decode(lookup("bee:capability_catalog"))
            local grant = vocabulary and application_id and capability_grants.decode(installed,
                record.overlay_owner, workspace_id, application_id, vocabulary) or nil
            local live = grant and capability_grants.live(grant, lookup) or false
            if not live then installed = nil; vocabulary = nil end
        end
        local profile, profile_error = activation_profiles.select_decoded(configuration,
            workspace_id, record.source_node, record.source_workspace, node_id,
            installed, vocabulary, record.overlay_owner)
        local omission: string? = nil
        if not profile then
            omission = tostring(profile_error or "no activation profile selected")
        elseif profile.overlay_owner ~= record.overlay_owner then
            omission = "selected activation profile belongs to another overlay owner"
        elseif not profile.applications then
            omission = "selected activation profile admits no applications"
        else
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
            if projected and projected.bytes == item.bytes then
                for index, raw in ipairs(profile.applications) do
                    local measured_binding = record.bindings[index]
                    if not measured_binding or not same_binding(raw, measured_binding) then
                        error("Governed application admission binding order changed")
                    end
                end
                result[#result + 1] = item
            elseif not complete then
                omission = "an admitted application definition or policy is missing"
            elseif not projected then
                omission = "the selected activation profile could not be measured"
            else
                omission = "the selected activation profile does not match the applied admission"
            end
        end
        if omission then
            log:warn("Governed application admission omitted", {workspace_id = workspace_id,
                source_workspace = record.source_workspace, source_node = record.source_node,
                destination_node = node_id, reason = omission})
        end
    end
    return result
end

local function packaged(revision: string, configuration: activation_profiles.DecodedConfiguration,
    workspace_id: string, node_id: string, lookup: Lookup): ({Measurement}?, string?)
    local cached = package_cache
    if not cached or cached.revision ~= revision or cached.workspace_id ~= workspace_id
        or cached.node_id ~= node_id then
        local admissions, error_message = activation_profiles.package_admissions(configuration,
            workspace_id, node_id, function(id: string): unknown return lookup(id) end)
        cached = {revision = revision, workspace_id = workspace_id, node_id = node_id,
            admissions = admissions or {}, error = error_message}
        package_cache = cached
    end
    if cached.error then return nil, cached.error end
    return cached.admissions, nil
end

-- Package projection is memoized by the same registry revision, workspace and
-- node tuple as the catalog read it replaces.
function M.read(pinned: registry.Snapshot, revision: string, workspace_id: string,
    node_id: string): (Selection?, string?)
    local function lookup(id: string): Entry?
        local entry = pinned:get(id)
        return entry and entry :: Entry or nil
    end
    local profile_entry = lookup("bee.env:gov_activation_profiles")
    if not profile_entry or profile_entry.kind ~= "registry.entry" then return nil, "Invalid activation profiles" end
    local configuration, configuration_error = activation_profiles.decode(profile_entry.data)
    if not configuration then return nil, "Invalid activation profiles: " .. tostring(configuration_error) end
    local governed_records = governed(pinned, lookup, configuration, workspace_id, node_id)
    local package_records, package_error = packaged(revision, configuration, workspace_id, node_id, lookup)
    if not package_records then
        return nil, "Invalid package application admission: " .. tostring(package_error)
    end
    return {governed = governed_records, packages = package_records}, nil
end

return M
