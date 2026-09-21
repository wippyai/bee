-- MIT. Pure decoder for host-selected activation policy profiles.
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local application_admission = require("application_admission")

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
type DecodedConfiguration = {profiles: {DecodedProfile}}
type Profile = {workspace_id: string, source_node: string, source_workspace: string,
    component: string, overlay_owner: string, approval_policy: string, resolver: string, parameters: {unknown},
    packages: Set, namespaces: Set, kinds: Set, databases: Set, grants: Set, modules: Set,
    database_bindings: DatabaseBindings?, migration_policies: PolicyIds?, applications: {Object}?,
    policy_digest: string}
type Configuration = {profiles: {Profile}}

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

local function decoded(raw: unknown): (DecodedConfiguration?, {Object}?, string?)
    local value = bounds.object(raw)
    local rows, rows_error = list(value and value.profiles or nil, "activation profiles")
    if not rows then return nil, nil, rows_error or "activation configuration is invalid" end
    if #rows > MAX_PROFILES then return nil, nil, "activation profile capacity is exceeded" end
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
    return {profiles = result}, policies, nil
end

-- Decode the complete host configuration without requiring a local node
-- identity. The result is suitable for consumers that need the configured
-- selection and ceilings but do not measure a destination authorization policy.
function M.decode(raw: unknown): (DecodedConfiguration?, string?)
    local configuration, _, decode_error = decoded(raw)
    return configuration, decode_error
end

-- Bind a normalized configuration to a destination node for the exact policy
-- digest consumed by activation. This preserves the historical configuration
-- result consumed by destination_service.
function M.configuration(raw: unknown, node_raw: unknown): (Configuration?, string?)
    local node_id = bounds.id(node_raw)
    if not node_id then return nil, "activation configuration is invalid" end
    local configuration, policies, decode_error = decoded(raw)
    if not configuration or not policies then return nil, decode_error end
    local result: {Profile} = {}
    for index, decoded_profile in ipairs(configuration.profiles) do
        local policy = policies[index]
        if not policy then return nil, "activation policy is unavailable" end
        policy.node_id = node_id
        local policy_bytes, encode_error = canonical.encode(policy)
        local policy_digest, digest_error = policy_bytes and hash.sha256(policy_bytes) or nil
        if not policy_digest then return nil, tostring(encode_error or digest_error or "measure activation policy") end
        result[index] = {workspace_id = decoded_profile.workspace_id, source_node = decoded_profile.source_node,
            source_workspace = decoded_profile.source_workspace, component = decoded_profile.component,
            overlay_owner = decoded_profile.overlay_owner, approval_policy = decoded_profile.approval_policy,
            resolver = decoded_profile.resolver, parameters = decoded_profile.parameters,
            packages = decoded_profile.packages, namespaces = decoded_profile.namespaces, kinds = decoded_profile.kinds,
            databases = decoded_profile.databases, grants = decoded_profile.grants, modules = decoded_profile.modules,
            database_bindings = decoded_profile.database_bindings,
            migration_policies = decoded_profile.migration_policies, applications = decoded_profile.applications,
            policy_digest = policy_digest}
    end
    return {profiles = result}, nil
end

return M
