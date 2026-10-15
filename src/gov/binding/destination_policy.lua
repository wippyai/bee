-- MIT. Destination policy selection, resolver composition and admitted drivers.
local registry = require("registry")
local security = require("security")
local time = require("time")
local system = require("system")
local funcs = require("funcs")
local bounds = require("bounds")
local resources = require("resources")
local plans = require("plan_store")
local activations = require("activation_store")
local leases = require("lease_store")
local owner = require("activation_owner")
local resolver = require("hub_resolver")
local package_requirements = require("package_requirements")
local overlay_resolver = require("overlay_resolver")
local preflight = require("preflight")
local materializer = require("materializer")
local artifact = require("artifact")
local driver_admission = require("driver_admission")
local migration_effect = require("migration_effect")
local migration_runner = require("migration_runner")
local activation_profiles = require("activation_profiles")
local capability_grants = require("capability_grants")
local capability_model = require("capability_model")
local capability_files = require("capability_files")
local workspace_applications = require("workspace_applications")

local M = {}
local ACTOR = "bee.gov.activation"
type Object = {[string]: unknown}
type Set = {[string]: boolean}
type DatabaseBinding = {database_id: string, table_prefix: string?}
type DatabaseBindings = {[string]: DatabaseBinding}
type PolicyIds = {string}
type Profile = {workspace_id: string, source_node: string, source_workspace: string,
    component: string, overlay_owner: string, approval_policy: string, resolver: string, parameters: {unknown},
    packages: Set, namespaces: Set, kinds: Set, databases: Set, grants: Set, modules: Set,
    database_bindings: DatabaseBindings?, migration_policies: PolicyIds?, applications: {Object}?,
    auto_start: boolean, super_edit: boolean, expires_at: string, policy_digest: string}
type Configuration = activation_profiles.Configuration
type ResolverRoot = {component: string, version: string, parameters: {unknown}}
type ResolverPolicy = {node_id: string, policy_digest: string, packages: Set,
    namespaces: Set, kinds: Set, databases: Set, grants: Set, modules: Set,
    database_bindings: DatabaseBindings?, applied: {[string]: preflight.Migration},
    applied_databases: {[string]: preflight.DatabaseEvidence},
    migration_barrier: boolean, auto_start: boolean, super_edit: boolean, applications: {Object}?, workspace_id: string?, overlay_owner: string?,
    source_node: string?, source_workspace: string?, workspace_application: boolean?,
    base_policy_digest: string?}
type OwnerConfigResult = {ok: true, config: owner.Config} | {ok: false, error: string}

local function migration_database_owner(value: unknown): string?
    if type(value) ~= "string" or #value > 160 or value:find("%c") then return nil end
    return value
end

local function applied_database_evidence(raw: unknown): ({[string]: preflight.DatabaseEvidence}?, string?)
    local historical = bounds.object(raw)
    if not historical then return nil, "stored applied migration database evidence is malformed" end
    local result: {[string]: preflight.DatabaseEvidence} = {}
    for target_key, raw_database in pairs(historical) do
        local captured = bounds.object(raw_database)
        local target = bounds.id(target_key)
        local database_id = captured and bounds.id(captured.database_id) or nil
        local kind = captured and bounds.id(captured.kind) or nil
        local package = captured and migration_database_owner(captured.package) or nil
        local digest = captured and bounds.text(captured.digest, 64) or nil
        local table_prefix: string? = nil
        if captured and captured.table_prefix ~= nil then
            table_prefix = bounds.text(captured.table_prefix, 64)
            if not table_prefix or not table_prefix:match("^[A-Za-z][A-Za-z0-9_]*$") then
                return nil, "stored applied migration table prefix is malformed"
            end
        end
        if not target or not captured or captured.target_db ~= target then
            return nil, "stored applied migration database target is malformed"
        end
        if not database_id or not kind or not package then
            return nil, "stored applied migration database identity is malformed"
        end
        if not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then
            return nil, "stored applied migration database digest is malformed"
        end
        if type(captured.planned) ~= "boolean" then
            return nil, "stored applied migration planned-state evidence is malformed"
        end
        result[target] = {database_id = database_id, table_prefix = table_prefix,
            kind = kind, package = package, digest = digest}
    end
    return result, nil
end

function M.configuration(raw: unknown, node_raw: unknown): (Configuration?, string?)
    return activation_profiles.configuration(raw, node_raw)
end

local function load(): (Configuration?, string?)
    local node_id, node_error = system.node.id()
    if not node_id or node_error then return nil, "native node identity is unavailable" end
    local entry, entry_error = resources.activation_profiles()
    if not entry then return nil, tostring(entry_error or "activation profiles are unavailable") end
    local data = bounds.object(entry.data)
    if not data then return nil, "activation profiles are malformed" end
    return M.configuration(data, node_id)
end

-- The dedicated approver policy a super-edit row must name: it must exist,
-- list its approvers, and demand an explicit confirmation. The name is the
-- host's declaration of a person-confirmed, node-local decision; a policy
-- missing here or carrying any other confirmation is refused.
local function super_edit_approver_policy(name: string): (boolean, string?)
    local entry = registry.get("bee.security.approvals:approver_policies")
    local data = entry and bounds.object(entry.data) or nil
    local listed = data and data.policies or nil
    if type(listed) ~= "table" then return false, "approver policies are unavailable" end
    for _, raw in ipairs(listed) do
        local policy = bounds.object(raw)
        local declared = policy and bounds.id(policy.name) or nil
        if declared == name then
            local approvers = policy and policy.approvers or nil
            if type(approvers) ~= "table" or #(approvers) == 0 then
                return false, "super-edit approver policy " .. name .. " names no approvers"
            end
            if policy.confirm ~= "explicit" then
                return false, "super-edit approver policy " .. name .. " must confirm explicitly"
            end
            return true, nil
        end
    end
    return false, "super-edit approver policy " .. name .. " is not configured on this host"
end

-- A super-edit row is admitted only while unexpired and naming the dedicated
-- explicit-confirmation approver policy. The decoder already refused a row
-- that could grant security authority or start itself.
local FORMAT = "2006-01-02T15:04:05.000Z07:00"
function M.super_edit_admission(raw: unknown): (boolean, string?)
    local profile_value = bounds.object(raw)
    if not profile_value then return false, "super-edit admission needs a measured profile" end
    if profile_value.super_edit ~= true then return true, nil end
    local expires_at = bounds.text(profile_value.expires_at, 40)
    local approval_policy = bounds.id(profile_value.approval_policy)
    if not expires_at or not approval_policy then
        return false, "super-edit activation profile is malformed"
    end
    local expires = time.parse(FORMAT, expires_at)
    if not expires then return false, "super-edit activation profile has an invalid expiry" end
    if not expires:after(time.now()) then
        return false, "super-edit activation profile expired at " .. expires_at
    end
    if not approval_policy:match("^super%-edit") then
        return false, "a super-edit activation profile must name a super-edit approver policy"
    end
    return super_edit_approver_policy(approval_policy)
end

local function selected(config: Configuration, workspace_id: string, source_node: string,
    source_workspace: string, activation_store: activations.Store?): (Profile?, string?)
    local installed: unknown = nil
    local vocabulary: unknown = nil
    local owner_hint: string? = nil
    local slot_source: string? = nil
    local workspace_identity = activation_profiles.hub_identity(workspace_id, source_workspace)
        or workspace_applications.identity(workspace_id, source_workspace)
    local prior_owner = workspace_applications.prior_owner(workspace_id, source_workspace)
    if prior_owner then
        local prior_id = capability_grants.prior_record_id(prior_owner)
        if (prior_id and registry.get(prior_id)) then owner_hint = prior_owner end
        if activation_store then
            local desired = activations.desired(activation_store, prior_owner)
            if desired.ok then owner_hint = prior_owner
            elseif desired.code ~= "NOT_FOUND" then return nil, desired.message end
        end
    end
    local owner = owner_hint or (workspace_identity and workspace_identity.overlay_owner)
    if owner and activation_store then
        local desired = activations.desired(activation_store, owner)
        if desired.ok then
            local held = bounds.object(desired.value)
            slot_source = held and bounds.id(held.source_node) or nil
            if not slot_source then return nil, "desired activation source is malformed" end
        elseif desired.code ~= "NOT_FOUND" then return nil, desired.message end
    end
    local id = owner and (owner_hint and capability_grants.prior_record_id(owner)
        or capability_grants.record_id(owner)) or nil
    if id then
        installed = registry.get(id)
        if installed then
            local raw_catalog = registry.get("bee.capability:catalog")
            local decoded, catalog_error = capability_model.decode(raw_catalog)
            if not decoded then return nil, catalog_error end
            vocabulary = decoded
            local record, record_error = capability_grants.decode(installed, owner,
                workspace_id, (bounds.object(installed) and bounds.object((bounds.object(installed)).data) or {}).application, decoded)
            if not record then return nil, record_error end
            local live, live_error = capability_grants.live(record,
                function(entry_id: string): unknown return registry.get(entry_id) end)
            if not live then return nil, live_error end
        end
        if installed == nil and workspace_identity == nil and config.packages then
            local entry = activation_profiles.find_package(config.packages, source_workspace)
            if entry then
                local package_owner = activation_profiles.package_owner(workspace_id, entry.component)
                local package_id = package_owner and capability_grants.record_id(package_owner) or nil
                local package_installed = package_id and registry.get(package_id) or nil
                if package_installed then
                    local raw_catalog = registry.get("bee.capability:catalog")
                    local decoded, catalog_error = capability_model.decode(raw_catalog)
                    if not decoded then return nil, catalog_error end
                    vocabulary = decoded
                    local record, record_error = capability_grants.decode(package_installed,
                        package_owner, workspace_id, entry.definition_id, decoded)
                    if not record then return nil, record_error end
                    local live, live_error = capability_grants.live(record,
                        function(entry_id: string): unknown return registry.get(entry_id) end)
                    if not live then return nil, live_error end
                    installed = package_installed
                end
            end
        end
    end
    local profile_value, profile_error = activation_profiles.select(config, workspace_id, source_node,
        source_workspace, installed, vocabulary, owner_hint, slot_source)
    if not profile_value then return nil, profile_error end
    local admitted, admission_error = M.super_edit_admission(profile_value)
    if not admitted then return nil, admission_error end
    return profile_value, nil
end

local function migration_binding(profile_value: Profile, target: string): (DatabaseBinding?, string?)
    if profile_value.database_bindings == nil then return nil, nil end
    local binding = profile_value.database_bindings[target]
    if not binding then return nil, "activation profile has no database binding for " .. target end
    return binding, nil
end

local function approval_executor(): (owner.Executor?, string?)
    local request_id, request_ref_error = resources.approval_request_policy()
    local consume_id, consume_ref_error = resources.approval_consume_policy()
    if not request_id or not consume_id then return nil, tostring(request_ref_error or consume_ref_error or "approval policies are unavailable") end
    local request, request_error = security.policy(request_id)
    local consume, consume_error = security.policy(consume_id)
    if not request or not consume then return nil, tostring(request_error or consume_error or "load approval policies") end
    local caller = funcs.new():with_actor(security.new_actor(ACTOR)):with_scope(security.new_scope({request, consume}))
    local executor: owner.Executor = {call = function(_self: owner.Executor, target: string, input: unknown): (unknown?, unknown?)
        local result, problem = caller:call(target, input)
        local value = bounds.object(result)
        return value, problem and tostring(problem) or nil
    end}
    return executor, nil
end

local function destination_resolver(config: Configuration, profile_value: Profile, node_id: string, workspace_id: string,
    activation_store: activations.Store?): unknown
    local function selected_root(spec_raw: unknown, verified_entries: unknown?): (ResolverRoot?, string?)
        local spec = bounds.object(spec_raw)
        if not spec or spec.owner_node ~= node_id or spec.workspace_id ~= workspace_id
            or spec.source_node ~= profile_value.source_node or spec.source_workspace ~= profile_value.source_workspace
            or not bounds.id(spec.version) then return nil, "selected plan does not match its activation profile" end
        local version = bounds.id(spec.version)
        if not version then return nil, "selected plan version is invalid" end
        if spec.source_workspace == "hub:" .. profile_value.component then
            local frozen = verified_entries
            if frozen == nil then
                local decoded, problem = artifact.decode(spec.artifact_bytes, spec.artifact_digest)
                if not decoded then return nil, problem end
                frozen = decoded
            end
            local parameters, invalid = package_requirements.frozen_parameters(frozen)
            if not parameters then return nil, invalid end
            local rows: {unknown} = {}
            for _, parameter in ipairs(parameters) do rows[#rows + 1] = parameter end
            return {component = profile_value.component, version = version, parameters = rows}, nil
        end
        return {component = profile_value.component, version = version, parameters = profile_value.parameters}, nil
    end
    local function selected_policy(spec_raw: unknown, _captured: unknown, _preview: unknown): (ResolverPolicy?, string?)
        local admitted, admission_error = M.super_edit_admission(profile_value)
        if not admitted then return nil, admission_error end
        local spec = bounds.object(spec_raw)
        if not spec or spec.owner_node ~= node_id then return nil, "activation policy belongs to another node" end
        local identity = activation_profiles.hub_identity(profile_value.workspace_id, profile_value.source_workspace)
        or workspace_applications.identity(profile_value.workspace_id, profile_value.source_workspace)
        local base_policy_digest: string? = nil
        if identity and identity.component == profile_value.component
            and (identity.overlay_owner == profile_value.overlay_owner
                or workspace_applications.prior_owner(profile_value.workspace_id,
                    profile_value.source_workspace) == profile_value.overlay_owner) then
            local base, base_error = activation_profiles.select(config, profile_value.workspace_id,
                profile_value.source_node, profile_value.source_workspace, nil, nil, profile_value.overlay_owner)
            if not base then return nil, base_error end
            base_policy_digest = base.policy_digest
        end
        local applied: {[string]: preflight.Migration} = {}
        local applied_databases: {[string]: preflight.DatabaseEvidence} = {}
        if activation_store then
            local known = activations.applied(activation_store, profile_value.component)
            if not known.ok then return nil, tostring(known.message or "read applied migration facts") end
            local evidence = bounds.object(known.value)
            local historical_migrations = evidence and bounds.object(evidence.migrations) or nil
            local historical_databases = evidence and bounds.object(evidence.databases) or nil
            if not evidence or not historical_migrations or not historical_databases then
                return nil, "stored applied migration evidence is malformed"
            end
            for key, raw in pairs(historical_migrations) do
                local item = bounds.object(raw)
                local target = item and bounds.id(item.target_db) or nil
                local migration_id = item and bounds.id(item.id) or nil
                local checksum = item and bounds.text(item.checksum, 64) or nil
                local ordinal = item and bounds.count(item.ordinal) or nil
                if type(key) ~= "string" or not target or not migration_id or key ~= target .. "\n" .. migration_id
                    or not checksum or #checksum ~= 64 or not checksum:match("^[0-9a-f]+$")
                    or ordinal == nil then return nil, "stored applied migration fact is malformed" end
                applied[key] = {id = migration_id, target_db = target, checksum = checksum, ordinal = ordinal}
            end
            local decoded_databases, database_error = applied_database_evidence(historical_databases)
            if not decoded_databases then return nil, database_error end
            applied_databases = decoded_databases
            for _, fact in pairs(applied) do
                local captured = applied_databases[fact.target_db]
                if not captured then return nil, "stored applied migration has no database evidence" end
                local binding, binding_error = migration_binding(profile_value, fact.target_db)
                if binding_error then return nil, binding_error end
                -- An application database the grant provisions is bound
                -- by its host-derived identity, as the resolver binds it.
                local provisioned = capability_files.database_id(profile_value.overlay_owner, fact.target_db)
                local current_database = binding and binding.database_id
                    or (captured.database_id == provisioned and provisioned) or fact.target_db
                local current_prefix = binding and binding.table_prefix or nil
                if captured.database_id ~= current_database or captured.table_prefix ~= current_prefix then
                    return nil, "activation profile changes an applied migration database binding: " .. fact.target_db
                end
                local frozen = {database_id = captured.database_id,
                    table_prefix = captured.table_prefix}
                local present, ledger_error = migration_runner.is_applied(fact.target_db, fact.id, frozen)
                if present == nil then return nil, tostring(ledger_error or "read target migration ledger") end
                if not present then return nil, "target migration ledger differs from Governance facts: " .. fact.id end
            end
        end
        return {node_id = node_id, policy_digest = profile_value.policy_digest,
            packages = profile_value.packages, namespaces = profile_value.namespaces, kinds = profile_value.kinds,
            databases = profile_value.databases, grants = profile_value.grants, modules = profile_value.modules,
            database_bindings = profile_value.database_bindings,
            applications = profile_value.applications, workspace_id = profile_value.workspace_id,
            overlay_owner = profile_value.overlay_owner, source_node = profile_value.source_node,
            source_workspace = profile_value.source_workspace,
            workspace_application = base_policy_digest ~= nil,
            base_policy_digest = base_policy_digest,
            applied = applied, applied_databases = applied_databases, migration_barrier = true,
            auto_start = profile_value.auto_start, super_edit = profile_value.super_edit}, nil
    end
    if profile_value.resolver == "overlay" then
        return overlay_resolver.new({overlay_owner = profile_value.overlay_owner,
            root = function(spec_raw: unknown): (overlay_resolver.Root?, string?)
                local root, root_error = selected_root(spec_raw)
                if not root then return nil, root_error end
                return {component = root.component, version = root.version}, nil
            end, policy = selected_policy,
            folder = function(): (unknown?, string?) return resources.workspace_folder(workspace_id) end})
    end
    return resolver.new({overlay_owner = profile_value.overlay_owner,
        root = selected_root, policy = selected_policy,
        folder = function(): (unknown?, string?) return resources.workspace_folder(workspace_id) end})
end

local function generated_install(profile_value: Profile, intent_raw: unknown): (Object?, string?)
    local identity = activation_profiles.hub_identity(profile_value.workspace_id, profile_value.source_workspace)
        or workspace_applications.identity(profile_value.workspace_id, profile_value.source_workspace)
    local prior_owner = workspace_applications.prior_owner(profile_value.workspace_id, profile_value.source_workspace)
    local uses_prior = prior_owner ~= nil and prior_owner == profile_value.overlay_owner
    if not identity or (identity.overlay_owner ~= profile_value.overlay_owner and not uses_prior)
        or identity.component ~= profile_value.component then return nil, nil end
    local intent = bounds.object(intent_raw)
    if not intent or intent.overlay_owner ~= profile_value.overlay_owner
        or intent.workspace_id ~= profile_value.workspace_id
        or not bounds.id(intent.approval_id) or not bounds.id(intent.version) then
        return nil, "capability activation identity is invalid"
    end
    local candidate, candidate_error = preflight.decode_candidate(intent.resolution_bytes,
        intent.resolution_digest)
    if not candidate then return nil, candidate_error end
    local catalog_entry, catalog_lookup_error = registry.get("bee.capability:catalog")
    if not catalog_entry then return nil, "host capability catalog lookup failed: " .. tostring(catalog_lookup_error) end
    local vocabulary, catalog_error = capability_model.decode(catalog_entry)
    if not vocabulary then return nil, catalog_error end
    local requested: {Object} = {}
    for _, requirement in ipairs(candidate.requirements) do
        if requirement.capability_request then requested[#requested + 1] = requirement end
    end
    local folder: unknown = nil
    if capability_files.rooted(requested) then
        local resolved, folder_error = resources.workspace_folder(profile_value.workspace_id)
        if not resolved then return nil, folder_error end
        folder = resolved
    end
    local artifact_entries, artifact_error = artifact.decode(intent.artifact_bytes, intent.artifact_digest)
    if not artifact_entries then return nil, artifact_error end
    local application_id, application_error = workspace_applications.application(artifact_entries)
    if not application_id then return nil, application_error end
    local proposed, proposed_error = capability_grants.propose(vocabulary, profile_value.overlay_owner,
        application_id, requested, uses_prior, folder)
    if not proposed then return nil, proposed_error end
    local record_id = uses_prior and capability_grants.prior_record_id(profile_value.overlay_owner)
        or capability_grants.record_id(profile_value.overlay_owner)
    local prior_raw = record_id and registry.get(record_id) or nil
    local prior: Object? = nil
    if prior_raw then
        local decoded, decoded_error = capability_grants.decode(prior_raw, profile_value.overlay_owner,
            profile_value.workspace_id, application_id, vocabulary)
        if not decoded then return nil, decoded_error end
        local live, live_error = capability_grants.live(decoded,
            function(id: string): unknown return registry.get(id) end)
        if not live then return nil, live_error end
        prior = decoded
    end
    local approval_id = bounds.id(intent.approval_id)
    local revision: integer = 1
    local installed_same = prior and prior.artifact_digest == intent.artifact_digest
        and prior.version == intent.version
    if installed_same then
        if prior.digest ~= proposed.digest or prior.approval_id ~= approval_id then
            return nil, "installed grant differs from the activated intent"
        end
        revision = prior.revision
    -- A settled, applied intent carries the grant the person approved for its
    -- exact version; restoring it, after the overlay was lost or when the
    -- person goes back to it, installs that grant again over whatever replaced it.
    elseif not (intent.phase == "settled" and intent.outcome == "applied"
        and intent.application_admission_digest ~= nil) then
        if (prior and prior.record_digest or nil) ~= intent.grant_predecessor_digest then
            return nil, "installed grant changed since permission review"
        end
        local compared, compare_error = capability_grants.diff(vocabulary, prior, proposed)
        if not compared then return nil, compare_error end
        -- A contained upgrade either reuses the installed grant exactly or,
        -- when the person approved it afresh, as for a version that runs
        -- migrations, carries that approval.
        if prior and not compared.requires_approval then
            if intent.grant_reuse_digest ~= nil and (intent.grant_reuse_digest ~= prior.record_digest
                or approval_id ~= prior.approval_id) then
                return nil, "contained upgrade has no matching installed grant reuse"
            end
        elseif intent.grant_reuse_digest ~= nil then
            return nil, "widening cannot reuse an installed grant"
        end
        if prior then revision = (prior.revision) + 1 end
    end
    local record, record_error = capability_grants.record(profile_value.overlay_owner,
        profile_value.workspace_id, application_id, proposed, approval_id, revision,
        intent.artifact_digest, intent.version, uses_prior)
    if not record then return nil, record_error end
    return {policies = proposed.policies, bindings = proposed.bindings, record = record,
        volumes = proposed.volumes, databases = proposed.databases, executors = proposed.executors}, nil
end

-- approved_drivers visits every consumed driver artifact whose host-selected
-- owner matches its desired slot and whose exact code overlay is present.
local function approved_drivers(config: Configuration, visit: ({Object}) -> string?): string?
    local resource, resource_error = resources.database()
    if not resource then return resource_error end
    local listed = activations.desired_slots(resource, config.node_id)
    local value = listed.ok and bounds.object(listed.value) or nil
    local slots = value and bounds.dense_list(value.slots, 1024, "desired driver slots") or nil
    if not slots then return listed.message or "desired driver slots are unavailable" end
    for _, raw_slot in ipairs(slots) do
        local slot = bounds.object(raw_slot)
        local workspace = slot and bounds.id(slot.workspace_id) or nil
        local owner_id = slot and bounds.id(slot.overlay_owner) or nil
        if not workspace or not owner_id then return "desired driver slot is malformed" end
        local store, open_error = activations.open(resource, config.node_id, workspace)
        if not store then return open_error end
        local desired = activations.desired(store, owner_id)
        activations.close(store)
        if not desired.ok then return desired.message end
        local intent = desired.ok and bounds.object(desired.value) or nil
        local source = intent and bounds.id(intent.source_workspace) or nil
        if source then
            local source_node = intent and bounds.id(intent.source_node) or nil
            local profile = source_node and activation_profiles.select(config, workspace, source_node, source) or nil
            if profile and profile.overlay_owner == owner_id and intent and intent.consumed_consumer_id == ACTOR then
                local decoded, decode_error = artifact.decode(intent.artifact_bytes, intent.artifact_digest)
                if not decoded then return decode_error end
                local present, present_error = materializer.matches(owner_id, decoded)
                if present == nil then return present_error end
                if present then
                    local visit_error = visit(decoded)
                    if visit_error then return visit_error end
                end
            end
        end
    end
    return nil
end

local function approved_driver_bindings(config: Configuration): ({string}?, string?)
    local bindings: {string} = {}
    local seen: Set = {}
    local walk_error = approved_drivers(config, function(decoded: {Object}): string?
        local selected, selection_error = driver_admission.bindings(decoded)
        if not selected then return selection_error end
        for _, id in ipairs(selected) do
            if not seen[id] then
                if #bindings >= 64 then return "approved driver bindings exceed their bound" end
                bindings[#bindings + 1], seen[id] = id, true
            end
        end
        return nil
    end)
    if walk_error then return nil, walk_error end
    table.sort(bindings)
    return bindings, nil
end

function M.driver_bindings(): ({string}?, string?)
    local config, config_error = load()
    if not config then return nil, config_error end
    return approved_driver_bindings(config)
end

-- driver_logins reports the login format each approved driver declares for its
-- own provider; the credential host projects the machine login only for these.
function M.driver_logins(): ({Object}?, string?)
    local config, config_error = load()
    if not config then return nil, config_error end
    local logins: {Object} = {}
    local seen: Set = {}
    local walk_error = approved_drivers(config, function(decoded: {Object}): string?
        local declared, login_error = driver_admission.logins(decoded)
        if not declared then return login_error end
        for _, login in ipairs(declared) do
            if not seen[login.provider] then
                if #logins >= 64 then return "approved driver logins exceed their bound" end
                logins[#logins + 1], seen[login.provider] = {provider = login.provider, format = login.format, path = login.path}, true
            end
        end
        return nil
    end)
    if walk_error then return nil, walk_error end
    return logins, nil
end

local function owner_config(config: Configuration, profile_value: Profile, plan_store: plans.Store,
    activation_store: activations.Store, lease_handle: leases.Store): OwnerConfigResult
    local executor, executor_error = approval_executor()
    if not executor then return {ok = false, error = tostring(executor_error or "approval executor is unavailable")} end
    local resolved = destination_resolver(config, profile_value, activation_store.node,
        profile_value.workspace_id, activation_store)
    -- An application database the intent's grant provisions joins the
    -- application's overlay with the grant that reaches it before its
    -- migrations run, and its migrations run with that grant.
    local function database_grants(work: migration_work.Work, intent: unknown): (migration_effect.Provisioned?, {string}?, string?)
        local staged: migration_effect.Provisioned = {databases = {}, policies = {}}
        local policies: {string} = {}
        local wanted: {[string]: migration_work.Database} = {}
        local any = false
        for _, item in ipairs(work.databases) do
            if item.database_id:sub(1, #capability_files.DATABASE_PREFIX) == capability_files.DATABASE_PREFIX then
                wanted[item.database_id], any = item, true
            end
        end
        if not any then return staged, policies, nil end
        local generated, generated_error = generated_install(profile_value, intent)
        if not generated then return nil, nil, generated_error or "the intent provisions no application database" end
        local granted: {[string]: boolean} = {}
        for _, raw_policy in ipairs(bounds.array(generated.policies, 64) or {}) do
            local policy = bounds.object(raw_policy)
            local data = policy and bounds.object(policy.data) or nil
            local inner = data and bounds.object(data.policy) or nil
            local resources = inner and bounds.array(inner.resources, 64) or nil
            local reaches: migration_work.Database? = nil
            for _, resource in ipairs(resources or {}) do
                if type(resource) == "string" and wanted[resource] then reaches = wanted[resource] end
            end
            if policy and reaches then
                policies[#policies + 1] = tostring(policy.id)
                granted[reaches.database_id] = true
                if reaches.planned then staged.policies[#staged.policies + 1] = policy end
            end
        end
        for id, item in pairs(wanted) do
            if not granted[id] then return nil, nil, "no approved grant reaches application database " .. id end
            if item.planned then staged.databases[#staged.databases + 1] = item.definition end
        end
        table.sort(policies)
        return staged, policies, nil
    end
    local migration_adapter = {
        matches = function(overlay_owner: string, work: migration_work.Work, intent: unknown): (boolean?, string?)
            local staged, _, staged_error = database_grants(work, intent)
            if not staged then return nil, staged_error end
            return migration_effect.matches(overlay_owner, work, staged)
        end,
        prepare = function(overlay_owner: string, work: migration_work.Work, intent: unknown): ({[string]: unknown}?, string?)
            local staged, _, staged_error = database_grants(work, intent)
            if not staged then return nil, staged_error end
            return migration_effect.prepare(overlay_owner, work, staged)
        end,
        clear = migration_effect.clear, cleared = migration_effect.cleared,
        execute = function(work: migration_work.Work, intent: unknown): ({bytes: string, digest: string}?, boolean, string?)
            local _, granted, grant_error = database_grants(work, intent)
            if not granted then return nil, false, grant_error end
            local execution: {string} = {}
            for _, id in ipairs(profile_value.migration_policies or {}) do execution[#execution + 1] = id end
            for _, id in ipairs(granted) do execution[#execution + 1] = id end
            local receipt, complete, execute_error = migration_effect.execute(work, execution)
            return receipt, complete, execute_error
        end,
    }
    local owner_configuration: owner.Config = {plans = plan_store, activations = activation_store, resolver = resolved,
        approvals = executor, actor_id = ACTOR, consumer_id = ACTOR, leases = lease_handle,
        overlay_owner = profile_value.overlay_owner, approval_policy = profile_value.approval_policy,
        apply = function(overlay_owner: string, entries: unknown, admission: unknown?, intent: unknown): ({[string]: unknown}?, string?, boolean?)
            local generated, generated_error = generated_install(profile_value, intent)
            if generated_error then return nil, generated_error, true end
            return materializer.reconcile_composed(overlay_owner, entries, admission, generated)
        end, matches = function(overlay_owner: string, entries: unknown, admission: unknown?, intent: unknown): (boolean?, string?)
            local generated, generated_error = generated_install(profile_value, intent)
            if generated_error then return nil, generated_error end
            return materializer.matches_composed(overlay_owner, entries, admission, generated)
        end, migrations = migration_adapter}
    return {ok = true, config = owner_configuration}
end

M.ACTOR = ACTOR
M.migration_database_owner = migration_database_owner
M.applied_database_evidence = applied_database_evidence
M.load = load
M.super_edit_approver_policy = super_edit_approver_policy
M.FORMAT = FORMAT
M.selected = selected
M.migration_binding = migration_binding
M.approval_executor = approval_executor
M.destination_resolver = destination_resolver
M.generated_install = generated_install
M.approved_drivers = approved_drivers
M.approved_driver_bindings = approved_driver_bindings
M.owner_config = owner_config
return M
