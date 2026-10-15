-- MIT. Leases for the approvals authority.
local sql = require("sql")
local hash = require("hash")
local security = require("security")
local bounds = require("bounds")
local canonical = require("canonical")
local store = require("store")
local runtime_lease = require("runtime_lease")
local windows = require("windows")
local grants = require("grants")
local part_authority = require("part_authority")
local part_effects = require("part_effects")
local part_model = require("part_model")
local part_records = require("part_records")
local part_values = require("part_values")
local M = {}
type Result = part_model.Result
type Object = part_model.Object
local failure = part_values.failure
local storage = part_values.storage
local success = part_values.success
local stamp = part_values.stamp
local node = part_values.node
local load = part_records.load
local incarnation = part_authority.incarnation
local authenticated_definition = part_authority.authenticated_definition
local op_consume = part_effects.op_consume
local function runtime_view(record: grants.Grant): Object
    local ceiling = bounds.object(record.metadata.ceiling) or {}
    return {grant_id = record.grant_id,lease_ref = record.metadata.lease_ref,subject = ceiling.subject,workspace_id = record.workspace_id,tool = ceiling.tool,input_digest = ceiling.input_digest,expires_ms = record.until_ms,max_uses = record.max_uses,revoked_at = record.revoked_at,used = record.used}
end
local function op_runtime_lease(tx: sql.Transaction, actor: string, request: Object, now: integer, prepared: Object?): Result
    if bounds.fields(request,{"operation","lease_ref","workspace_id","tool","input_digest","effect_key"}) then return failure("INVALID_ARGUMENT","runtime lease request has unknown fields") end
    local operation = bounds.member(request.operation,{"grant","check","use","revoke","list"})
    if not operation then return failure("INVALID_ARGUMENT","runtime lease operation is invalid") end
    if operation == "list" then
        local workspace = bounds.id(request.workspace_id)
        if not workspace or not security.can(part_model.CONSUME,workspace) then return failure("DENIED","runtime lease list needs workspace consume authority") end
        local rows, err = tx:query("SELECT * FROM bee_approval_grants WHERE domain = 'runtime_lease' AND requester_id = ? AND workspace_id = ? ORDER BY grant_id LIMIT 64",{actor,workspace})
        if not rows or err then return storage("list runtime grants") end
        local leases: {Object} = {}
        for _, raw in ipairs(rows) do
            local record, decode_error = grants.decode(raw)
            if not record then return storage(decode_error or "runtime grant is corrupt") end
            leases[#leases + 1] = runtime_view(record)
        end
        return success({leases = leases},false)
    end
    local ref = bounds.id(request.lease_ref)
    if not ref then return failure("INVALID_ARGUMENT","lease_ref is required") end
    local record, read_error = grants.read(tx,ref .. ":grant")
    if read_error then return storage(read_error) end
    if operation == "grant" then
        local source, err = load(tx,ref)
        if not source then return failure("NOT_FOUND",err or "lease source approval is missing") end
        local ceiling, invalid = runtime_lease.decode(source.proposal.payload)
        if source.proposal.ref ~= runtime_lease.REF or not ceiling then return failure("INVALID_ARGUMENT",invalid or "approval is not a runtime lease") end
        if actor ~= ceiling.subject or source.requester_id ~= actor or source.workspace_id ~= ceiling.workspace_id then return failure("DENIED","runtime lease belongs to another subject") end
        if not record then return failure("INVALID_STATE","runtime lease source is not approved") end
        local current, unavailable = incarnation(tx,source.owner_node)
        if not current then return unavailable or storage("runtime lease authority") end
        if source.owner_incarnation ~= current and source.validated_incarnation ~= current then return failure("REVALIDATE","runtime lease approval needs revalidation after restart",{current_incarnation = current}) end
        local consumed = op_consume(tx,actor,{approval_id = ref,proposal_digest = source.proposal_digest,effect_key = "runtime-lease:" .. ref,owner_incarnation = current},now,nil)
        if not consumed.ok then return consumed end
        if grants.state(record,now) ~= "active" then return failure("INVALID_STATE","runtime grant is " .. grants.state(record,now)) end
        return success({lease_ref = ref,grant_id = record.grant_id,ceiling = ceiling},consumed.replayed)
    end
    if not record or record.domain ~= "runtime_lease" then return failure("NOT_FOUND","runtime lease is missing") end
    local workspace = record.workspace_id
    if not security.can(part_model.CONSUME,workspace) then return failure("DENIED","runtime lease needs workspace consume authority") end
    if operation == "revoke" then
        if actor ~= record.requester_id and not security.can(part_model.MANAGE,workspace) then return failure("DENIED","runtime lease belongs to another subject") end
        local err = grants.revoke(tx,record,record.revision,actor,now)
        if err then return storage(err) end
        return success(runtime_view(record),false)
    end
    local ceiling = bounds.object(record.metadata.ceiling)
    if not ceiling then return storage("runtime grant ceiling is corrupt") end
    if actor ~= record.requester_id or request.workspace_id ~= workspace then return failure("DENIED","runtime lease subject or workspace differs") end
    if (request.tool ~= nil and request.tool ~= ceiling.tool) or (request.input_digest ~= nil and request.input_digest ~= ceiling.input_digest) then return failure("DENIED","runtime lease does not cover this exact tool input") end
    if operation == "check" then
        local state = grants.state(record,now)
        if state ~= "active" then return failure("DENIED","runtime grant is " .. state) end
        return success(runtime_view(record),false)
    end
    local effect = bounds.id(request.effect_key)
    if not effect or request.tool ~= ceiling.tool or request.input_digest ~= ceiling.input_digest then return failure("DENIED","runtime lease does not cover this exact tool input") end
    local digest = hash.sha256(assert(canonical.encode({subject = actor,workspace_id = workspace,tool = request.tool,input_digest = request.input_digest})))
    local previous, previous_error = tx:query("SELECT state FROM bee_approval_grant_uses WHERE grant_id = ? AND effect_key = ?",{record.grant_id,effect})
    if not previous or previous_error then return storage("read runtime grant receipt") end
    if #previous == 0 then
        local reserved, reserve_error = grants.use(tx,record,"reserve",effect,digest,record.revision,actor,now)
        if reserved == nil then return failure(reserve_error and reserve_error:match("^(%u+):") or "STORAGE",reserve_error or "reserve runtime grant") end
    end
    local admitted, admission_error = grants.use(tx,record,"admit",effect,digest,record.revision,actor,now)
    if admitted == nil then return failure(admission_error and admission_error:match("^(%u+):") or "STORAGE",admission_error or "admit runtime grant") end
    local view = runtime_view(record)
    view.consumed = true
    return success(view,admitted)
end
local function op_grant_window(tx: sql.Transaction, actor: string, request: Object, now: integer, prepared: Object?): Result
    local extra = bounds.fields(request, {"operation", "workspace_id", "grant_id", "after_id"})
    if extra then return failure("INVALID_ARGUMENT", extra) end
    local owner, node_error = node()
    if not owner then return failure("UNAVAILABLE", node_error or "native node identity is unavailable") end
    local definition = authenticated_definition(actor)
    if request.operation == "list" then
        local workspace = bounds.id(request.workspace_id)
        local after = request.after_id == nil and "" or bounds.id(request.after_id)
        if not workspace or after == nil then return failure("INVALID_ARGUMENT", "workspace_id and optional after_id must be identifiers") end
        if not security.can(part_model.DECIDE, workspace) then return failure("DENIED", "caller has no approval decision authority in this workspace") end
        local rows, err = store.active_windows(tx, owner, workspace, actor, definition, now, after)
        if not rows or err then return storage(err or "list active approval windows") end
        local grants: {windows.Grant} = {}
        local more = #rows > part_model.MAX_LIST
        for index, raw in ipairs(rows) do
            if index > part_model.MAX_LIST then break end
            local grant, decode_error = windows.decode(raw)
            if not grant then return storage(decode_error or "decode approval window") end
            grants[#grants + 1] = grant
        end
        return success({grants = grants, more = more, next_id = more and grants[#grants].grant_id or nil}, false)
    end
    if request.operation ~= "revoke" then return failure("INVALID_ARGUMENT", "operation must be list or revoke") end
    local id = bounds.id(request.grant_id)
    if not id then return failure("INVALID_ARGUMENT", "grant_id must be an identifier") end
    local raw, read_error = store.window(tx, id)
    if read_error then return storage(read_error) end
    if not raw then return failure("NOT_FOUND", "approval window does not exist") end
    local grant, decode_error = windows.decode(raw)
    if not grant then return storage(decode_error or "decode approval window") end
    if grant.owner_node ~= owner or not security.can(part_model.DECIDE, grant.workspace_id)
        or (request.workspace_id ~= nil and request.workspace_id ~= grant.workspace_id)
        or (actor ~= grant.granted_by and (not definition or definition ~= grant.granted_definition)) then return failure("DENIED", "caller does not own this node's approval window") end
    local revoke_error = store.revoke_window(tx, id, stamp(now))
    if revoke_error then return storage(revoke_error) end
    return success({grant_id = id, revoked = true}, grant.revoked_at ~= nil)
end
M.op_grant_window = op_grant_window
M.op_runtime_lease = op_runtime_lease
return M
