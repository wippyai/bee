-- MIT. Pure decoder for host-selected activation policy profiles.
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local application_admission = require("application_admission")
local workspace_applications = require("workspace_applications")

local M = {}
local MAX_PROFILES = 64
local MAX_DATABASE_BINDINGS = 256
type Object = {[string]: unknown}
type Set = {[string]: boolean}
type DatabaseBinding = {database_id: string, table_prefix: string?}
type DatabaseBindings = {[string]: DatabaseBinding}
type PolicyIds = {string}
type DecodedProfile = {workspace_id: string, source_node: string, source_workspace: string,
    component: string, overlay_owner: string, approval_policy: string, resolver: string, parameters: {unknown},
    packages: Set, namespaces: Set, kinds: Set, databases: Set, grants: Set, modules: Set,
    database_bindings: DatabaseBindings?, migration_policies: PolicyIds?, applications: {Object}?}
-- The host's rule for applications a workspace's own agents deliver to it:
-- one profile per eligible local overlay, derived by workspace_applications.
type Template = {approval_policy: string, kinds: {string}, modules: {string}, policies: {string},
    thread_access: string}
type DecodedConfiguration = {profiles: {DecodedProfile}, workspace_applications: Template?}
type Profile = {workspace_id: string, source_node: string, source_workspace: string,
    component: string, overlay_owner: string, approval_policy: string, resolver: string, parameters: {unknown},
    packages: Set, namespaces: Set, kinds: Set, databases: Set, grants: Set, modules: Set,
    database_bindings: DatabaseBindings?, migration_policies: PolicyIds?, applications: {Object}?,
    policy_digest: string}
type Configuration = {node_id: string, profiles: {Profile}, workspace_applications: Template?}

local function list(raw: unknown, label: string): ({unknown}?, string?)
    if type(raw) ~= "table" then return nil, label .. " must be a list" end
    local source = raw :: table
    local count = 0
    for key in pairs(source) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil, label .. " must be a dense list" end
        count = count + 1
    end
    if count > 256 then return nil, label .. " exceeds its bound" end
    local result: {unknown} = {}
    for index = 1, count do
        if source[index] == nil then return nil, label .. " must be a dense list" end
        result[index] = source[index]
    end
    return result, nil
end

local function set(raw: unknown, label: string): (Set?, string?)
    local rows, rows_error = list(raw, label)
    if not rows then return nil, rows_error end
    local result: Set = {}
    for _, raw_value in ipairs(rows) do
        local value = bounds.id(raw_value)
        if not value or result[value] then return nil, label .. " contains an invalid or duplicate value" end
        result[value] = true
    end
    return result, nil
end

local function database_bindings(raw: unknown, databases: Set): (DatabaseBindings?, {unknown}?, string?)
    if raw == nil then return nil, nil, nil end
    local rows, rows_error = list(raw, "database bindings")
    if not rows then return nil, nil, rows_error end
    if #rows > MAX_DATABASE_BINDINGS then return nil, nil, "database bindings exceed their bound" end
    local result: DatabaseBindings = {}
    local measured: {unknown} = {}
    for index, raw_binding in ipairs(rows) do
        local value = bounds.object(raw_binding)
        local extra = value and bounds.fields(value, {"target_db", "database_id", "table_prefix"}) or nil
        local target_db = value and bounds.id(value.target_db) or nil
        local database_id = value and bounds.id(value.database_id) or nil
        local table_prefix: string? = nil
        if value and value.table_prefix ~= nil then
            table_prefix = bounds.text(value.table_prefix, 64)
            if not table_prefix or not table_prefix:match("^[A-Za-z][A-Za-z0-9_]*$") then
                return nil, nil, "database binding table_prefix is invalid"
            end
        end
        if not value or extra or not target_db or not database_id or not databases[target_db]
            or result[target_db] then
            return nil, nil, extra and "database binding: " .. extra
                or "database binding is invalid or duplicated"
        end
        result[target_db] = {database_id = database_id, table_prefix = table_prefix}
        local item: Object = {target_db = target_db, database_id = database_id}
        if table_prefix then item.table_prefix = table_prefix end
        measured[index] = item
    end
    table.sort(measured, function(left: unknown, right: unknown): boolean
        local a, b = bounds.object(left), bounds.object(right)
        return tostring(a and a.target_db or "") < tostring(b and b.target_db or "")
    end)
    return result, measured, nil
end

local function policy_ids(raw: unknown): (PolicyIds?, string?)
    if raw == nil then return nil, nil end
    local rows, rows_error = list(raw, "migration policies")
    if not rows then return nil, rows_error end
    if #rows > 64 then return nil, "migration policies exceed their bound" end
    local result: PolicyIds = {}
    local seen: Set = {}
    for index, raw_id in ipairs(rows) do
        local id = bounds.id(raw_id)
        if not id or seen[id] then return nil, "migration policies contain an invalid or duplicate value" end
        seen[id] = true
        result[index] = id
    end
    table.sort(result)
    return result, nil
end

local function profile(raw: unknown): (DecodedProfile?, Object?, string?)
    local value = bounds.object(raw)
    if not value then return nil, nil, "activation profile must be an object" end
    local extra = bounds.fields(value, {"workspace_id", "source_node", "source_workspace", "component",
        "overlay_owner", "approval_policy", "resolver", "parameters", "allow", "database_bindings",
        "migration_policies", "applications"})
    if extra then return nil, nil, "activation profile: " .. extra end
    local workspace_id, source_node = bounds.id(value.workspace_id), bounds.id(value.source_node)
    local source_workspace, component = bounds.id(value.source_workspace), bounds.text(value.component, 160)
    local overlay_owner, approval_policy = bounds.id(value.overlay_owner), bounds.id(value.approval_policy)
    local resolver_kind = value.resolver == nil and "hub" or value.resolver
    local parameters, parameters_error = list(value.parameters or {}, "activation parameters")
    local allow = bounds.object(value.allow)
    if not workspace_id or not source_node or not source_workspace or not component or component == ""
        or not overlay_owner or not approval_policy or (resolver_kind ~= "hub" and resolver_kind ~= "overlay")
        or not parameters or not allow then
        return nil, nil, parameters_error or "activation profile identity is invalid"
    end
    local allow_extra = bounds.fields(allow, {"packages", "namespaces", "kinds", "databases", "grants", "modules"})
    if allow_extra then return nil, nil, "activation allowlist: " .. allow_extra end
    local packages, packages_error = set(allow.packages or {}, "allowed packages")
    local namespaces, namespaces_error = set(allow.namespaces or {}, "allowed namespaces")
    local kinds, kinds_error = set(allow.kinds or {}, "allowed kinds")
    local databases, databases_error = set(allow.databases or {}, "allowed databases")
    local grants, grants_error = set(allow.grants or {}, "allowed grants")
    local modules, modules_error = set(allow.modules or {}, "allowed modules")
    if not packages or not namespaces or not kinds or not databases or not grants or not modules then
        return nil, nil, packages_error or namespaces_error or kinds_error or databases_error or grants_error or modules_error
    end
    local bindings, measured_bindings, bindings_error = database_bindings(value.database_bindings, databases)
    if bindings_error then return nil, nil, bindings_error end
    local migration_policies, migration_policies_error = policy_ids(value.migration_policies)
    if migration_policies_error then return nil, nil, migration_policies_error end
    local applications: {Object}? = nil
    if value.applications ~= nil then
        local decoded, applications_error = application_admission.bindings(value.applications)
        if not decoded then return nil, nil, applications_error end
        if #decoded > 0 then applications = decoded :: {Object} end
    end
    local policy: Object = {schema_revision = "bee.governance-activation-policy@1",
        workspace_id = workspace_id, source_node = source_node,
        source_workspace = source_workspace, component = component, overlay_owner = overlay_owner,
        approval_policy = approval_policy, resolver = resolver_kind, parameters = parameters, allow = allow}
    if measured_bindings then policy.database_bindings = measured_bindings end
    if migration_policies then policy.migration_policies = migration_policies end
    if applications then policy.applications = applications end
    return {workspace_id = workspace_id, source_node = source_node, source_workspace = source_workspace,
        component = component, overlay_owner = overlay_owner, approval_policy = approval_policy,
        resolver = resolver_kind :: string,
        parameters = parameters, packages = packages, namespaces = namespaces, kinds = kinds,
        databases = databases, grants = grants, modules = modules,
        database_bindings = bindings, migration_policies = migration_policies,
        applications = applications}, policy, nil
end

local function sorted_set(raw: unknown, label: string): ({string}?, string?)
    local values, values_error = set(raw, label)
    if not values then return nil, values_error end
    local result: {string} = {}
    for value in pairs(values) do result[#result + 1] = value end
    table.sort(result)
    return result, nil
end

local function template(raw: unknown): (Template?, string?)
    if raw == nil then return nil, nil end
    local value = bounds.object(raw)
    if not value then return nil, "workspace applications profile must be an object" end
    local extra = bounds.fields(value, {"approval_policy", "kinds", "modules", "policies", "thread_access"})
    if extra then return nil, "workspace applications profile: " .. extra end
    local approval_policy = bounds.id(value.approval_policy)
    if not approval_policy then return nil, "workspace applications profile names no approval policy" end
    local kinds, kinds_error = sorted_set(value.kinds, "workspace application kinds")
    local modules, modules_error = sorted_set(value.modules, "workspace application modules")
    if not kinds or not modules then return nil, kinds_error or modules_error end
    if #kinds == 0 then return nil, "workspace applications profile admits no entry kind" end
    local probe, probe_error = application_admission.bindings({{definition_id = "app.profile:app",
        policies = value.policies, thread_access = value.thread_access}})
    local binding = probe and probe[1] or nil
    if not binding then return nil, "workspace application admission: " .. tostring(probe_error) end
    return {approval_policy = approval_policy, kinds = kinds, modules = modules,
        policies = binding.policies, thread_access = binding.thread_access}, nil
end

local function empty_list(): {unknown}
    return table.create(1, 0)
end

-- One eligible local overlay's profile, built as host configuration and
-- decoded by the same rules as an explicit row.
local function instantiate(rule: Template, workspace_id: string, source_node: string,
    source_workspace: string): (DecodedProfile?, Object?, string?)
    local identity, identity_error = workspace_applications.identity(workspace_id, source_workspace)
    if not identity then return nil, nil, identity_error end
    local policies: {unknown} = empty_list()
    for index, policy in ipairs(rule.policies) do policies[index] = policy end
    return profile({workspace_id = workspace_id, source_node = source_node, source_workspace = identity.name,
        component = identity.component, overlay_owner = identity.overlay_owner,
        approval_policy = rule.approval_policy, resolver = "overlay", parameters = empty_list(),
        allow = {packages = {identity.component}, namespaces = {identity.namespace}, kinds = rule.kinds,
            databases = empty_list(), grants = empty_list(), modules = rule.modules},
        applications = {{definition_id = identity.definition_id, policies = policies,
            thread_access = rule.thread_access}}})
end

local function decoded(raw: unknown): (DecodedConfiguration?, {Object}?, string?)
    local value = bounds.object(raw)
    local extra = value and bounds.fields(value, {"profiles", "workspace_applications"}) or nil
    if extra then return nil, nil, "activation configuration: " .. extra end
    local rows, rows_error = list(value and value.profiles or nil, "activation profiles")
    if not rows then return nil, nil, rows_error or "activation configuration is invalid" end
    if #rows > MAX_PROFILES then return nil, nil, "activation profile capacity is exceeded" end
    local rule, rule_error = template(value and value.workspace_applications or nil)
    if rule_error then return nil, nil, rule_error end
    local result: {DecodedProfile} = {}
    local policies: {Object} = {}
    local keys: Set = {}
    for _, raw_profile in ipairs(rows) do
        local item, policy, item_error = profile(raw_profile)
        if not item or not policy then return nil, nil, item_error end
        local key = item.workspace_id .. "\n" .. item.source_node .. "\n" .. item.source_workspace
        if keys[key] then return nil, nil, "activation profile identity is duplicated" end
        keys[key] = true
        result[#result + 1] = item
        policies[#policies + 1] = policy
    end
    return {profiles = result, workspace_applications = rule}, policies, nil
end

local function measure(decoded_profile: DecodedProfile, policy: Object, node_id: string): (Profile?, string?)
    policy.node_id = node_id
    local policy_bytes, encode_error = canonical.encode(policy)
    local policy_digest, digest_error = policy_bytes and hash.sha256(policy_bytes) or nil
    if not policy_digest then return nil, tostring(encode_error or digest_error or "measure activation policy") end
    return {workspace_id = decoded_profile.workspace_id, source_node = decoded_profile.source_node,
        source_workspace = decoded_profile.source_workspace, component = decoded_profile.component,
        overlay_owner = decoded_profile.overlay_owner, approval_policy = decoded_profile.approval_policy,
        resolver = decoded_profile.resolver, parameters = decoded_profile.parameters,
        packages = decoded_profile.packages, namespaces = decoded_profile.namespaces, kinds = decoded_profile.kinds,
        databases = decoded_profile.databases, grants = decoded_profile.grants, modules = decoded_profile.modules,
        database_bindings = decoded_profile.database_bindings,
        migration_policies = decoded_profile.migration_policies, applications = decoded_profile.applications,
        policy_digest = policy_digest}, nil
end

local function missing(workspace_id: string, source_node: string, source_workspace: string): string
    return "this workspace has no activation profile for overlay " .. source_workspace .. " from node "
        .. source_node .. "; a host adds one to bee.governance:activation_profiles"
        .. " (workspace " .. workspace_id .. ")"
end

-- Decode the complete host configuration without requiring a local node
-- identity. The result is suitable for consumers that need the configured
-- selection and ceilings but do not measure a destination authorization policy.
function M.decode(raw: unknown): (DecodedConfiguration?, string?)
    local configuration, _, decode_error = decoded(raw)
    return configuration, decode_error
end

-- Bind a normalized configuration to a destination node for the exact policy
-- digest consumed by activation.
function M.configuration(raw: unknown, node_raw: unknown): (Configuration?, string?)
    local node_id = bounds.id(node_raw)
    if not node_id then return nil, "activation configuration is invalid" end
    local configuration, policies, decode_error = decoded(raw)
    if not configuration or not policies then return nil, decode_error end
    local result: {Profile} = {}
    for index, decoded_profile in ipairs(configuration.profiles) do
        local policy = policies[index]
        if not policy then return nil, "activation policy is unavailable" end
        local measured, measure_error = measure(decoded_profile, policy, node_id)
        if not measured then return nil, measure_error end
        result[index] = measured
    end
    return {node_id = node_id, profiles = result, workspace_applications = configuration.workspace_applications}, nil
end

type Identity = {workspace_id: string, source_node: string, source_workspace: string}

-- The index of the one explicit row for a source at a destination workspace.
local function explicit(rows: {Identity}, workspace_id: string, source_node: string,
    source_workspace: string): (integer?, string?)
    local found: integer? = nil
    for index, item in ipairs(rows) do
        if item.workspace_id == workspace_id and item.source_node == source_node
            and item.source_workspace == source_workspace then
            if found then return nil, "activation profile identity is ambiguous" end
            found = index
        end
    end
    return found, nil
end

-- The one host profile for a source at a destination workspace: an explicit
-- row, or else the workspace-applications rule for an overlay this node
-- authored. The refusal names what a host configures.
function M.select_decoded(configuration: DecodedConfiguration, workspace_id: string, source_node: string,
    source_workspace: string, node_id: string): (DecodedProfile?, string?)
    local index, ambiguous = explicit(configuration.profiles, workspace_id, source_node, source_workspace)
    if ambiguous then return nil, ambiguous end
    if index then return configuration.profiles[index], nil end
    local rule = configuration.workspace_applications
    if rule and source_node == node_id then
        local item, _, instantiate_error = instantiate(rule, workspace_id, source_node, source_workspace)
        return item, instantiate_error
    end
    return nil, missing(workspace_id, source_node, source_workspace)
end

-- The measured form of select_decoded, for the destination owner.
function M.select(configuration: Configuration, workspace_id: string, source_node: string,
    source_workspace: string): (Profile?, string?)
    local index, ambiguous = explicit(configuration.profiles, workspace_id, source_node, source_workspace)
    if ambiguous then return nil, ambiguous end
    if index then return configuration.profiles[index], nil end
    local rule = configuration.workspace_applications
    if rule and source_node == configuration.node_id then
        local item, policy, instantiate_error = instantiate(rule, workspace_id, source_node, source_workspace)
        if not item or not policy then return nil, instantiate_error end
        return measure(item, policy, configuration.node_id)
    end
    return nil, missing(workspace_id, source_node, source_workspace)
end

return M
