-- MIT. Decisions for the approvals authority.
local sql = require("sql")
local json = require("json")
local bounds = require("bounds")
local canonical = require("canonical")
local resources = require("resources")
local store = require("store")
local windows = require("windows")
local part_authority = require("part_authority")
local part_model = require("part_model")
local part_projections = require("part_projections")
local part_records = require("part_records")
local part_values = require("part_values")
local M = {}
type Result = part_model.Result
type Object = part_model.Object
local failure = part_values.failure
local refusal = part_values.refusal
local storage = part_values.storage
local success = part_values.success
local stamp = part_values.stamp
local text = part_values.text
local response_schema_bytes = part_values.response_schema_bytes
local decode_row = part_records.decode_row
local load = part_records.load
local authenticated_definition = part_authority.authenticated_definition
local eligible = part_authority.eligible
local settle = part_projections.settle
local expire_if_due = part_projections.expire_if_due
-- decide: an eligible approver settles the pending revision for the exact
-- proposal digest; an identical retry replays, anything else conflicts.
local function op_decide(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local unknown_field = bounds.fields(object, {"approval_id", "expected_revision", "decision", "proposal_digest", "response", "window_ttl_ms", "window_permanent", "reviewed_digest", "assurance"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local approval_id = bounds.id(object.approval_id)
    if not approval_id then return failure("INVALID_ARGUMENT", "approval_id is not an identifier") end
    local expected = bounds.integer(object.expected_revision)
    if not expected or expected < 1 then return failure("INVALID_ARGUMENT", "expected_revision must be a positive integer") end
    local declared_decision = bounds.member(object.decision, part_model.DECISIONS)
    if not declared_decision then return failure("INVALID_ARGUMENT", "decision kind is invalid") end
    local decision = (declared_decision == "deny" or declared_decision == "denied") and "denied" or "approved"
    local proposal_digest = text(object.proposal_digest)
    if not proposal_digest then return failure("INVALID_ARGUMENT", "proposal_digest is required") end
    local response: unknown = nil
    if object.response ~= nil then
        local encoded, content_error = canonical.encode(object.response, 8192)
        if not encoded then return failure("INVALID_ARGUMENT", "response: " .. tostring(content_error)) end
        response = object.response
    end
    local row, load_error = load(tx, approval_id)
    if load_error then return storage(load_error) end
    if not row then return failure("NOT_FOUND", "approval request does not exist") end
    if declared_decision == "answer" and row.request_kind ~= "question" then return failure("INVALID_ARGUMENT", "answer needs a question") end
    if declared_decision == "allow_once" and row.request_kind ~= "permission" then return failure("INVALID_ARGUMENT", "allow_once needs a permission") end
    local confirmation = row.proposal.ref == "bee.approvals:confirmation"
    if row.policy == "local-confirmation" and row.requester_id ~= actor then return failure("DENIED", "only the requesting instance confirms its local gesture") end
    local assurance = bounds.object(object.assurance)
    if object.assurance ~= nil then
        if not assurance or bounds.fields(assurance, {"kind", "gesture", "presentation"})
            or assurance.kind ~= "explicit_gesture"
            or not bounds.member(assurance.gesture, {"enter", "space", "click", "shortcut"})
            or assurance.presentation ~= row.contract.presentation then
            return failure("INVALID_ARGUMENT", "assurance must identify the explicit gesture and reviewed presentation")
        end
    end
    if confirmation and not assurance then return failure("INVALID_ARGUMENT", "confirmation requires an explicit gesture") end
    if confirmation and (object.window_ttl_ms ~= nil or object.window_permanent == true) then
        return failure("INVALID_ARGUMENT", "confirmations cannot create reusable grants")
    end
    local adapter, adapter_error = resources.has_grant_adapter(row.proposal)
    if adapter_error then return storage(adapter_error) end
    if adapter and (object.window_ttl_ms ~= nil or object.window_permanent == true) then return failure("INVALID_ARGUMENT","this proposal already reviews its domain grant terms") end
    if declared_decision == "allow_grant" and not adapter and object.window_ttl_ms == nil and object.window_permanent ~= true then return failure("INVALID_ARGUMENT", "allow_grant requires reviewed window terms") end
    local may_decide, policy_error = eligible(actor, row)
    if policy_error then return storage(policy_error) end
    if not may_decide then return failure("DENIED", "caller is not an eligible approver for this request") end
    local window_ttl: integer? = nil
    if object.window_permanent ~= nil and type(object.window_permanent) ~= "boolean" then return failure("INVALID_ARGUMENT", "window_permanent must be boolean") end
    if (object.window_permanent == true or object.window_ttl_ms ~= nil) and row.contract.reviewed_required == true then
        return failure("INVALID_ARGUMENT", "approval windows require the exact requester proposal scope")
    end
    if object.window_permanent == true then
        if object.window_ttl_ms ~= nil then return failure("INVALID_ARGUMENT", "choose duration or permanent") end
        local policies, policy_error = resources.policies()
        if not policies then return storage(policy_error or "approver policies") end
        local configured = policies[row.policy]
        if not configured or not configured.allow_permanent then return failure("FORBIDDEN", "policy does not permit permanent windows") end
        if decision ~= "approved" or row.request_kind ~= "permission" or response ~= nil then return failure("INVALID_ARGUMENT", "windows approve permissions without a response") end
        window_ttl = windows.PERMANENT_UNTIL_MS - now
    end
    if object.window_ttl_ms ~= nil then
        window_ttl = bounds.integer(object.window_ttl_ms)
        if not window_ttl or window_ttl < 1 then return failure("INVALID_ARGUMENT", "window_ttl_ms must be a positive integer") end
        if decision ~= "approved" or row.request_kind ~= "permission" or response ~= nil then return failure("INVALID_ARGUMENT", "windows approve permissions without a response") end
        if window_ttl > row.window_max_ttl_ms then return failure("FORBIDDEN", "window_ttl_ms exceeds the policy ceiling of " .. tostring(row.window_max_ttl_ms)) end
    end
    if row.proposal_digest ~= proposal_digest then return failure("CONFLICT", "proposal digest does not match the recorded proposal", part_records.view(row)) end
    if object.reviewed_digest ~= nil and object.reviewed_digest ~= row.reviewed_digest then
        return failure("CONFLICT", "reviewed digest does not match the recorded review", part_records.view(row))
    end
    local evidence = bounds.array(row.contract.evidence, 64)
    if (row.contract.reviewed_required == true or (evidence and #evidence > 0)) and object.reviewed_digest == nil then return failure("INVALID_ARGUMENT", "reviewed_digest is required for evidence-bound decisions") end
    if row.request_kind == "question" and decision == "approved" then
        if response == nil then return failure("INVALID_ARGUMENT", "a question needs a response to be approved") end
        local schema_json, encode_error = response_schema_bytes(row.response_schema)
        if not schema_json then return storage(encode_error or "encode response schema") end
        local valid, schema_error = json.validate(schema_json, response)
        if not valid or schema_error then return failure("INVALID_ARGUMENT", "answer does not match its response schema: " .. tostring(schema_error)) end
    end
    local current, expire_error, expired_now = expire_if_due(tx, row, now)
    if not current then return storage(expire_error or "expire approval request") end
    if current.state == "decided" then
        local wanted = ""
        if response ~= nil then wanted = canonical.encode(response) or "" end
        local same_response = wanted == (text(current.response_json) or "")
        local same_window = window_ttl == nil and current.window_grant == nil
            or (window_ttl ~= nil and current.window_grant ~= nil and current.allowed_by_grant == nil
                and (current.window_grant.until_ms - current.window_grant.granted_ms == window_ttl
                    or (object.window_permanent == true and current.window_grant.until_ms == windows.PERMANENT_UNTIL_MS)))
        if current.decider_id == actor and current.decision == decision and same_response and same_window then
            if assurance then
                local records = assert(bounds.array(current.lifecycle_records.decisions, 64))
                local record = records[1] and bounds.object(records[1])
                if not record or record.assurance_json ~= canonical.encode(assurance) then return failure("CONFLICT", "decision assurance differs", part_records.view(current)) end
            end
            return success(part_records.view(current), true)
        end
        return failure("CONFLICT", "request was decided " .. tostring(current.decision) .. " by " .. tostring(current.decider_id), part_records.view(current))
    end
    if expired_now then return refusal("INVALID_STATE", "request expired at its deadline", part_records.view(current)) end
    if current.state ~= "pending" then return failure("INVALID_STATE", "request is " .. tostring(current.state), part_records.view(current)) end
    if current.revision ~= expected then return failure("CONFLICT", "request is at revision " .. tostring(current.revision), part_records.view(current)) end
    if window_ttl then
        local grant_id = current.approval_id
        local scope_digest, scope_error = windows.scope_digest(current.proposal)
        if not scope_digest then return storage(scope_error or "measure approval window scope") end
        local matches, match_error = store.matching_windows(tx, current.owner_node, current.workspace_id, current.requester_id, current.policy, scope_digest)
        if not matches or match_error then return storage(match_error or "read approval window") end
        local reused = false
        if #matches > 0 then
            local previous, decode_error = windows.decode(matches[1])
            if not previous then return storage(decode_error or "decode approval window") end
            if not previous.revoked_at and previous.granted_by == actor and previous.granted_ms == now and previous.until_ms == now + window_ttl then
                grant_id = previous.grant_id
                reused = true
            end
        end
        if not reused then
            local grant: windows.Grant = {grant_id = grant_id, owner_node = current.owner_node, workspace_id = current.workspace_id,
                requester_id = current.requester_id, policy = current.policy, scope_digest = scope_digest,
                granted_by = actor, granted_definition = authenticated_definition(actor), granted_ms = now, granted_at = stamp(now),
                until_ms = now + window_ttl, until_at = stamp(now + window_ttl), revoked_at = nil}
            local supersede_error = store.supersede_windows(tx, grant)
            if supersede_error then return storage(supersede_error) end
            local grant_error = store.insert_window(tx, grant)
            if grant_error then return storage(grant_error) end
        end
        local attach_error = store.attach_window(tx, current.approval_id, grant_id, false)
        if attach_error then return storage(attach_error) end
    end
    local settled, settle_error = settle(tx, current, "decided", decision, actor, response, actor, "decided " .. decision, now)
    if not settled then return storage(settle_error or "settle decision") end
    if assurance then
        local _, assurance_error = tx:execute("UPDATE bee_approval_decisions SET assurance_json = ? WHERE approval_id = ? AND revision = ?",
            {canonical.encode(assurance), settled.approval_id, settled.revision})
        if assurance_error then return storage("record decision assurance") end
        local refreshed, refresh_error = load(tx, settled.approval_id)
        if not refreshed then return storage(refresh_error or "read confirmation decision") end
        settled = refreshed
    end
    return success(part_records.view(settled), false)
end
-- decide_batch: several pending requests of one requester in one workspace are
-- decided together in a single transaction. Every item carries exactly the
-- fields decide requires; the grouping is read from the stored rows, so a
-- mixed batch is refused before any decision commits and one failing item
-- rolls the whole batch back.
local function op_decide_batch(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local unknown_field = bounds.fields(object, {"decisions", "window_ttl_ms"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local items = bounds.dense_list(object.decisions, part_model.MAX_BATCH, "decisions")
    if not items or #items < 1 then return failure("INVALID_ARGUMENT", "decisions must list 1 to " .. tostring(part_model.MAX_BATCH) .. " requests") end
    local seen: {[string]: boolean} = {}
    local requester: string? = nil
    local workspace: string? = nil
    for _, raw in ipairs(items) do
        local item = bounds.object(raw)
        local approval_id = item and bounds.id(item.approval_id) or nil
        if not item or not approval_id then return failure("INVALID_ARGUMENT", "every decision names an approval_id") end
        if seen[approval_id] then return failure("INVALID_ARGUMENT", "a request appears once per batch") end
        seen[approval_id] = true
        local row, load_error = load(tx, approval_id)
        if load_error then return storage(load_error) end
        if not row then return failure("NOT_FOUND", "approval request does not exist") end
        if requester == nil then requester, workspace = row.requester_id, row.workspace_id end
        if row.requester_id ~= requester or row.workspace_id ~= workspace then
            return failure("INVALID_ARGUMENT", "a batch decides requests of one requester in one workspace")
        end
    end
    local views: {unknown} = {}
    for _, raw in ipairs(items) do
        local decision = bounds.object(raw)
        if not decision then return failure("INVALID_ARGUMENT", "decision must be an object") end
        if object.window_ttl_ms ~= nil then
            if decision.window_ttl_ms ~= nil then return failure("INVALID_ARGUMENT", "a batch has one window choice") end
            local copied: Object = {}
            for key, value in pairs(decision) do copied[key] = value end
            copied.window_ttl_ms = object.window_ttl_ms
            decision = copied
        end
        local settled = op_decide(tx, actor, decision, now, prepared)
        if not settled.ok then
            local fault = bounds.object(raw)
            return failure(settled.code or "INTERNAL", tostring(fault and fault.approval_id) .. ": " .. tostring(settled.message), bounds.object(settled.value))
        end
        views[#views + 1] = settled.value
    end
    return success({decisions = views}, false)
end
local function op_withdraw_origin(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local instance = bounds.id(object.instance_id)
    if bounds.fields(object, {"instance_id"}) or not instance then return failure("INVALID_ARGUMENT", "instance_id is required") end
    local _, closed_error = tx:execute("INSERT OR IGNORE INTO bee_approval_closed_origins(requester_id, instance_id, closed_at) VALUES (?, ?, ?)", {actor, instance, stamp(now)})
    if closed_error then return storage("close approval origin") end
    local rows, err = tx:query("SELECT * FROM bee_approval_requests WHERE requester_id = ? AND state = 'pending' AND json_extract(contract_json, '$.origin.instance_id') = ?", {actor, instance})
    if err or not rows then return storage("read pending origin approvals") end
    local requests: {Object} = {}
    for _, raw in ipairs(rows) do
        local row, decode_error = decode_row(raw, tx)
        if not row then return storage(decode_error or "decode origin approval") end
        local current, expire_error = expire_if_due(tx, row, now)
        if not current then return storage(expire_error or "expire origin approval") end
        if current.state == "pending" then
            local settled, settle_error = settle(tx, current, "withdrawn", nil, nil, nil, actor, "requester transport closed", now)
            if not settled then return storage(settle_error or "withdraw origin approval") end
            current = settled
        end
        requests[#requests + 1] = part_records.view(current)
    end
    return success({requests = requests}, false)
end
-- withdraw: the requester ends its own pending request; a request already
-- settled reports the outcome that actually committed.
local function op_withdraw(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local unknown_field = bounds.fields(object, {"approval_id", "expected_revision", "proposal_digest", "reviewed_digest"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local approval_id = bounds.id(object.approval_id)
    if not approval_id then return failure("INVALID_ARGUMENT", "approval_id is not an identifier") end
    local row, load_error = load(tx, approval_id)
    if load_error then return storage(load_error) end
    if not row then return failure("NOT_FOUND", "approval request does not exist") end
    if row.requester_id ~= actor then return failure("DENIED", "only the requester withdraws a request") end
    local expected = bounds.integer(object.expected_revision)
    if not expected or expected < 1 or not bounds.id(object.proposal_digest) then return failure("INVALID_ARGUMENT", "withdraw requires expected_revision and proposal_digest") end
    if object.proposal_digest ~= row.proposal_digest or ((row.contract.reviewed_required == true or object.reviewed_digest ~= nil) and object.reviewed_digest ~= row.reviewed_digest) then return failure("CONFLICT", "withdraw review differs from the request", part_records.view(row)) end
    local current, expire_error = expire_if_due(tx, row, now)
    if not current then return storage(expire_error or "expire approval request") end
    if current.state ~= "pending" then return success({withdrawn = false, request = part_records.view(current)}, current.state == "withdrawn") end
    if expected ~= current.revision then return failure("CONFLICT", "withdraw revision differs from the pending request", part_records.view(current)) end
    local settled, settle_error = settle(tx, current, "withdrawn", nil, nil, nil, actor, "withdrawn by the requester", now)
    if not settled then return storage(settle_error or "withdraw request") end
    return success({withdrawn = true, request = part_records.view(settled)}, false)
end
M.op_decide = op_decide
M.op_decide_batch = op_decide_batch
M.op_withdraw = op_withdraw
M.op_withdraw_origin = op_withdraw_origin
return M
