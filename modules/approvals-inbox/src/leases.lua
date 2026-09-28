-- MIT. The inbox's lease and batch slice, pure: a bounded spec grammar for a
-- lease request, the governance operations that propose, grant, list and
-- revoke it, the rows shown for active leases, and the marked set decided as
-- one batch. Decision authority stays with the approval and governance
-- owners; nothing here decides or grants.
local json = require("json")
local bounds = require("bounds")
local model = require("model")
local M = {}
M.MAX_MARKS = 16
M.MAX_LEASES = 256
M.MAX_EXTRAS = 8
M.MAX_TTL_SECONDS = 86400 * 30
M.FACADE = "bee.gov.binding:destination_call"
M.BATCH = "bee.approvals.binding:decide_batch"
M.PROPOSAL = "bee.gov:grant-lease"
M.ACTIVATION = "bee.gov:establish-overlay"
type Object = {[string]: unknown}
type Extra = {capability: string, parameters: {[string]: string}}
type Spec = {ttl_seconds: integer?, max_applies: integer?, extras: {Extra}}
type Row = {lease_id: string, source: string, workspace_id: string, target: string, state: string,
    applies_used: integer, max_applies: integer?, expires_at: string?, revision: integer,
    granted_by: string, uses: integer, envelope_lines: {string}}
type Slice = {rows: {[string]: Row}, selected: string?, leases_view: boolean, marked: {[string]: boolean}, notice: string}
type Intent = {target: string, request: Object, source: string}

function M.new(): Slice
    local slice: Slice = {rows = {}, selected = nil, leases_view = false, marked = {}, notice = ""}
    return slice
end

local UNITS: {[string]: integer} = {s = 1, m = 60, h = 3600, d = 86400}

local function duration(raw: string): integer?
    local amount_text, unit = raw:match("^(%d+)([smhd])$")
    if not amount_text or not unit then return nil end
    local scale: integer = UNITS[unit] or 0
    local amount: number = tonumber(amount_text) or 0
    local seconds = amount * scale
    if seconds < 1 or seconds > M.MAX_TTL_SECONDS then return nil end
    return math.floor(seconds)
end

-- parse_parameters: key=value pairs separated by commas, or nothing for a
-- capability that takes none. Values stay text; a value with | lists members
-- and the governance owner reads set-valued parameters from the catalog.
function M.parse_parameters(input: string): ({[string]: string}?, string?)
    if #input > 256 or input:find("%c") then return nil, "parameters are too long" end
    local parsed: {[string]: string} = {}
    local count = 0
    if not input:match("^%s*$") then
        for pair in input:gmatch("[^,]+") do
            local key, item = pair:match("^%s*([a-z_]+)%s*=%s*(.-)%s*$")
            if not key or not item or item == "" or parsed[key] ~= nil then return nil, "use key=value pairs, comma separated" end
            count = count + 1
            if count > 8 then return nil, "at most 8 parameters" end
            parsed[key] = item
        end
    end
    return parsed, nil
end

function M.capability_name(input: string): boolean
    return #input <= 160 and input:match("^[a-z][a-z0-9_.-]*$") ~= nil
end

-- spec: the form's values as one lease bound. ttl_seconds is a duration in
-- seconds or "none"; applies is empty or a whole number; each extra is a
-- capability with its parameter text.
function M.spec(ttl_seconds: string, applies: string, extras: {{capability: string, parameters: string}}): (Spec?, string?)
    local spec: Spec = {ttl_seconds = nil, max_applies = nil, extras = {}}
    if ttl_seconds ~= "none" then
        local seconds = tonumber(ttl_seconds)
        if not seconds or seconds < 1 or seconds > M.MAX_TTL_SECONDS then return nil, "expiry is out of range" end
        spec.ttl_seconds = math.floor(seconds)
    end
    if applies ~= "" then
        local count: number = tonumber(applies) or 0
        if count ~= math.floor(count) or count < 1 or count > 1000000 then return nil, "max applies is a positive whole number" end
        spec.max_applies = math.floor(count)
    end
    if not spec.ttl_seconds and not spec.max_applies then return nil, "a lease needs an expiry, a use limit, or both" end
    for _, extra in ipairs(extras) do
        if extra.capability ~= "" then
            if #spec.extras >= M.MAX_EXTRAS then return nil, "too many extras" end
            if not M.capability_name(extra.capability) then return nil, "capability is not an identifier" end
            local parameters, parameter_error = M.parse_parameters(extra.parameters)
            if not parameters then return nil, parameter_error end
            spec.extras[#spec.extras + 1] = {capability = extra.capability, parameters = parameters}
        end
    end
    return spec, nil
end

function M.select(slice: Slice, row: Row)
    slice.selected = row.source .. "/" .. row.lease_id
end
function M.show_leases(slice: Slice, shown: boolean)
    slice.leases_view = shown
end
function M.say(slice: Slice, text: string)
    slice.notice = text
end

local function payload_of(view: model.ApprovalView, ref: string): Object?
    if view.proposal.ref ~= ref then return nil end
    return view.proposal.payload
end

-- propose_intent: from the open pending activation request, ask governance
-- to file a lease approval for that application.
function M.propose_intent(view: model.ApprovalView, spec: Spec, key: string): (Intent?, string?)
    local payload = payload_of(view, M.ACTIVATION)
    if not payload or view.state ~= "pending" then return nil, "open a pending activation request to lease its application" end
    local workspace, node, source = bounds.id(payload.workspace_id), bounds.id(payload.source_node), bounds.id(payload.source_workspace)
    if not workspace or not node or not source then return nil, "the request does not name its application" end
    return {target = M.FACADE, source = view.workspace_id, request = {operation = "lease_propose", workspace_id = workspace,
        source_node = node, source_workspace = source, extras = spec.extras, ttl_seconds = spec.ttl_seconds,
        max_applies = spec.max_applies, idempotency_key = key}}, nil
end

-- grant_intent: the lease approval a person approved becomes a lease.
function M.grant_intent(view: model.ApprovalView, key: string): (Intent?, string?)
    local payload = payload_of(view, M.PROPOSAL)
    if not payload then return nil, "open an approved lease request to grant it" end
    if view.state ~= "decided" or view.decision ~= "approved" then return nil, "the lease request is not approved" end
    local workspace, node, source = bounds.id(payload.workspace_id), bounds.id(payload.source_node), bounds.id(payload.source_workspace)
    if not workspace or not node or not source then return nil, "the lease request does not name its application" end
    return {target = M.FACADE, source = view.workspace_id, request = {operation = "lease_grant", workspace_id = workspace,
        source_node = node, source_workspace = source, approval_id = view.source_approval_id or view.approval_id,
        idempotency_key = key}}, nil
end

function M.list_intent(source: string, workspace_id: string): Intent
    return {target = M.FACADE, source = source, request = {operation = "lease_list", workspace_id = workspace_id}}
end

local function fault(raw: unknown): string?
    local reply = bounds.object(raw)
    if not reply then return "no answer from governance" end
    if reply.ok == true then return nil end
    local detail = bounds.object(reply.error) or reply
    return model.text(tostring(detail.code or "FAILED") .. ": " .. tostring(detail.message or "governance refused the request"), model.LINE_LIMIT)
end

local function envelope_lines(envelope: unknown): {string}
    local lines: {string} = {}
    if type(envelope) ~= "table" then return lines end
    for _, raw in ipairs(envelope :: {unknown}) do
        local grant = bounds.object(raw)
        if grant and #lines < 8 then
            local scope = json.encode(grant.scope) or "{}"
            lines[#lines + 1] = model.text(tostring(grant.capability) .. " " .. tostring(scope), model.LINE_LIMIT)
        end
    end
    return lines
end

local function decode_row(source: string, workspace_id: string, raw: unknown): Row?
    local item = bounds.object(raw)
    if not item then return nil end
    local lease_id, target = bounds.id(item.lease_id), bounds.id(item.target)
    local used, revision = bounds.count(item.applies_used), bounds.count(item.revision)
    local state = type(item.state) == "string" and item.state or nil
    if not lease_id or not target or used == nil or not revision or not state then return nil end
    local max = item.max_applies == nil and nil or bounds.count(item.max_applies)
    local uses = type(item.uses) == "table" and #(item.uses :: {unknown}) or 0
    return {lease_id = lease_id, source = source, workspace_id = workspace_id, target = model.text(target, model.LINE_LIMIT),
        state = model.text(state, 20), applies_used = used, max_applies = max,
        expires_at = type(item.expires_at) == "string" and model.text(item.expires_at, 40) or nil,
        revision = revision, granted_by = model.text(item.granted_by, 200), uses = uses,
        envelope_lines = envelope_lines(item.envelope)}
end

-- apply_list: replace this source's rows with governance's answer.
function M.apply_list(slice: Slice, source: string, workspace_id: string, raw: unknown): string?
    local failure = fault(raw)
    if failure then return failure end
    local value = bounds.object((raw :: Object).value)
    local listed = value and value.leases
    if type(listed) ~= "table" or #(listed :: {unknown}) > M.MAX_LEASES then return "INVALID_REPLY: lease list is malformed" end
    for key, row in pairs(slice.rows) do if row.source == source then slice.rows[key] = nil end end
    for _, item in ipairs(listed :: {unknown}) do
        local row = decode_row(source, workspace_id, item)
        if not row then return "INVALID_REPLY: a lease row is malformed" end
        slice.rows[source .. "/" .. row.lease_id] = row
    end
    if slice.selected and not slice.rows[slice.selected :: string] then slice.selected = nil end
    return nil
end

function M.rows(slice: Slice): {Row}
    local list: {Row} = {}
    for _, row in pairs(slice.rows) do list[#list + 1] = row end
    table.sort(list, function(a: Row, b: Row): boolean
        local a_active, b_active = a.state == "active", b.state == "active"
        if a_active ~= b_active then return a_active end
        if a.target ~= b.target then return a.target < b.target end
        return a.lease_id < b.lease_id
    end)
    return list
end

function M.selected(slice: Slice): Row?
    if not slice.selected then return nil end
    return slice.rows[slice.selected :: string]
end

function M.move(slice: Slice, delta: integer)
    local list = M.rows(slice)
    if #list == 0 then slice.selected = nil; return end
    local index = 1
    for position, row in ipairs(list) do
        if slice.selected == row.source .. "/" .. row.lease_id then index = position end
    end
    index = math.floor(math.max(1, math.min(#list, index + delta)))
    slice.selected = list[index].source .. "/" .. list[index].lease_id
end

function M.revoke_intent(slice: Slice, key: string): (Intent?, string?)
    local row = M.selected(slice)
    if not row then return nil, "select a lease to revoke" end
    if row.state ~= "active" then return nil, "the lease is " .. row.state end
    return {target = M.FACADE, source = row.source, request = {operation = "lease_revoke", workspace_id = row.workspace_id,
        lease_id = row.lease_id, expected_revision = row.revision, idempotency_key = key}}, nil
end

-- notice: the person-facing outcome of a propose, grant or revoke answer.
function M.notice(kind: string, raw: unknown): string
    local failure = fault(raw)
    if failure then return failure end
    if kind == "lease_propose" then return "Lease request filed; approve it in the inbox, then grant it" end
    if kind == "lease_grant" then return "Lease granted" end
    return "Lease revoked"
end

-- toggle_mark: one pending request joins or leaves the batch. A batch holds
-- requests of one requester in one workspace, which the owner also checks.
function M.toggle_mark(slice: Slice, rows: {[string]: model.Row}, approval_id: string): string?
    local row = rows[approval_id]
    if not row or row.state ~= "pending" then return "only a pending request can join a batch" end
    if slice.marked[approval_id] then slice.marked[approval_id] = nil; return nil end
    local count = 0
    for id in pairs(slice.marked) do
        count = count + 1
        local other = rows[id]
        if other and (other.requester_id ~= row.requester_id or other.workspace_id ~= row.workspace_id) then
            return "a batch holds requests of one requester in one workspace"
        end
    end
    if count >= M.MAX_MARKS then return "a batch holds at most " .. tostring(M.MAX_MARKS) .. " requests" end
    slice.marked[approval_id] = true
    return nil
end

-- marked: the marked rows that are still pending, oldest first.
function M.marked(slice: Slice, rows: {[string]: model.Row}): {model.Row}
    local list: {model.Row} = {}
    for id in pairs(slice.marked) do
        local row = rows[id]
        if row and row.state == "pending" then list[#list + 1] = row else slice.marked[id] = nil end
    end
    table.sort(list, function(a: model.Row, b: model.Row): boolean
        if a.created_at ~= b.created_at then return a.created_at < b.created_at end
        return a.approval_id < b.approval_id
    end)
    return list
end

-- batch_intent: every marked request decided at the revision and digest the
-- viewer saw, in one owner transaction.
function M.batch_intent(slice: Slice, rows: {[string]: model.Row}, decision: string): (Intent?, string?)
    local chosen = bounds.member(decision, {"approved", "denied"})
    if not chosen then return nil, "decision must be approved or denied" end
    local marked = M.marked(slice, rows)
    if #marked == 0 then return nil, "mark pending requests with M first" end
    local decisions: {Object} = {}
    for _, row in ipairs(marked) do
        decisions[#decisions + 1] = {approval_id = row.approval_id, expected_revision = row.revision,
            proposal_digest = row.view.proposal_digest, decision = chosen}
    end
    return {target = M.BATCH, source = marked[1].workspace_id, request = {decisions = decisions}}, nil
end

-- apply_batch: the owner's answer. A success folds every committed view into
-- the model; a failure leaves the marks for a retry after a refresh.
function M.apply_batch(slice: Slice, reply: model.Reply?, fold: (model.ApprovalView) -> ()): string
    if not reply then return "The owner's answer is unknown; refresh to see what committed" end
    if reply.kind ~= "success" then
        local code = reply.code
        local message = reply.message
        return model.text(code .. ": " .. message, model.LINE_LIMIT)
    end
    local value = bounds.object(reply.value)
    local views = value and value.decisions
    if type(views) ~= "table" then return "INVALID_REPLY: batch result is malformed" end
    local decided = 0
    for _, raw in ipairs(views :: {unknown}) do
        local view = model.decode_view(raw)
        if view then fold(view); decided = decided + 1 end
    end
    slice.marked = {}
    return "Decided " .. tostring(decided) .. " requests"
end

return M
