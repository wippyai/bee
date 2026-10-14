-- MIT. Host proposal and policy projection for application capabilities.
local bounds = require("bounds")
local hash = require("hash")
local canonical = require("canonical")
local workspace_applications = require("workspace_applications")
local capability_model = require("capability_model")
local capability_grants = require("capability_grants")
local capability_files = require("capability_files")
local preflight = require("preflight")
local M = {}
type Object = {[string]: unknown}
type Entry = Object
type DatabaseBinding = {database_id: string, table_prefix: string?}
type DatabaseBindings = {[string]: DatabaseBinding}
type Policy = {node_id: string, policy_digest: string, packages: {[string]: boolean},
    namespaces: {[string]: boolean}, kinds: {[string]: boolean}, databases: {[string]: boolean},
    grants: {[string]: boolean}, modules: {[string]: boolean}, applied: {[string]: preflight.Migration},
    applied_databases: {[string]: preflight.DatabaseEvidence}?, database_bindings: DatabaseBindings?, migration_barrier: boolean,
    auto_start: boolean?, super_edit: boolean?,
    applications: {Object}?, workspace_id: string?, overlay_owner: string?, source_node: string?, source_workspace: string?,
    workspace_application: boolean?, base_policy_digest: string?, generated_databases: {Object}?}
-- folder resolves the destination workspace folder file grants are rooted in;
-- it is consulted only when the plan requests workspace files.

type Result = {policy: Policy, proposal: capability_grants.Proposal?, installed: capability_grants.Installed?,
    review: capability_grants.Review?, module_capabilities: {[string]: {string}}?}
local function object(value: unknown): Object?
    return bounds.object(value)
end
local function sha(value: unknown): string?
    if type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-f]+$") then return nil end
    return value
end
function M.prepare(policy: Policy, spec: Object, incoming: {Entry}, requirements: {preflight.Requirement},
    current_raw: {[string]: Entry}, folder_fn: (() -> (unknown?, string?))?): (Result?, string?)
    local original_policy = policy
    local database_bindings = policy.database_bindings
    local capability_proposal: capability_grants.Proposal? = nil
    local capability_installed: capability_grants.Installed? = nil
    local capability_review: capability_grants.Review? = nil
    local module_capabilities: {[string]: {string}}? = nil
    if policy.workspace_application then
        local app_binding = policy.applications and object(policy.applications[1]) or nil
        local app_id, application_error = workspace_applications.application(incoming)
        if not app_id then return nil, application_error end
        if app_binding then app_binding.definition_id = app_id end
        if not app_binding then return nil, "application capability binding is absent" end
        local owner = bounds.id(policy.overlay_owner)
        local catalog_entry = current_raw["bee.capability:catalog"]
        local vocabulary, catalog_error = capability_model.decode(catalog_entry)
        if not app_id or not owner or not vocabulary or not sha(policy.base_policy_digest) then
            return nil, catalog_error or "workspace application capability profile is invalid"
        end
        local model_vocabulary = vocabulary
        local requested: {Object} = {}
        for _, item in ipairs(requirements) do
            if item.capability_request then requested[#requested + 1] = item end
        end
        local folder: unknown = nil
        if capability_files.rooted(requested) then
            local resolve_folder = folder_fn
            if not resolve_folder then return nil, "workspace folder is unavailable for a file grant" end
            local resolved_folder, folder_error = resolve_folder()
            if not resolved_folder then return nil, folder_error or "workspace folder is unavailable" end
            folder = resolved_folder
        end
        local proposed, proposed_error = capability_grants.propose(model_vocabulary, owner, app_id, requested, nil, folder)
        if not proposed then return nil, proposed_error end
        capability_proposal = proposed
        local record_id = capability_grants.record_id(owner)
        local prior = record_id and current_raw[record_id] or nil
        if not prior then
            local old_id = capability_grants.prior_record_id(owner)
            prior = old_id and current_raw[old_id] or nil
        end
        if prior then
            local decoded, decoded_error = capability_grants.decode(prior, owner, spec.workspace_id,
                app_id, model_vocabulary)
            if not decoded then return nil, decoded_error end
            capability_installed = decoded
        end
        local compared, compare_error = capability_grants.diff(model_vocabulary, capability_installed, proposed)
        if not compared then return nil, compare_error end
        capability_review = {added = compared.added, widened = compared.widened,
            narrowed = compared.narrowed, removed = compared.removed, changed = compared.changed,
            requires_approval = compared.requires_approval or prior == nil, revocation = compared.revocation,
            lines = compared.lines, resolved = compared.resolved, delta = compared.delta}
        local selected_policies: {unknown} = table.create(16, 0)
        for _, raw_id in ipairs(app_binding.policies) do
            if not capability_grants.reserved(raw_id) then selected_policies[#selected_policies + 1] = raw_id end
        end
        for grant_id in pairs(policy.grants) do
            if capability_grants.reserved(grant_id) then policy.grants[grant_id] = nil end
        end
        for _, generated in ipairs(proposed.policies) do
            local generated_id = generated.id
            selected_policies[#selected_policies + 1] = generated_id
            policy.grants[generated_id] = true
        end
        -- Database grants bind logical migration targets to host-provisioned stores.
        local generated_databases: {Object} = {}
        for _, raw_grant in ipairs(proposed.capabilities) do
            local grant = object(raw_grant)
            local scope = grant and object(grant.scope) or nil
            local target: string? = nil
            if grant and scope and grant.capability == "app.database" then
                target = bounds.id(scope.name)
            end
            if target then
                local database_id, database_error = capability_files.database_id(owner, target)
                if not database_id then return nil, database_error end
                policy.databases[target] = true
                local bindings = database_bindings
                if not bindings then
                    bindings = {}
                    database_bindings = bindings
                end
                bindings[target] = {database_id = database_id}
                generated_databases[#generated_databases + 1] = {database_id = database_id,
                    target_db = target}
            end
        end
        -- Requested capabilities admit their catalog-declared runtime modules.
        local admitted_modules: {[string]: boolean} = {}
        for name, allowed in pairs(original_policy.modules) do admitted_modules[name] = allowed end
        for name in pairs(capability_model.modules(model_vocabulary, proposed.capabilities)) do
            admitted_modules[name] = true
        end
        module_capabilities = capability_model.module_capabilities(model_vocabulary)
        local source_binding = app_binding
        local prospective_binding: Object = {definition_id = app_id,
            policies = selected_policies, thread_access = proposed.thread_access,
            appearance_write = source_binding.appearance_write == true,
            application_stop = source_binding.application_stop == true,
            scope_management = source_binding.scope_management == true,
            close_grace_ms = source_binding.close_grace_ms == nil and 250
                or source_binding.close_grace_ms}
        local applications: {Object} = {prospective_binding}
        local prospective_bytes = canonical.encode({base_policy_digest = policy.base_policy_digest,
            capability_digest = proposed.digest, database_bindings = database_bindings or {}})
        local prospective_digest = prospective_bytes and hash.sha256(prospective_bytes) or nil
        if not prospective_digest then return nil, "measure prospective capability policy" end
        policy = {node_id = original_policy.node_id, policy_digest = prospective_digest,
            packages = original_policy.packages, namespaces = original_policy.namespaces, kinds = original_policy.kinds,
            databases = original_policy.databases, grants = original_policy.grants, modules = admitted_modules,
            applied = original_policy.applied, applied_databases = original_policy.applied_databases,
            database_bindings = database_bindings, migration_barrier = original_policy.migration_barrier,
            auto_start = original_policy.auto_start, super_edit = original_policy.super_edit, applications = applications, workspace_id = original_policy.workspace_id,
            overlay_owner = original_policy.overlay_owner, source_node = original_policy.source_node,
            source_workspace = original_policy.source_workspace, workspace_application = original_policy.workspace_application,
            base_policy_digest = original_policy.base_policy_digest, generated_databases = generated_databases}
    end
    return {policy = policy, proposal = capability_proposal, installed = capability_installed,
        review = capability_review, module_capabilities = module_capabilities}, nil
end
function M.evidence(value: Result): preflight.CapabilityEvidence
    if not value.proposal or not value.review then return {kind = "absent"} end
    if value.installed then
        return {kind = "installed", proposal = value.proposal, review = value.review, installed = value.installed}
    end
    return {kind = "new", proposal = value.proposal, review = value.review}
end
return M
