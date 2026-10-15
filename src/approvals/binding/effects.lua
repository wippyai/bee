-- MIT. Effects for the approvals authority.
local sql = require("sql")
local hash = require("hash")
local security = require("security")
local bounds = require("bounds")
local canonical = require("canonical")
local resources = require("resources")
local store = require("store")
local grants = require("grants")
local lifecycle = require("lifecycle")
local part_authority = require("part_authority")
local part_model = require("part_model")
local part_projections = require("part_projections")
local part_records = require("part_records")
local part_values = require("part_values")
local M = {}
type Result = part_model.Result
type Object = part_model.Object
type Row = part_model.Row
local failure = part_values.failure
local refusal = part_values.refusal
local storage = part_values.storage
local success = part_values.success
local stamp = part_values.stamp
local text = part_values.text
local load = part_records.load
local incarnation = part_authority.incarnation
local authenticated_definition = part_authority.authenticated_definition
local eligible = part_authority.eligible
local settle = part_projections.settle
-- The effect owner's view of an approved decision under the current
-- authority: the caller must hold the consume action, name the exact
-- proposal digest and present the incarnation it observed. An observation
-- of an older authority, or a decision made under one that no effect owner
-- has validated against the current one, asks for revalidation and changes
-- nothing; the reply names the current incarnation to validate against.
local function effect_view(tx: sql.Transaction, actor: string, object: Object, now: integer): (Row?, integer?, Result?)
    local approval_id = bounds.id(object.approval_id)
    if not approval_id then return nil, nil, failure("INVALID_ARGUMENT", "approval_id is not an identifier") end
    local proposal_digest = text(object.proposal_digest)
    if not proposal_digest then return nil, nil, failure("INVALID_ARGUMENT", "proposal_digest is required") end
    local observed = bounds.integer(object.owner_incarnation)
    if not observed or observed < 1 then return nil, nil, failure("INVALID_ARGUMENT", "owner_incarnation must be the incarnation the effect owner observed") end
    local row, load_error = load(tx, approval_id)
    if load_error then return nil, nil, storage(load_error) end
    if not row then return nil, nil, failure("NOT_FOUND", "approval request does not exist") end
    if not security.can(part_model.CONSUME, text(row.workspace_id) or "") then return nil, nil, failure("DENIED", "caller is not an effect owner for workspace " .. tostring(row.workspace_id)) end
    if row.proposal_digest ~= proposal_digest or (object.reviewed_digest ~= nil and object.reviewed_digest ~= row.reviewed_digest) then return nil, nil, failure("CONFLICT", "effect digest does not match the recorded review", part_records.view(row)) end
    local scope = bounds.object(row.contract.scope)
    local scope_type = scope and bounds.id(scope.type) or nil
    if not scope or not scope_type then return nil, nil, storage("approval scope is corrupt") end
    local registered, scope_error = resources.scope(scope_type)
    if not registered then return nil, nil, failure("INVALID_STATE", scope_error or "scope adapter is unavailable") end
    if row.contract_version == lifecycle.VERSION and (scope.adapter_version ~= registered.version or scope.adapter_digest ~= registered.digest) then
        return nil, nil, failure("INVALID_STATE", "reviewed scope adapter changed", part_records.view(row))
    end
    local owner = text(row.owner_node)
    if not owner then return nil, nil, storage("approval request has no owner node") end
    local current, unavailable = incarnation(tx, owner)
    if not current then return nil, nil, unavailable end
    if observed ~= current then
        return nil, nil, failure("REVALIDATE", "authority incarnation is " .. tostring(current) .. ", not " .. tostring(observed), {request = part_records.view(row), current_incarnation = current})
    end
    if row.state ~= "decided" or row.decision ~= "approved" then return nil, nil, failure("INVALID_STATE", "request is not approved", part_records.view(row)) end
    return row, current, nil
end
-- revalidate: after an authority restart the effect owner re-checks the
-- decision in its own domain and records that it holds under the current
-- incarnation; consumption under that incarnation is then possible.
local function op_revalidate(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local unknown_field = bounds.fields(object, {"approval_id", "proposal_digest", "owner_incarnation", "reviewed_digest"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local row, current, refused = effect_view(tx, actor, object, now)
    if not row or not current then return refused or storage("read approval request") end
    if row.validated_incarnation == current then return success(part_records.view(row), true) end
    local update_error = store.validate_effect(tx, row.approval_id, current, actor, stamp(now))
    if update_error then return storage("record validation") end
    local updated = load(tx, text(row.approval_id) or "")
    if not updated then return storage("read approval request") end
    return success(part_records.view(updated), false)
end
-- consume: the effect owner binds an approved decision to one effect
-- identity. A decision made under an earlier authority incarnation must
-- have been revalidated under the current one first.
local function op_consume(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local unknown_field = bounds.fields(object, {"approval_id", "proposal_digest", "effect_key", "owner_incarnation", "reviewed_digest"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local effect_key = bounds.id(object.effect_key)
    if not effect_key then return failure("INVALID_ARGUMENT", "effect_key is not an identifier") end
    local row, current, refused = effect_view(tx, actor, object, now)
    if not row or not current then return refused or storage("read approval request") end
    if row.owner_incarnation ~= current and row.validated_incarnation ~= current then
        return failure("REVALIDATE", "decision was made under authority incarnation " .. tostring(row.owner_incarnation) .. "; validate it under " .. tostring(current), {request = part_records.view(row), current_incarnation = current})
    end
    local consumed = text(row.consumed_effect)
    if consumed then
        if consumed == effect_key and row.consumer_id == actor then return success(part_records.view(row), true) end
        return failure("CONFLICT", "approval was consumed by " .. tostring(row.consumer_id) .. " for effect " .. consumed, part_records.view(row))
    end
    local authority: grants.Grant? = nil
    if row.request_kind == "permission" and row.proposal.ref ~= "bee.approvals:confirmation" then
        local records, grant_error = tx:query("SELECT * FROM bee_approval_grants WHERE approval_id = ? OR grant_id = ?",{row.approval_id,row.allowed_by_grant or (row.window_grant and row.window_grant.grant_id) or sql.NULL})
        if not records or grant_error then return storage("read effect grant") end
        if #records ~= 1 then return failure("INVALID_STATE","effect has no unique grant") end
        local decoded, invalid = grants.decode(records[1])
        authority = decoded
        if not authority then return storage(invalid or "invalid effect grant") end
        local context_error = grants.observe(tx,authority)
        if context_error then return storage(context_error) end
        local authority_state = grants.state(authority,now)
        if authority_state ~= "active" and not (authority_state == "exhausted" and authority.reserved > 0) then return failure("INVALID_STATE","effect grant is " .. authority_state) end
    end
    if row.effect_admission_ms and row.effect_admission_ms <= now then return failure("INVALID_STATE", "effect admission deadline has passed", part_records.view(row)) end
    local bound_effect = row.effect
    if bound_effect.state ~= "authorized" and bound_effect.state ~= "reserved" then return failure("INVALID_STATE", "effect is not authorized", part_records.view(row)) end
    local bound = (row.contract_version ~= 1 and bound_effect.destination ~= nil) or bound_effect.state == "reserved"
    if bound and bound_effect.effect_id ~= effect_key then return failure("CONFLICT", "effect identity differs from the reviewed continuation or reservation", part_records.view(row)) end
    if authority and (authority.domain == "decision" or authority.domain == "approval_window") then
        local use_key = authority.domain == "approval_window" and (row.approval_id .. ":" .. effect_key) or effect_key
        local digest = assert(hash.sha256(assert(canonical.encode(row.contract.scope))))
        local uses = assert(tx:query("SELECT state FROM bee_approval_grant_uses WHERE grant_id = ? AND effect_key = ?",{authority.grant_id,use_key}))
        local operation = #uses == 1 and uses[1].state == "reserved" and "admit" or "consume"
        local admitted, err = grants.use(tx,authority,operation,use_key,digest,authority.revision,actor,now)
        if admitted == nil then return failure(err and err:match("^(%u+):") or "STORAGE",err or "effect grant admission denied") end
    end
    local lifecycle_error = lifecycle.consume(tx, row.approval_id, actor, effect_key, current, stamp(now), bound)
    if lifecycle_error then return storage(lifecycle_error) end
    local update_error = store.consume(tx, row.approval_id, actor, effect_key, stamp(now))
    if update_error then return storage("record consumption") end
    local updated = load(tx, text(row.approval_id) or "")
    if not updated then return storage("read approval request") end
    return success(part_records.view(updated), false)
end
local function op_end(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local extra = bounds.fields(object, {"approval_id", "expected_revision", "proposal_digest", "reviewed_digest", "outcome", "reason"})
    if extra then return failure("INVALID_ARGUMENT", extra) end
    local approval_id, outcome = bounds.id(object.approval_id), bounds.member(object.outcome, {"superseded", "invalidated"})
    if not approval_id or not outcome then return failure("INVALID_ARGUMENT", "approval_id and terminal outcome are required") end
    local row, err = load(tx, approval_id)
    if err then return storage(err) end
    if not row then return failure("NOT_FOUND", "approval request does not exist") end
    if row.requester_id ~= actor and not security.can(part_model.MANAGE, row.workspace_id) then return failure("DENIED", "caller cannot end this request") end
    local expected = bounds.integer(object.expected_revision)
    if not expected or object.proposal_digest ~= row.proposal_digest or ((row.contract.reviewed_required == true or object.reviewed_digest ~= nil) and object.reviewed_digest ~= row.reviewed_digest) then return failure("CONFLICT", "terminal review differs", part_records.view(row)) end
    if row.state ~= "pending" then return success(part_records.view(row), true) end
    if row.revision ~= expected then return failure("CONFLICT", "terminal revision differs", part_records.view(row)) end
    local reason = object.reason == nil and outcome or bounds.text(object.reason, 4096)
    if not reason then return failure("INVALID_ARGUMENT", "reason must be bounded text") end
    local settled, settle_error = settle(tx, row, outcome, nil, nil, nil, actor, reason, now)
    if not settled then return storage(settle_error or "end request") end
    return success(part_records.view(settled), false)
end
local function op_effect(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local extra = bounds.fields(object, {"operation", "approval_id", "proposal_digest", "reviewed_digest", "effect_key", "owner_incarnation", "expected_revision", "state", "result"})
    if extra then return failure("INVALID_ARGUMENT", extra) end
    if object.operation == "claim" then
        return op_consume(tx, actor, {approval_id = object.approval_id, proposal_digest = object.proposal_digest,
            effect_key = object.effect_key, owner_incarnation = object.owner_incarnation, reviewed_digest = object.reviewed_digest}, now, nil)
    end
    local approval_id = bounds.id(object.approval_id)
    if not approval_id then return failure("INVALID_ARGUMENT", "approval_id is required") end
    local row, err = load(tx, approval_id)
    if err then return storage(err) end
    if not row then return failure("NOT_FOUND", "approval request does not exist") end
    local ended = row.effect.state == "canceled"
    local receiver = ended and type(row.effect.destination) == "string" and security.can(part_model.OWN, row.effect.destination)
    if not receiver and (not security.can(part_model.CONSUME, row.workspace_id) or (row.requester_id ~= actor and row.consumer_id ~= actor)) then return failure("DENIED", "caller does not own this effect") end
    if object.proposal_digest ~= row.proposal_digest or (object.reviewed_digest ~= nil and object.reviewed_digest ~= row.reviewed_digest) then return failure("CONFLICT", "effect review differs", part_records.view(row)) end
    local effect = row.effect
    if object.operation == "read" then return success(part_records.view(row), false) end
    if object.operation == "complete" then
        local receipt = bounds.object(object.result)
        local encoded, encode_error = canonical.encode(receipt, 8192)
        if not receipt or not encoded then return failure("INVALID_ARGUMENT", encode_error or "effect result is required") end
        local state = ended and "canceled" or bounds.member(object.state == nil and (receipt.ok == false and "failed" or "succeeded") or object.state, {"succeeded", "failed", "canceled", "uncertain"})
        if not state then return failure("INVALID_ARGUMENT", "completion requires a terminal effect state") end
        if row.effect_completed_at then
            if row.effect_result_json ~= encoded or effect.state ~= state then return failure("CONFLICT", "effect already has a different receipt", part_records.view(row)) end
            return success(part_records.view(row), true)
        end
        if not ended and (row.consumer_id ~= actor or row.consumed_effect ~= object.effect_key) then return failure("CONFLICT", "effect was not admitted by this receiver", part_records.view(row)) end
        if state == "uncertain" and effect.state == "uncertain" and canonical.encode(effect.receipt, 8192) == encoded then return success(part_records.view(row), true) end
        local completion_error: string? = nil
        if state == "uncertain" then
            completion_error = lifecycle.complete(tx, approval_id, state, encoded, stamp(now))
            if not completion_error then completion_error = lifecycle.ack_effect(tx, approval_id, stamp(now)) end
        else
            completion_error = store.complete_effect(tx, approval_id, stamp(now), encoded, stamp(now), state)
        end
        if not completion_error then
            completion_error = store.project_effect(tx, approval_id, row.workspace_id, row.revision, row.state,
                row.decision, actor, state, stamp(now))
            row.revision = row.revision + 1
        end
        if not completion_error and state ~= "uncertain" then completion_error = lifecycle.completed(tx, row, state, receipt, stamp(now)) end
        if completion_error then return storage(completion_error) end
    elseif object.operation == "start" or object.operation == "reconcile" then
        local current, refused = incarnation(tx, row.owner_node)
        if not current then return refused or storage("read authority") end
        if object.owner_incarnation ~= current or (row.owner_incarnation ~= current and row.validated_incarnation ~= current) then return failure("REVALIDATE", "effect needs current incarnation validation", {request = part_records.view(row), current_incarnation = current}) end
        if effect.consumer_id ~= actor or row.consumed_effect ~= object.effect_key then return failure("CONFLICT", "effect is not admitted by this receiver") end
        local state = object.operation == "start" and "started" or bounds.member(object.state, {"started", "uncertain"})
        if not state then return failure("INVALID_ARGUMENT", "reconciliation state must be started or uncertain") end
        if effect.state == state then return success(part_records.view(row), true) end
        if object.expected_revision ~= effect.revision then return failure("CONFLICT", "effect revision differs", part_records.view(row)) end
        if effect.state ~= "admitted" and effect.state ~= "started" and effect.state ~= "uncertain" then return failure("INVALID_STATE", "effect cannot start or reconcile") end
        local _, update_error = tx:execute("UPDATE bee_approval_effects SET state = ?, revision = revision + 1, owner_incarnation = ?, updated_at = ? WHERE approval_id = ?", {state, current, stamp(now), approval_id})
        if update_error then return storage("update effect") end
    else return failure("INVALID_ARGUMENT", "effect operation must be read, claim, start, complete or reconcile") end
    local updated, update_error = load(tx, approval_id)
    if not updated then return storage(update_error or "read effect") end
    return success(part_records.view(updated), false)
end
local function op_grant(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local extra = bounds.fields(object, {"operation", "grant_id", "expected_revision", "subject", "scope", "effect_key", "owner_incarnation", "reviewed_digest", "workspace_id", "after_id", "after_revision"})
    if extra then return failure("INVALID_ARGUMENT", extra) end
    if object.operation == "list" then
        local workspace = bounds.id(object.workspace_id)
        local resource = workspace or "node"
        local after = object.after_id == nil and "" or bounds.id(object.after_id)
        if (object.workspace_id ~= nil and not workspace) or not after then return failure("INVALID_ARGUMENT","workspace_id or after_id is invalid") end
        local all = security.can("bee.approvals.grants",resource) or (workspace ~= nil and security.can(part_model.MANAGE,workspace))
        if not all and (not workspace or not security.can(part_model.DECIDE,workspace)) then return failure("DENIED","caller cannot list grants") end
        local rows, err = tx:query("SELECT * FROM bee_approval_grants WHERE (? IS NULL OR workspace_id = ?) AND (? = 1 OR granted_by = ? OR granted_definition = ? OR requester_id = ?) AND grant_id > ? ORDER BY grant_id LIMIT 65",{workspace or sql.NULL,workspace or sql.NULL,all and 1 or 0,actor,authenticated_definition(actor) or sql.NULL,actor,after})
        if not rows or err then return storage("list grants") end
        local more = #rows > 64
        if more then rows[65] = nil end
        local records: {Object} = {}
        for _, raw in ipairs(rows) do
            local record, invalid = grants.decode(raw)
            if not record then return storage(invalid or "invalid grant") end
            local context_error = grants.observe(tx,record)
            if context_error then return storage(context_error) end
            record.state = grants.state(record,now)
            records[#records + 1] = record
        end
        return success({grants = records,more = more,next_id = more and rows[#rows].grant_id or nil},false)
    end
    local id = bounds.id(object.grant_id)
    if not id then return failure("INVALID_ARGUMENT", "grant_id is required") end
    local rows, err = tx:query("SELECT * FROM bee_approval_grants WHERE grant_id = ?", {id})
    if not rows or err then return storage("read grant") end
    local grant = #rows == 1 and bounds.object(rows[1]) or nil
    if not grant then return failure("NOT_FOUND", "grant does not exist") end
    local record, invalid = grants.decode(grant)
    if not record then return storage(invalid or "grant is corrupt") end
    local context_error = grants.observe(tx,record)
    if context_error then return storage(context_error) end
    local definition = authenticated_definition(actor)
    local owns = record.requester_id == actor or record.granted_by == actor or (definition ~= nil and definition == record.granted_definition) or security.can(part_model.MANAGE,record.workspace_id) or security.can("bee.approvals.grants",record.workspace_id)
    if object.operation == "read" or object.operation == "history" then
        if not owns and not security.can("bee.approvals.grant.use",record.domain) then return failure("DENIED","caller cannot read this grant") end
        local after = object.after_revision == nil and 0 or bounds.integer(object.after_revision)
        if not after or after < 0 then return failure("INVALID_ARGUMENT","after_revision is invalid") end
        local history, err = tx:query("SELECT * FROM bee_approval_grant_history WHERE grant_id = ? AND revision > ? ORDER BY revision LIMIT 65",{id,after})
        if not history or err then return storage("read grant history") end
        local more = #history > 64
        if more then history[65] = nil end
        record.state = grants.state(record,now)
        return success({grant = record,history = history,more = more,next_revision = more and history[#history].revision or nil},false)
    end
    if object.operation == "revoke" then
        if not owns and record.approval_id then
            local source = load(tx,record.approval_id)
            if source then owns = eligible(actor,source) == true end
        end
        if not owns then return failure("DENIED","caller cannot revoke this grant") end
        if object.workspace_id ~= nil and object.workspace_id ~= record.workspace_id then return failure("DENIED","grant workspace differs") end
        if grant.state == "revoked" then return success(record,true) end
        local expected = bounds.integer(object.expected_revision)
        if not expected then return failure("INVALID_ARGUMENT","expected_revision is required") end
        local err = grants.revoke(tx,record,expected,actor,now)
        if err then return failure(err:match("^(%u+):") or "STORAGE",err) end
        if record.approval_id and record.domain ~= "approval_window" then
            local _, fence_error = tx:execute("UPDATE bee_approval_effects SET state = 'canceled',revision = revision + 1,updated_at = ? WHERE approval_id = ? AND state IN ('authorized','reserved')",{stamp(now),record.approval_id})
            if fence_error then return storage("fence revoked grant effect") end
            err = lifecycle.grant_revoked(tx,record.approval_id,record.requester_id,record.revision,stamp(now))
            if err then return storage(err) end
        end
        local view: Object = {}
        for key, item in pairs(record) do view[key] = item end
        local source = record.approval_id and load(tx,record.approval_id) or nil
        view.already_admitted = source ~= nil and source.consumed_effect ~= nil
        return success(view,false)
    end
    if grant.domain ~= "decision" and grant.domain ~= "approval_window" then
        local definition = authenticated_definition(actor)
        local owns = record.requester_id == actor or record.granted_by == actor or (definition ~= nil and definition == record.granted_definition) or security.can(part_model.MANAGE,record.workspace_id) or security.can("bee.approvals.grants",record.workspace_id) or security.can("bee.approvals.grant.use",record.domain)
        if not owns then return failure("DENIED","caller cannot administer this grant") end
        local subject, scope = canonical.encode(object.subject),canonical.encode(object.scope)
        if subject ~= grant.subject_json or scope ~= grant.scope_json then return failure("CONFLICT","grant subject or scope differs") end
        if object.operation == "check" then
            local state = grants.state(record,now)
            if state ~= "active" then return failure("INVALID_STATE","grant is " .. state,record) end
            return success(record,false)
        end
        local effect_key, expected = bounds.id(object.effect_key),bounds.integer(object.expected_revision)
        if not effect_key or not expected then return failure("INVALID_ARGUMENT","effect_key and expected_revision are required") end
        local use, use_error = grants.use(tx,record,tostring(object.operation),effect_key,assert(hash.sha256(scope)),expected,actor,now)
        if use == nil then return failure(use_error and use_error:match("^(%u+):") or "STORAGE",use_error or "grant use failed") end
        return success(record,use)
    end
    local approval_id = bounds.id(grant.approval_id)
    local row, row_error = approval_id and load(tx, approval_id) or nil, nil
    if not row then return storage(row_error or "grant source is missing") end
    if row.requester_id ~= actor or not security.can(part_model.CONSUME, row.workspace_id) then return failure("DENIED", "caller cannot use this grant") end
    local subject = canonical.encode(object.subject)
    local scope = canonical.encode(object.scope)
    if subject ~= grant.subject_json or scope ~= grant.scope_json then return failure("CONFLICT", "grant subject or exact scope differs") end
    local deadline = bounds.integer(grant.until_ms)
    if grant.state == "active" and deadline and deadline <= now then
        local expire_error = grants.expire(tx,record,now)
        if expire_error then return storage(expire_error) end
        return refusal("INVALID_STATE", "grant expired", {grant_id = id, state = "expired"})
    end
    if object.operation == "admit" then
        if row.consumed_effect == nil and object.expected_revision ~= grant.revision then return failure("CONFLICT", "grant revision differs", grant) end
        return op_consume(tx, actor, {approval_id = approval_id, proposal_digest = row.proposal_digest,
            effect_key = object.effect_key, owner_incarnation = object.owner_incarnation, reviewed_digest = object.reviewed_digest}, now, nil)
    end
    if grant.state ~= "active" then return failure("INVALID_STATE", "grant is " .. tostring(grant.state), grant) end
    if object.operation == "check" then return success(grant, false) end
    if object.expected_revision ~= grant.revision then return failure("CONFLICT", "grant revision differs", grant) end
    local state: string? = nil
    local effect_state = row.effect.state
    if object.operation == "reserve" then
        if effect_state == "reserved" and row.effect.effect_id == object.effect_key then return success(grant, true) end
        if effect_state ~= "authorized" then return failure("INVALID_STATE", "effect cannot reserve") end
        if row.contract_version ~= 1 and row.effect.destination ~= nil and row.effect.effect_id ~= object.effect_key then return failure("CONFLICT", "effect identity differs") end
        state = "reserved"
    elseif object.operation == "release" then
        if effect_state ~= "reserved" or row.effect.effect_id ~= object.effect_key then return failure("CONFLICT", "effect reservation differs") end
        state = "authorized"
    else return failure("INVALID_ARGUMENT", "grant operation must be check, reserve, admit, release or revoke") end
    local effect_key = bounds.id(object.effect_key)
    if not effect_key then return failure("INVALID_ARGUMENT", "effect_key is required") end
    local _, update_error = tx:execute("UPDATE bee_approval_effects SET effect_id = ?, state = ?, revision = revision + 1, updated_at = ? WHERE approval_id = ?", {effect_key, state, stamp(now), approval_id})
    if update_error then return storage("reserve or release effect") end
    local used, use_error = grants.use(tx,record,tostring(object.operation),effect_key,assert(hash.sha256(scope)),record.revision,actor,now)
    if used == nil then return failure(use_error and use_error:match("^(%u+):") or "STORAGE",use_error or "grant reservation failed") end
    local updated, read_error = tx:query("SELECT * FROM bee_approval_grants WHERE grant_id = ?", {id})
    if not updated or read_error then return storage("read updated grant") end
    return success(updated[1], false)
end
M.op_consume = op_consume
M.op_effect = op_effect
M.op_end = op_end
M.op_grant = op_grant
M.op_revalidate = op_revalidate
return M
