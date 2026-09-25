-- MIT. Host-owned capability grant values. Portable requirements remain
-- declarations; only generated policy entries installed by activation grant.
local bounds = require("bounds")
local canonical = require("canonical")
local hash = require("hash")
local catalog = require("capability_catalog")
local containment = require("capability_containment")

local M = {}
M.SCHEMA = "bee.governance-capability-grants@1"
M.PREFIX = "bee.governance.grants:"
type Object = {[string]: unknown}
type Proposal = {capabilities: {Object}, policies: {Object}, bindings: {Object},
    thread_access: string, digest: string}

local function sha(raw: unknown): string?
    if type(raw) ~= "string" or #raw ~= 64 or not raw:match("^[0-9a-f]+$") then return nil end
    return raw
end
local function list(raw: unknown, limit: integer): {unknown}?
    if type(raw) ~= "table" then return nil end
    local count = 0
    for key in pairs(raw :: table) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil end
        count = count + 1
    end
    if count > limit then return nil end
    local capacity: integer = count > 0 and count or 1
    local result: {unknown} = table.create(capacity, 0)
    for index = 1, count do
        if (raw :: table)[index] == nil then return nil end
        result[index] = (raw :: table)[index]
    end
    return result
end
local function digest(value: unknown): string?
    local bytes = canonical.encode(value)
    return bytes and hash.sha256(bytes) or nil
end
local function policy_id(owner: string, requirement: string): string?
    local suffix = digest({owner = owner, requirement = requirement})
    return suffix and M.PREFIX .. "policy." .. suffix or nil
end
function M.record_id(owner_raw: unknown): string?
    local owner = bounds.id(owner_raw)
    local suffix = owner and hash.sha256(owner) or nil
    return suffix and M.PREFIX .. "record." .. suffix or nil
end
function M.reserved(raw: unknown): boolean
    return type(raw) == "string" and raw:sub(1, #M.PREFIX) == M.PREFIX
end

-- This slice materializes only owner-checked thread reads. Other catalog
-- entries remain review vocabulary until their resource and owner boundaries
-- arrive in later slices.
local function policy(grant: Object, id: string): (Object?, string?)
    local scope = bounds.object(grant.scope)
    if grant.capability ~= "threads.read" or grant.operation ~= "threads.read"
        or grant.resource ~= "threads" or not scope or scope.scope ~= "owned" then
        return nil, "capability has no installed enforcement in this slice"
    end
    return {id = id, kind = "security.policy", meta = {comment = "Host-generated owned thread read grant"},
        policy = {actions = {"funcs.call"},
            resources = {"bee.threads.service:get", "bee.threads.service:list",
                "bee.threads.service:read_after"}, effect = "allow"}}, nil
end

function M.propose(vocabulary: catalog.Catalog, owner_raw: unknown, app_raw: unknown,
    requirements_raw: unknown): (Proposal?, string?)
    local owner, app = bounds.id(owner_raw), bounds.id(app_raw)
    local rows = list(requirements_raw, 128)
    if not owner or not app or not rows then return nil, "capability proposal identity is invalid" end
    local capacity: integer = #rows > 0 and #rows or 1
    local capabilities: {Object} = table.create(capacity, 0)
    local policies: {Object} = table.create(capacity, 0)
    local bindings: {Object} = table.create(capacity, 0)
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(rows) do
        local item = bounds.object(raw)
        local request = item and bounds.object(item.capability_request) or nil
        local requirement_id = item and bounds.id(item.id) or nil
        local targets = item and list(item.targets, 1) or nil
        if not item or not request or not requirement_id or seen[requirement_id]
            or not targets or #targets ~= 1 or targets[1] ~= app
            or item.value ~= nil or item.expected_kind ~= "security.policy"
            or request.target ~= app or request.path ~= ".security.policies +="
            or request.catalog_revision ~= vocabulary.revision then
            return nil, "capability requirement is not a measured app policy append"
        end
        local template = type(request.capability) == "string" and vocabulary.capabilities[request.capability] or nil
        if not template or request.template_revision ~= template.revision then
            return nil, "capability template changed since resolution"
        end
        local resolved, resolve_error = catalog.resolve(vocabulary, request.capability, request.parameters)
        if not resolved then return nil, resolve_error end
        if #resolved ~= 1 then return nil, "capability template needs unsupported policy count" end
        local id = policy_id(owner :: string, requirement_id :: string)
        if not id then return nil, "measure generated policy identity" end
        local generated, policy_error = policy(resolved[1], id)
        if not generated then return nil, policy_error end
        seen[requirement_id] = true
        capabilities[#capabilities + 1] = resolved[1]
        policies[#policies + 1] = generated
        bindings[#bindings + 1] = {requirement_id = requirement_id, policy_id = id}
    end
    table.sort(capabilities, function(a: Object, b: Object): boolean
        return tostring(a.capability) .. tostring(a.resource) < tostring(b.capability) .. tostring(b.resource)
    end)
    table.sort(policies, function(a: Object, b: Object): boolean return tostring(a.id) < tostring(b.id) end)
    table.sort(bindings, function(a: Object, b: Object): boolean
        return tostring(a.requirement_id) < tostring(b.requirement_id)
    end)
    local set_digest = digest({capabilities = capabilities, bindings = bindings, policies = policies,
        thread_access = "none"})
    if not set_digest then return nil, "measure capability proposal" end
    return {capabilities = capabilities, policies = policies, bindings = bindings,
        thread_access = "none", digest = set_digest}, nil
end

function M.record(owner_raw: unknown, workspace_raw: unknown, app_raw: unknown,
    proposal: Proposal, approval_raw: unknown, revision_raw: unknown): (Object?, string?)
    local owner, workspace, app = bounds.id(owner_raw), bounds.id(workspace_raw), bounds.id(app_raw)
    local approval_id, revision = bounds.id(approval_raw), bounds.count(revision_raw)
    local id = M.record_id(owner)
    if not owner or not workspace or not app or not approval_id or not revision or revision < 1
        or not id or not sha(proposal.digest) then return nil, "capability grant record is invalid" end
    return {id = id, kind = "registry.entry", meta = {type = M.SCHEMA},
        data = {schema_revision = M.SCHEMA, overlay_owner = owner, workspace_id = workspace,
            application = app, capabilities = proposal.capabilities, bindings = proposal.bindings,
            policies = proposal.policies, thread_access = proposal.thread_access,
            digest = proposal.digest, approval_id = approval_id, revision = revision}}, nil
end

function M.decode(raw: unknown, owner_raw: unknown, workspace_raw: unknown,
    app_raw: unknown, vocabulary: catalog.Catalog): (Object?, string?)
    local item, owner = bounds.object(raw), bounds.id(owner_raw)
    local data = item and bounds.object(item.data) or nil
    local expected = M.record_id(owner)
    local meta = item and bounds.object(item.meta) or nil
    if not item or not data or not meta or meta.type ~= M.SCHEMA
        or item.id ~= expected or item.kind ~= "registry.entry"
        or data.schema_revision ~= M.SCHEMA or data.overlay_owner ~= owner
        or data.workspace_id ~= workspace_raw or data.application ~= app_raw
        or not bounds.id(data.approval_id) or not bounds.count(data.revision)
        or not sha(data.digest) or data.thread_access ~= "none" then
        return nil, "installed capability grant record is malformed"
    end
    local capabilities, bindings, policies = list(data.capabilities, 128), list(data.bindings, 128), list(data.policies, 128)
    if not capabilities or not bindings or not policies or #capabilities ~= #bindings
        or #bindings ~= #policies then return nil, "installed capability grant set is malformed" end
    local actual = digest({capabilities = capabilities, bindings = bindings, policies = policies,
        thread_access = data.thread_access})
    if actual ~= data.digest then return nil, "installed capability digest differs from the stored set" end
    local capacity: integer = #bindings > 0 and #bindings or 1
    local reproduced: {Object} = table.create(capacity, 0)
    for index, raw_binding in ipairs(bindings) do
        local binding = bounds.object(raw_binding)
        local grant = bounds.object(capabilities[index])
        if not binding or not grant or not bounds.id(binding.requirement_id)
            or not bounds.id(binding.policy_id) then return nil, "installed capability binding is malformed" end
        reproduced[index] = {id = binding.requirement_id, value = nil,
            expected_kind = "security.policy", targets = {app_raw}, capability_request = {
                capability = grant.capability, parameters = grant.parameters,
                template_revision = grant.template_revision, catalog_revision = vocabulary.revision,
                target = app_raw, path = ".security.policies +="}}
    end
    local resolved, resolve_error = M.propose(vocabulary, owner, app_raw, reproduced)
    if not resolved or resolved.digest ~= data.digest then
        return nil, resolve_error or "installed capability digest differs from host templates"
    end
    return data, nil
end

function M.diff(vocabulary: catalog.Catalog, installed: Object?, proposal: Proposal): (Object?, string?)
    local old = installed and installed.capabilities or table.create(1, 0)
    local compared, compare_error = containment.compare(old, proposal.capabilities)
    if not compared then return nil, compare_error end
    local lines: {string} = {}
    for _, category in ipairs({"added", "widened", "narrowed", "removed", "changed"}) do
        for _, raw_change in ipairs(compared[category] :: {unknown}) do
            local change = raw_change :: Object
            local value = category == "removed" and change.before or change.after
            local rendered, render_error = catalog.render(vocabulary, {value})
            if not rendered then return nil, render_error end
            lines[#lines + 1] = category .. ": " .. tostring(rendered[1])
        end
    end
    local flows, flow_error = catalog.render(vocabulary, proposal.capabilities)
    if not flows then return nil, flow_error end
    for _, line in ipairs(flows) do
        if line:find(" may be sent to ", 1, true) then lines[#lines + 1] = line end
    end
    compared.lines = lines
    return compared, nil
end

return M
