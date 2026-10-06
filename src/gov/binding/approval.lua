-- MIT. Exact bridge from a measured activation intent to the local Approvals
-- owner. It neither decides a request nor applies an overlay.
local canonical = require("canonical")
local bounds = require("bounds")

local drivers = require("drivers")
local M = {}
local REQUEST = "bee.approvals.binding:request"
local CONSUME = "bee.approvals.binding:consume"
local REVALIDATE = "bee.approvals.binding:revalidate"
local READ = "bee.approvals.binding:read"
local CLOSE = "bee.approvals.binding:close_activation"

type Object = {[string]: unknown}
type Executor = {call: (Executor, string, unknown) -> (unknown?, unknown?)}
type Fault = {code: string, message: string, value: Object?}
-- A pending migration the activation runs: its definition and the database
-- it changes.
type Migration = {id: string, target_db: string}
-- How the person knows what they install: the application's own title, who
-- made it and where it came from, and the names its tools go by for agents.
type Presentation = {title: string?, maker: string?, tools: {[string]: string}?}

local function object(value: unknown): Object?
    return bounds.object(value)
end

local function reply(value: unknown, err: unknown): (Object?, string?)
    if err then return nil, tostring(err) end
    local envelope = object(value)
    if not envelope then return nil, "approval owner returned a malformed reply" end
    if envelope.ok ~= true then
        local fault = object(envelope.error) or {}
        return nil, tostring(fault.code or "UNAVAILABLE") .. ": " .. tostring(fault.message or "approval owner refused the request")
    end
    local result = object(envelope.value)
    if not result then return nil, "approval owner returned no request" end
    return result, nil
end

local function typed_reply(value: unknown, err: unknown): (Object?, Fault?)
    if err then return nil, {code = "UNAVAILABLE", message = tostring(err), value = nil} end
    local envelope = object(value)
    if not envelope then return nil, {code = "UNAVAILABLE", message = "approval owner returned a malformed reply", value = nil} end
    if envelope.ok ~= true then
        local fault = object(envelope.error) or {}
        return nil, {code = tostring(fault.code or "UNAVAILABLE"),
            message = tostring(fault.message or "approval owner refused the request"),
            value = object(envelope.value)}
    end
    local result = object(envelope.value)
    if not result then return nil, {code = "UNAVAILABLE", message = "approval owner returned no request", value = nil} end
    return result, nil
end

local function hex(value: unknown): string?
    local measured = bounds.text(value, 64)
    if not measured or #measured ~= 64 or not measured:match("^[0-9a-f]+$") then return nil end
    return measured
end

-- Activation approvals bind the destination's freshly measured immutable
-- intent.
local function activation(value: unknown): (Object?, string?)
    local item = object(value)
    if not item then return nil, "activation intent is not an object" end
    local result: Object = {workspace_id = bounds.id(item.workspace_id), overlay_owner = bounds.id(item.overlay_owner),
        source_node = bounds.id(item.source_node), source_workspace = bounds.id(item.source_workspace),
        version = bounds.id(item.version), authorization_digest = hex(item.authorization_digest),
        artifact_digest = hex(item.artifact_digest), resolution_digest = hex(item.resolution_digest),
        preflight_digest = hex(item.preflight_digest), effect_key = bounds.id(item.effect_key),
        approval_id = bounds.id(item.approval_id), approval_proposal_digest = hex(item.approval_proposal_digest),
        owner_incarnation = bounds.count(item.approval_owner_incarnation)}
    if not result.workspace_id or not result.overlay_owner or not result.source_node or not result.source_workspace
        or not result.version or not result.authorization_digest or not result.artifact_digest
        or not result.resolution_digest or not result.preflight_digest or not result.effect_key then
        return nil, "activation intent identity is malformed"
    end
    if item.application_admission_digest ~= nil then
        result.application_admission_digest = hex(item.application_admission_digest)
        if not result.application_admission_digest then return nil, "activation application admission digest is malformed" end
    end
    if item.grant_predecessor_digest ~= nil then
        result.grant_predecessor_digest = hex(item.grant_predecessor_digest)
        if not result.grant_predecessor_digest then return nil, "activation predecessor digest is malformed" end
    end
    return result, nil
end

-- A tool is named to the person as agents see it, not by its function id.
local function with_aliases(line: string, tools: {[string]: string}?): string
    for id, alias in pairs(tools or {}) do
        local result = ""
        local rest = line
        while true do
            local from, to = rest:find(id, 1, true)
            if not from or not to then break end
            result = result .. rest:sub(1, from - 1) .. alias
            rest = rest:sub(to + 1)
        end
        line = result .. rest
    end
    return line
end

local function review_lines(raw: unknown, tools: {[string]: string}?): ({string}?, string?)
    if type(raw) ~= "table" then return nil, "capability review lines are invalid" end
    local result: {string} = {}
    if #raw > 24 then return nil, "capability review exceeds its bound" end
    for index, line in ipairs(raw) do
        local shown = bounds.text(line, 512)
        if not shown or shown == "" or shown:find("%c") then
            return nil, "capability review line is invalid"
        end
        result[index] = with_aliases(shown, tools)
    end
    return result, nil
end

-- The pending migrations as the person reviews them, bounded and in run
-- order.
local function migration_rows(raw: {Migration}?): ({Object}?, string?)
    if raw == nil then return {}, nil end
    if #raw > 128 then return nil, "pending migrations exceed their bound" end
    local rows: {Object} = {}
    for index, item in ipairs(raw) do
        local id, target = bounds.id(item.id), bounds.text(item.target_db, 160)
        if not id or not target or target == "" or target:find("%c") then return nil, "pending migration is malformed" end
        rows[index] = {id = id, target_db = target}
    end
    return rows, nil
end

function M.activation_proposal(value: unknown, review_raw: unknown?, migrations_raw: {Migration}?, shown: Presentation?): (Object?, string?)
    local item, intent_error = activation(value)
    if not item then return nil, intent_error end
    local payload: Object = {workspace_id = item.workspace_id, overlay_owner = item.overlay_owner,
        source_node = item.source_node, source_workspace = item.source_workspace,
        version = item.version, artifact_digest = item.artifact_digest,
        resolution_digest = item.resolution_digest, preflight_digest = item.preflight_digest,
        application_admission_digest = item.application_admission_digest}
    payload.grant_predecessor_digest = item.grant_predecessor_digest
    -- What the card names: the application or driver, who made it and where it
    -- came from.
    payload.title = shown and bounds.line(shown.title, 80) or nil
    payload.maker = shown and bounds.line(shown.maker, 160) or nil
    if type(item.overlay_owner) == "string" and (item.overlay_owner :: string):sub(1, #drivers.OWNER_PREFIX) == drivers.OWNER_PREFIX then
        payload.subject = "driver"
    end
    if review_raw ~= nil then
        local review = object(review_raw)
        local resolved, resolved_error = review and review_lines(review.resolved, shown and shown.tools) or nil
        local delta, delta_error = review and review_lines(review.delta, shown and shown.tools) or nil
        if not resolved or not delta or type(review.requires_approval) ~= "boolean" then
            return nil, resolved_error or delta_error or "capability review is invalid"
        end
        payload.resolved_capabilities = resolved
        payload.permission_changes = delta
    end
    local migrations, migrations_error = migration_rows(migrations_raw)
    if not migrations then return nil, migrations_error end
    if #migrations > 0 then payload.migrations = migrations end
    return {kind = "operation", ref = "bee.gov:establish-overlay",
        revision = item.authorization_digest, input_digest = item.authorization_digest,
        payload = payload}, nil
end

-- activation_prompt names what the person approves: the exact version, the
-- permissions it adds, and its scope and duration. A driver may declare a
-- login format for its own provider; approving it lets that driver's sessions
-- use the person's machine login for that provider.
local function activation_prompt(item: Object, changes: {string}?, migrations: {Object}, shown: Presentation?): string
    local subject = (shown and shown.title) or tostring(item.source_workspace)
    local login = ""
    if type(item.overlay_owner) == "string" and (item.overlay_owner :: string):sub(1, #drivers.OWNER_PREFIX) == drivers.OWNER_PREFIX then
        subject = "agent driver " .. tostring(item.source_workspace)
        login = " Its sessions may use your machine login for its own provider."
    end
    local maker = shown and shown.maker and shown.maker ~= "this bee" and (" (" .. shown.maker .. ")") or ""
    local permissions = " It adds no permissions."
    if changes and #changes > 0 then permissions = " It adds: " .. table.concat(changes, "; ") .. "." end
    local schema = ""
    if #migrations > 0 then
        local named: {string} = {}
        for index, row in ipairs(migrations) do
            if index > 8 then named[#named + 1] = "and " .. tostring(#migrations - 8) .. " more"; break end
            named[#named + 1] = tostring(row.id) .. " on " .. tostring(row.target_db)
        end
        schema = " It runs " .. tostring(#migrations) .. " database migration" .. (#migrations == 1 and "" or "s")
            .. ": " .. table.concat(named, "; ") .. ". Migrations change the database for good."
    end
    return "Install " .. subject .. " " .. tostring(item.version) .. maker .. "?" .. permissions .. schema .. login
        .. " Applies to this exact version in this workspace until replaced or removed."
end

function M.request_activation(executor: Executor, value: unknown, policy_raw: unknown, key_raw: unknown,
    review_raw: unknown?, migrations_raw: {Migration}?, presentation: Presentation?): (Object?, string?)
    local item, intent_error = activation(value)
    if not item then return nil, intent_error end
    local policy, key = bounds.id(policy_raw), bounds.id(key_raw)
    if not policy or not key then return nil, "approval policy and idempotency key are required" end
    local proposal, proposal_error = M.activation_proposal(value, review_raw, migrations_raw, presentation)
    if not proposal then return nil, proposal_error end
    local payload = object(proposal.payload)
    local changes = payload and payload.permission_changes
    local migrations = payload and bounds.array(payload.migrations or {}, 128) or {}
    local shown: {Object} = {}
    for _, raw in ipairs(migrations or {}) do
        local row = object(raw)
        if row then shown[#shown + 1] = row end
    end
    local raw, call_error = executor:call(REQUEST, {workspace_id = item.workspace_id,
        idempotency_key = key, request_kind = "permission", policy = policy, proposal = proposal,
        prompt = {text = activation_prompt(item, type(changes) == "table" and changes :: {string} or nil, shown, presentation)}})
    local approved, approved_error = reply(raw, call_error)
    if not approved then return nil, approved_error end
    local approval_id, proposal_digest = bounds.id(approved.approval_id), hex(approved.proposal_digest)
    local incarnation = bounds.count(approved.owner_incarnation)
    local recorded = object(approved.proposal)
    local recorded_bytes = recorded and canonical.encode(recorded) or nil
    local expected_bytes = canonical.encode(proposal)
    if not approval_id or not proposal_digest or not incarnation or incarnation < 1
        or not recorded_bytes or recorded_bytes ~= expected_bytes then
        return nil, "approval owner returned a request for another activation intent"
    end
    return {approval_id = approval_id, approval_proposal_digest = proposal_digest,
        owner_incarnation = incarnation}, nil
end

local function activation_effect(executor: Executor, method: string, value: unknown,
    incarnation_raw: unknown, expected_consumer_raw: unknown?): (Object?, Fault?)
    local item, intent_error = activation(value)
    if not item then return nil, {code = "INVALID", message = tostring(intent_error), value = nil} end
    local approval_id, proposal_digest = bounds.id(item.approval_id), hex(item.approval_proposal_digest)
    local incarnation = bounds.count(incarnation_raw)
    if not approval_id or not proposal_digest or not incarnation or incarnation < 1 then
        return nil, {code = "INVALID", message = "activation approval identity is malformed", value = nil}
    end
    local request: Object = {approval_id = approval_id, proposal_digest = proposal_digest,
        owner_incarnation = incarnation}
    if method == CONSUME then request.effect_key = item.effect_key end
    local raw, call_error = executor:call(method, request)
    local result, fault = typed_reply(raw, call_error)
    if not result then return nil, fault end
    if bounds.id(result.approval_id) ~= approval_id or hex(result.proposal_digest) ~= proposal_digest then
        return nil, {code = "CONFLICT", message = "approval owner returned another activation approval", value = result}
    end
    if method == CONSUME then
        local expected_consumer = bounds.id(expected_consumer_raw)
        if not expected_consumer or bounds.id(result.consumer_id) ~= expected_consumer
            or bounds.id(result.consumed_effect) ~= item.effect_key then
            return nil, {code = "CONFLICT", message = "approval consumption receipt does not match the activation effect", value = result}
        end
    elseif bounds.count(result.validated_incarnation) ~= incarnation then
        return nil, {code = "CONFLICT", message = "approval revalidation did not bind the requested incarnation", value = result}
    end
    return result, nil
end

function M.consume_activation(executor: Executor, value: unknown, expected_consumer: unknown,
    current_incarnation: unknown?): (Object?, Fault?)
    local item, intent_error = activation(value)
    if not item then return nil, {code = "INVALID", message = tostring(intent_error), value = nil} end
    return activation_effect(executor, CONSUME, value, current_incarnation or item.owner_incarnation, expected_consumer)
end

function M.revalidate_activation(executor: Executor, value: unknown, current_incarnation: unknown): (Object?, Fault?)
    return activation_effect(executor, REVALIDATE, value, current_incarnation, nil)
end

-- ending reads how the activation's approval request ended without approval:
-- denied, expired or withdrawn; nil while it is pending or approved.
function M.activation_ending(executor: Executor, value: unknown): (string?, string?)
    local item, intent_error = activation(value)
    if not item then return nil, intent_error end
    if not item.approval_id or not item.approval_proposal_digest then return nil, "activation has no approval request" end
    local raw, call_error = executor:call(READ, {approval_id = item.approval_id})
    local read, read_error = reply(raw, call_error)
    if not read then return nil, read_error end
    if bounds.id(read.approval_id) ~= item.approval_id or hex(read.proposal_digest) ~= item.approval_proposal_digest then
        return nil, "approval owner returned another activation approval"
    end
    if read.state == "expired" or read.state == "withdrawn" then return read.state, nil end
    if read.state == "decided" and read.decision == "denied" then return "denied", nil end
    return nil, nil
end

-- close_activation tells the approval owner the ended request is settled here.
function M.close_activation(executor: Executor, value: unknown): string?
    local item, intent_error = activation(value)
    if not item then return intent_error end
    local raw, call_error = executor:call(CLOSE, {approval_id = item.approval_id,
        proposal_digest = item.approval_proposal_digest})
    local _, close_error = reply(raw, call_error)
    return close_error
end

return M
