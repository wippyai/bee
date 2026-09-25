-- MIT. Canonical host-selected application admission carried by one governed
-- overlay. This module is pure: it reads no registry state and grants no
-- capability. Activation and the application catalog separately decide when
-- a measured record is trusted.
local canonical = require("canonical")
local hash = require("hash")
local bounds = require("bounds")
local json = require("json")

local M = {}

M.SCHEMA = "bee.governance-application-admission@1"
M.MAX_BINDINGS = 64
M.MAX_POLICIES = 16
M.MAX_BYTES = 65536
M.MAX_POLICY_BYTES = 262144
M.NAMESPACE = "bee.gov"
M.RESERVED_PREFIX = M.NAMESPACE .. ":admission."
local PRIOR_ADMISSION_PREFIX = "bee.governance:admission."
local PRIOR_GRANTS_PREFIX = "bee.governance.grants:"
local PRIOR_WORKSPACE_OWNER_PREFIX = "bee.governance.workspace_applications:"

type Object = {[string]: unknown}
type ThreadAccess = "none" | "observe_post"
type Binding = {definition_id: string, policies: {string}, thread_access: ThreadAccess}
type Record = {schema_revision: string, workspace_id: string, overlay_owner: string,
    source_node: string, source_workspace: string, artifact_digest: string,
    policy_digest: string, bindings: {Binding}}
type Measurement = {id: string, record: Record, bytes: string, digest: string}
type Entry = {id: string, kind: string, data: Record}

local function sha(value: unknown): string?
    if type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-f]+$") then return nil end
    return value
end

local function registry_id(value: unknown): string?
    local id = bounds.id(value)
    if not id or not id:match("^[A-Za-z0-9][A-Za-z0-9_.-]*:[A-Za-z0-9][A-Za-z0-9_.-]*$") then return nil end
    return id
end

local function dense(raw: unknown, label: string, maximum: integer): (table?, integer?, string?)
    if type(raw) ~= "table" then return nil, nil, label .. " must be a list" end
    local count = 0
    for key in pairs(raw :: table) do
        if type(key) ~= "number" or key ~= math.floor(key :: number) or (key :: number) < 1 then
            return nil, nil, label .. " must be a dense list"
        end
        count = count + 1
    end
    if count > maximum then return nil, nil, label .. " exceeds its bound" end
    for index = 1, count do
        if (raw :: table)[index] == nil then return nil, nil, label .. " must be a dense list" end
    end
    return raw :: table, count, nil
end

local function thread_access(raw: unknown): ThreadAccess?
    if raw == nil or raw == "none" then return "none" end
    if raw == "observe_post" then return "observe_post" end
    return nil
end

type Grant = {policies: {string}, thread_access: ThreadAccess}

-- The admission a binding grants its definition: sorted distinct external
-- policy identities and the thread access.
function M.grant(policies_raw: unknown, thread_access_raw: unknown): (Grant?, string?)
    local access = thread_access(thread_access_raw)
    local rows, count, rows_error = dense(policies_raw, "application policies", M.MAX_POLICIES)
    if not access or not rows or count == nil then
        return nil, rows_error or "application admission grant is invalid"
    end
    -- Preallocate an array slot even for zero rows so canonical JSON retains
    -- the empty-list shape rather than turning it into an object.
    local capacity: integer = count
    if capacity < 1 then capacity = 1 end
    local policies: {string} = table.create(capacity, 0)
    local seen: {[string]: boolean} = {}
    for index = 1, count do
        local policy = registry_id(rows[index])
        if not policy or seen[policy] then return nil, "application policies contain an invalid or duplicate value" end
        seen[policy] = true
        policies[index] = policy
    end
    table.sort(policies)
    return {policies = policies, thread_access = access}, nil
end

local function binding(raw: unknown): (Binding?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "application binding must be an object" end
    local extra = bounds.fields(value, {"definition_id", "policies", "thread_access"})
    if extra then return nil, "application binding: " .. extra end
    local definition_id = registry_id(value.definition_id)
    if not definition_id then return nil, "application binding is invalid" end
    local granted, grant_error = M.grant(value.policies, value.thread_access)
    if not granted then return nil, grant_error end
    return {definition_id = definition_id, policies = granted.policies, thread_access = granted.thread_access}, nil
end

function M.bindings(raw: unknown): ({Binding}?, string?)
    local rows, count, rows_error = dense(raw, "applications", M.MAX_BINDINGS)
    if not rows or count == nil then return nil, rows_error end
    local capacity: integer = count
    if capacity < 1 then capacity = 1 end
    local result: {Binding} = table.create(capacity, 0)
    local seen: {[string]: boolean} = {}
    for index = 1, count do
        local item, item_error = binding(rows[index])
        if not item then return nil, item_error end
        if seen[item.definition_id] then return nil, "application definition is duplicated" end
        seen[item.definition_id] = true
        result[index] = item
    end
    table.sort(result, function(left: Binding, right: Binding): boolean
        return left.definition_id < right.definition_id
    end)
    return result, nil
end

function M.record(raw: unknown): (Record?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "application admission record must be an object" end
    local extra = bounds.fields(value, {"schema_revision", "workspace_id", "overlay_owner",
        "source_node", "source_workspace", "artifact_digest", "policy_digest", "bindings"})
    if extra then return nil, "application admission record: " .. extra end
    local workspace_id, overlay_owner = bounds.id(value.workspace_id), bounds.id(value.overlay_owner)
    local source_node, source_workspace = bounds.id(value.source_node), bounds.id(value.source_workspace)
    local artifact_digest, policy_digest = sha(value.artifact_digest), sha(value.policy_digest)
    local bindings, bindings_error = M.bindings(value.bindings)
    if value.schema_revision ~= M.SCHEMA or not workspace_id or not overlay_owner
        or not source_node or not source_workspace or not artifact_digest or not policy_digest or not bindings then
        return nil, bindings_error or "application admission record is invalid"
    end
    return {schema_revision = M.SCHEMA, workspace_id = workspace_id, overlay_owner = overlay_owner,
        source_node = source_node, source_workspace = source_workspace,
        artifact_digest = artifact_digest, policy_digest = policy_digest, bindings = bindings}, nil
end

function M.id(owner_raw: unknown): (string?, string?)
    local owner = bounds.id(owner_raw)
    if not owner then return nil, "application admission overlay owner is invalid" end
    local digest, digest_error = hash.sha256(owner)
    if not digest then return nil, tostring(digest_error or "measure application admission owner") end
    -- An admission installed under the prior workspace owner is a measured
    -- registry identity. Keep it when reconstructing an immutable activation.
    local prefix = owner:sub(1, #PRIOR_WORKSPACE_OWNER_PREFIX) == PRIOR_WORKSPACE_OWNER_PREFIX
        and PRIOR_ADMISSION_PREFIX or M.RESERVED_PREFIX
    return prefix .. digest, nil
end
function M.prior_id(owner_raw: unknown): string?
    local owner = bounds.id(owner_raw)
    local digest = owner and hash.sha256(owner) or nil
    return digest and PRIOR_ADMISSION_PREFIX .. digest or nil
end

-- Admission records live under an owner-derived private identity.  Treat the
-- whole prefix as reserved, including malformed suffixes: a portable artifact
-- must never get to claim a present or future admission identity.
function M.reserved(raw: unknown): boolean
    return type(raw) == "string" and ((raw :: string):sub(1, #M.RESERVED_PREFIX) == M.RESERVED_PREFIX
        or (raw :: string):sub(1, #"bee.gov.grants:") == "bee.gov.grants:"
        or (raw :: string):sub(1, #PRIOR_ADMISSION_PREFIX) == PRIOR_ADMISSION_PREFIX
        or (raw :: string):sub(1, #PRIOR_GRANTS_PREFIX) == PRIOR_GRANTS_PREFIX)
end

-- Decode the immutable byte handoff exactly as it was measured.  JSON only
-- parses the input; remeasurement rejects a valid-looking noncanonical body.
function M.decode(bytes_raw: unknown, digest_raw: unknown): (Measurement?, string?)
    if type(bytes_raw) ~= "string" or #bytes_raw == 0 or #bytes_raw > M.MAX_BYTES then
        return nil, "application admission bytes exceed bound"
    end
    local digest = sha(digest_raw)
    if not digest then return nil, "application admission digest is malformed" end
    local actual, actual_error = hash.sha256(bytes_raw)
    if not actual then return nil, tostring(actual_error or "measure application admission") end
    if actual ~= digest then return nil, "application admission digest does not match bytes" end
    local raw, decode_error = json.decode(bytes_raw)
    if decode_error then return nil, "application admission bytes are malformed" end
    local measured, measure_error = M.measure(raw)
    if not measured or measured.bytes ~= bytes_raw or measured.digest ~= digest then
        return nil, tostring(measure_error or "application admission bytes are not canonical")
    end
    return measured, nil
end

-- This record is deliberately outside the portable artifact envelope.  It is
-- a registry entry only after the destination has measured and frozen it.
function M.entry(bytes_raw: unknown, digest_raw: unknown): (Entry?, string?)
    local measured, measure_error = M.decode(bytes_raw, digest_raw)
    if not measured then return nil, measure_error end
    return {id = measured.id, kind = "registry.entry", data = measured.record}, nil
end

function M.measure(raw: unknown): (Measurement?, string?)
    local record, record_error = M.record(raw)
    if not record then return nil, record_error end
    local bytes, encode_error = canonical.encode(record, M.MAX_BYTES)
    if not bytes then return nil, tostring(encode_error or "encode application admission") end
    local digest, digest_error = hash.sha256(bytes)
    if not digest then return nil, tostring(digest_error or "measure application admission") end
    local id, id_error = M.id(record.overlay_owner)
    if not id then return nil, id_error end
    return {id = id, record = record, bytes = bytes, digest = digest}, nil
end

-- Derive admission only from one resolver capture. Artifact definitions and
-- external policy definitions are separate inputs so a candidate can never
-- satisfy its own authority declaration.
function M.project(raw: unknown): (Measurement?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "application admission projection must be an object" end
    local extra = bounds.fields(value, {"workspace_id", "overlay_owner", "source_node", "source_workspace",
        "artifact_digest", "bindings", "artifact_entries", "registry_entries", "overlay_ids",
        "generated_policies"})
    if extra then return nil, "application admission projection: " .. extra end
    local bindings, bindings_error = M.bindings(value.bindings)
    if not bindings then return nil, bindings_error end
    if #bindings == 0 then return nil, nil end
    local artifact_rows, artifact_count, artifact_error = dense(value.artifact_entries,
        "application artifact entries", 512)
    local registry_rows, registry_count, registry_error = dense(value.registry_entries,
        "application registry entries", 4096)
    if not artifact_rows or artifact_count == nil or not registry_rows or registry_count == nil then
        return nil, artifact_error or registry_error
    end
    if value.overlay_ids ~= nil and type(value.overlay_ids) ~= "table" then
        return nil, "application overlay identities are malformed"
    end
    local overlay_ids = type(value.overlay_ids) == "table" and value.overlay_ids :: table or {}
    local artifacts: {[string]: Object} = {}
    for index = 1, artifact_count do
        local entry = bounds.object(artifact_rows[index])
        local id = entry and registry_id(entry.id) or nil
        if not entry or not id or artifacts[id] then return nil, "application artifact entry is invalid or duplicated" end
        artifacts[id] = entry
    end
    local captured: {[string]: Object} = {}
    for index = 1, registry_count do
        local entry = bounds.object(registry_rows[index])
        local id = entry and registry_id(entry.id) or nil
        if not entry or not id or captured[id] then return nil, "application registry entry is invalid or duplicated" end
        captured[id] = entry
    end
    local generated: {[string]: Object} = {}
    if value.generated_policies ~= nil then
        local generated_rows, generated_count, generated_error = dense(value.generated_policies,
            "generated application policies", M.MAX_POLICIES)
        if not generated_rows or generated_count == nil then return nil, generated_error end
        for index = 1, generated_count do
            local entry = bounds.object(generated_rows[index])
            local id = entry and registry_id(entry.id) or nil
            if not entry or not id or (not id:match("^bee%.gov%.grants:policy%.[0-9a-f]+$")
                and not id:match("^bee%.governance%.grants:policy%.[0-9a-f]+$"))
                or generated[id] or entry.kind ~= "security.policy" then
                return nil, "generated application policy is invalid"
            end
            generated[id] = entry
        end
    end
    local selected_policies: {[string]: boolean} = {}
    for _, selected in ipairs(bindings) do
        local definition = artifacts[selected.definition_id]
        local meta = definition and bounds.object(definition.meta) or nil
        if not definition or definition.kind ~= "process.lua" or not meta or meta.type ~= "bee.application" then
            return nil, "admitted application is not an exact artifact application: " .. selected.definition_id
        end
        for _, policy in ipairs(selected.policies) do
            if artifacts[policy] then return nil, "application policy is supplied by the candidate: " .. policy end
            if overlay_ids[policy] and not generated[policy] then
                return nil, "application policy belongs to the selected overlay: " .. policy
            end
            selected_policies[policy] = true
        end
    end
    local policy_count = 0
    for _ in pairs(selected_policies) do policy_count = policy_count + 1 end
    local capacity: integer = policy_count
    if capacity < 1 then capacity = 1 end
    local policies: {Object} = table.create(capacity, 0)
    for policy in pairs(selected_policies) do
        local definition = generated[policy] or captured[policy]
        if not definition or (definition.kind ~= "security.policy" and definition.kind ~= "security.policy.expr") then
            return nil, "application policy is not an external security policy: " .. policy
        end
        local clean: Object = {}
        for field, item in pairs(definition) do if field ~= "registry" then clean[field] = item end end
        if clean.meta == nil or (type(clean.meta) == "table" and next(clean.meta :: table) == nil) then
            clean.meta = table.create(0, 1)
        end
        policies[#policies + 1] = clean
    end
    table.sort(policies, function(left: Object, right: Object): boolean
        return tostring(left.id) < tostring(right.id)
    end)
    local policy_bytes, policy_error = canonical.encode({schema_revision = "bee.governance-application-policies@1",
        policies = policies}, M.MAX_POLICY_BYTES)
    if not policy_bytes then return nil, tostring(policy_error or "encode application policies") end
    local policy_digest, policy_digest_error = hash.sha256(policy_bytes)
    if not policy_digest then return nil, tostring(policy_digest_error or "measure application policies") end
    return M.measure({schema_revision = M.SCHEMA, workspace_id = value.workspace_id,
        overlay_owner = value.overlay_owner, source_node = value.source_node,
        source_workspace = value.source_workspace, artifact_digest = value.artifact_digest,
        policy_digest = policy_digest, bindings = bindings})
end

return M
