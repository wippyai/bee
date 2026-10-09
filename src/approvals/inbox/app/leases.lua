local json = require("json")
local hash = require("hash")
local grants = require("grants")
local clock = require("clock")
local bounds = require("bounds")
local model = require("model")
local M = {}
M.MAX_MARKS = 16
M.MAX_EXTRAS = 8
M.MAX_TTL_SECONDS = 86400 * 30
M.FACADE = "bee.gov.binding:destination_call"
M.BATCH = "bee.approvals.binding:decide_batch"
M.PROPOSAL = "bee.gov:grant-lease"
M.ACTIVATION = "bee.gov:establish-overlay"
type Object = {[string]: unknown}
type Extra = {capability: string, parameters: {[string]: string}}
type Spec = {ttl_seconds: integer?, max_applies: integer?, extras: {Extra}}
type Row = {grant_id: string, lease_id: string, source: string, workspace_id: string, target: string, state: string,
    applies_used: integer, max_applies: integer?, expires_at: string?, revision: integer,
    granted_by: string, uses: integer, reserved: integer, envelope_lines: {string}}
type Slice = {rows: {[string]: Row}, selected: string?, leases_view: boolean, marked: {[string]: boolean}, notice: string,
    review_for: string, review_offset: integer, review_complete: boolean}
type Intent = {target: string, request: Object, source: string}

function M.new(): Slice
    local slice: Slice = {rows = {}, selected = nil, leases_view = false, marked = {}, notice = "", review_for = "", review_offset = 0, review_complete = false}
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

-- A pending lease approval opens as a full review: every term and every
-- grant of the ceiling, wrapped and scrollable, and Approve waits until the
-- last line has been on screen.
function M.is_review(view: model.ApprovalView?): boolean
    return view ~= nil and view.state == "pending" and view.proposal.ref == M.PROPOSAL
end

function M.review_lines(view: model.ApprovalView, width: integer): {string}
    local lines: {string} = {"Requester: " .. view.requester_id .. "  policy " .. view.policy,
        "This request expires " .. view.expires_at .. " (the lease's own term is below)"}
    for _, line in ipairs(model.permission_lines(view)) do lines[#lines + 1] = line end
    local wrapped: {string} = {}
    local room = math.floor(math.max(10, width - 4))
    for _, line in ipairs(lines) do
        local rest = line
        repeat
            local cut = #rest <= room and #rest or room
            if #rest > room then
                local space = rest:sub(1, room):match(".*()%s")
                if space and space > 1 then cut = space end
                while cut < #rest and cut > 1 and rest:byte(cut + 1) and rest:byte(cut + 1) >= 0x80 and rest:byte(cut + 1) < 0xC0 do cut = cut - 1 end
            end
            wrapped[#wrapped + 1] = rest:sub(1, cut)
            rest = rest:sub(cut + 1):gsub("^%s+", "")
        until rest == ""
    end
    return wrapped
end

-- review_frame: the window of lines on screen for this view and whether the
-- whole review has now been seen; opening another request starts over.
function M.review_frame(slice: Slice, view: model.ApprovalView, total: integer, visible: integer): (integer, boolean)
    local identity = view.approval_id .. "#" .. tostring(view.revision)
    if slice.review_for ~= identity then slice.review_for, slice.review_offset, slice.review_complete = identity, 0, false end
    local top = math.floor(math.max(0, math.min(slice.review_offset, total - visible)))
    slice.review_offset = top
    if top + visible >= total then slice.review_complete = true end
    return top, slice.review_complete
end

function M.review_scroll(slice: Slice, delta: integer)
    slice.review_offset = math.floor(math.max(0, slice.review_offset + delta))
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

function M.grant_intent(view: model.ApprovalView, key: string): (Intent?, string?)
    local payload = payload_of(view,M.PROPOSAL)
    if not payload or view.state ~= "decided" or view.decision ~= "approved" then return nil,"open an approved lease request" end
    local approval = view.source_approval_id or view.approval_id
    local lease_id = "lease-" .. assert(hash.sha256("bee.gov.lease_grant\n" .. approval))
    return {target = "bee.approvals.binding:grant",source = view.workspace_id,request = {operation = "read",grant_id = grants.identity("governance_lease",view.owner_node,view.workspace_id,lease_id)}},nil
end
function M.list_intent(source: string, workspace_id: string): Intent
    return {target = "bee.approvals.binding:grant",source = source,request = {operation = "list",workspace_id = workspace_id}}
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
    for _, raw in ipairs(envelope) do
        local grant = bounds.object(raw)
        if grant and #lines < 8 then
            local scope = json.encode(grant.scope) or "{}"
            lines[#lines + 1] = model.text(tostring(grant.capability) .. " " .. tostring(scope), model.LINE_LIMIT)
        end
    end
    return lines
end

local function decode_row(source: string, workspace_id: string, raw: unknown): Row?
    local grant = grants.decode(raw)
    if not grant or grant.domain ~= "governance_lease" then return nil end
    local target, lease = bounds.id(grant.metadata.target),bounds.id(grant.metadata.lease_id)
    local parameters = bounds.object(grant.scope.parameters)
    if not target or not lease or not parameters then return nil end
    return {grant_id = grant.grant_id,lease_id = lease,source = source,workspace_id = workspace_id,target = target,state = grant.state,
        applies_used = grant.used + grant.reserved,max_applies = grant.max_uses,expires_at = grant.until_ms and clock.stamp(grant.until_ms),revision = grant.revision,
        granted_by = grant.granted_by,uses = grant.used + grant.reserved,reserved = grant.reserved,envelope_lines = envelope_lines(parameters.envelope)}
end
function M.apply_list(slice: Slice, source: string, workspace_id: string, raw: unknown): string?
    local failure = fault(raw)
    if failure then return failure end
    local value = bounds.object((raw).value)
    local listed = value and value.grants
    if type(listed) ~= "table" then return "INVALID_REPLY: grant list is malformed" end
    for key, row in pairs(slice.rows) do if row.source == source then slice.rows[key] = nil end end
    for _, item in ipairs(listed) do
        local row = decode_row(source,workspace_id,item)
        if not row then return "INVALID_REPLY: a grant row is malformed" end
        slice.rows[source .. "/" .. row.lease_id] = row
    end
    if slice.selected and not slice.rows[slice.selected] then slice.selected = nil end
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
    return slice.rows[slice.selected]
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

-- A lease is revocable while it is active, or while a reservation of an
-- exhausted or expired one still awaits admission.
function M.revocable(row: Row): boolean
    if row.state == "active" then return true end
    return (row.state == "exhausted" or row.state == "expired") and row.reserved > 0
end

function M.revoke_intent(slice: Slice, key: string): (Intent?, string?)
    local row = M.selected(slice)
    if not row then return nil, "select a lease to revoke" end
    if not M.revocable(row) then return nil, "the lease is " .. row.state end
    return {target = "bee.approvals.binding:grant",source = row.source,request = {operation = "revoke",grant_id = row.grant_id,expected_revision = row.revision}},nil
end

function M.notice(kind: string, raw: unknown): string
    local failure = fault(raw)
    if failure then return failure end
    if kind == "lease_propose" then return "Lease request filed; approval creates its Grant" end
    if kind == "lease_grant" then return "Lease granted" end
    return "Lease revoked"
end

-- toggle_mark: one pending request joins or leaves the batch. A batch holds
-- requests of one requester in one workspace, which the owner also checks.
function M.toggle_mark(slice: Slice, rows: {[string]: model.Row}, approval_id: string): string?
    local row = rows[approval_id]
    if not row or row.state ~= "pending" then return "only a pending request can join a batch" end
    if row.view.proposal.ref == M.PROPOSAL then return "a lease request is reviewed and decided on its own" end
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
            proposal_digest = row.view.proposal_digest, reviewed_digest = row.view.reviewed_digest, decision = chosen}
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
    for _, raw in ipairs(views) do
        local view = model.decode_view(raw)
        if view then fold(view); decided = decided + 1 end
    end
    slice.marked = {}
    return "Decided " .. tostring(decided) .. " requests"
end

return M
