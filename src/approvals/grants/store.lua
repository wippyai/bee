local sql = require("sql")
local json = require("json")
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local clock = require("clock")
local M = {}
type Object = {[string]: unknown}
type Grant = {grant_id: string, domain: string, owner_node: string, workspace_id: string, requester_id: string,
    granted_by: string, granted_definition: string?, subject: Object, scope: Object, terms: Object, provenance: Object,
    metadata: Object, state: string, revision: integer, used: integer, reserved: integer, until_ms: integer?, max_uses: integer?,
    created_at: string, approval_id: string?, decision_id: string?, revoked_at: string?, revoked_by: string?}
local function execute(tx: sql.Transaction, statement: string, args: {unknown}): string?
    local _, err = tx:execute(statement,args)
    return err and tostring(err) or nil
end
function M.identity(domain: string, owner: string, workspace: string, key: string): string
    return domain .. "-" .. assert(hash.sha256(assert(canonical.encode({owner = owner,workspace = workspace,key = key}))))
end
function M.state(grant: Grant, now: integer): string
    if grant.state == "revoked" then return "revoked" end
    if grant.until_ms and grant.until_ms <= now then return "expired" end
    if grant.max_uses and grant.used + grant.reserved >= grant.max_uses then return "exhausted" end
    return grant.state
end
function M.decode(raw: unknown): (Grant?, string?)
    local row = bounds.object(raw)
    if not row then return nil,"grant record is corrupt" end
    local id, domain, owner, workspace = bounds.id(row.grant_id),bounds.id(row.domain),bounds.id(row.owner_node),bounds.id(row.workspace_id)
    local requester, issuer = bounds.id(row.requester_id),bounds.id(row.granted_by)
    local state = bounds.member(row.state,{"active","revoked","expired","exhausted"})
    local revision, used, reserved = bounds.integer(row.revision),bounds.integer(row.used),bounds.integer(row.reserved)
    local subject = type(row.subject_json) == "string" and bounds.object(json.decode(row.subject_json)) or nil
    local scope = type(row.scope_json) == "string" and bounds.object(json.decode(row.scope_json)) or nil
    local terms = type(row.terms_json) == "string" and bounds.object(json.decode(row.terms_json)) or nil
    local provenance = type(row.provenance_json) == "string" and bounds.object(json.decode(row.provenance_json)) or nil
    local metadata = type(row.metadata_json) == "string" and bounds.object(json.decode(row.metadata_json)) or nil
    local created = bounds.timestamp(row.created_at)
    if not id or not domain or not owner or not workspace or not requester or not issuer or not state or not revision
        or revision < 1 or not used or used < 0 or not reserved or reserved < 0 or not subject or not scope or not terms
        or not provenance or not metadata or not created then return nil,"grant record is corrupt" end
    return {grant_id = id,domain = domain,owner_node = owner,workspace_id = workspace,requester_id = requester,
        granted_by = issuer,granted_definition = bounds.id(row.granted_definition),subject = subject,scope = scope,terms = terms,
        provenance = provenance,metadata = metadata,state = state,revision = revision,used = used,reserved = reserved,
        until_ms = bounds.integer(row.until_ms),max_uses = bounds.integer(row.max_uses),created_at = created,
        approval_id = bounds.id(row.approval_id),decision_id = bounds.id(row.decision_id),revoked_at = bounds.timestamp(row.revoked_at),revoked_by = bounds.id(row.revoked_by)},nil
end
function M.read(tx: sql.Transaction, id: string): (Grant?, string?)
    local rows, err = tx:query("SELECT * FROM bee_approval_grants WHERE grant_id = ?",{id})
    if not rows or err then return nil,"read grant: " .. tostring(err) end
    if #rows == 0 then return nil,nil end
    return M.decode(rows[1])
end
function M.history(tx: sql.Transaction, grant: Grant, kind: string, actor: string, body: Object, at: string): string?
    return execute(tx,"INSERT INTO bee_approval_grant_history(grant_id,revision,kind,actor_id,body_json,at) VALUES (?,?,?,?,?,?)",
        {grant.grant_id,grant.revision,kind,actor,canonical.encode(body),at})
end
function M.create(tx: sql.Transaction, grant: Grant): string?
    local err = execute(tx,[[INSERT INTO bee_approval_grants(grant_id,approval_id,decision_id,subject_json,scope_json,terms_json,state,revision,used,reserved,until_ms,max_uses,created_at,domain,owner_node,workspace_id,requester_id,granted_by,granted_definition,provenance_json,metadata_json,revoked_at,revoked_by) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)]],
        {grant.grant_id,grant.approval_id,grant.decision_id,canonical.encode(grant.subject),canonical.encode(grant.scope),canonical.encode(grant.terms),grant.state,grant.revision,grant.used,grant.reserved,grant.until_ms,grant.max_uses,grant.created_at,grant.domain,grant.owner_node,grant.workspace_id,grant.requester_id,grant.granted_by,grant.granted_definition,canonical.encode(grant.provenance),canonical.encode(grant.metadata),grant.revoked_at,grant.revoked_by})
    if err then return err end
    return M.history(tx,grant,"grant.created",grant.granted_by,grant.provenance,grant.created_at)
end
function M.revoke(tx: sql.Transaction, grant: Grant, expected: integer, actor: string, now: integer): string?
    if grant.state == "revoked" then return nil end
    if grant.revision ~= expected then return "CONFLICT: grant revision differs" end
    local at = clock.stamp(now)
    local err = execute(tx,"UPDATE bee_approval_grants SET state = 'revoked',revision = revision + 1,revoked_at = ?,revoked_by = ? WHERE grant_id = ? AND revision = ?",{at,actor,grant.grant_id,expected})
    if err then return err end
    err = execute(tx,"UPDATE bee_approval_grant_uses SET state = 'fenced' WHERE grant_id = ? AND state = 'reserved'",{grant.grant_id})
    if err then return err end
    grant.state,grant.revision,grant.revoked_at,grant.revoked_by = "revoked",grant.revision + 1,at,actor
    return M.history(tx,grant,"grant.revoked",actor,{},at)
end
function M.use(tx: sql.Transaction, grant: Grant, operation: string, effect_key: string, digest: string, expected: integer, actor: string, now: integer): (boolean?, string?)
    local rows, query_error = tx:query("SELECT request_digest,state FROM bee_approval_grant_uses WHERE grant_id = ? AND effect_key = ?",{grant.grant_id,effect_key})
    if not rows or query_error then return nil,"read grant use" end
    local err: string? = nil
    local prior = #rows == 1 and rows[1] or nil
    if prior and prior.request_digest ~= digest then return nil,"CONFLICT: effect scope differs" end
    if prior and prior.state == "admitted" and operation == "admit" then return true,nil end
    if operation == "release" and prior and prior.state == "released" then return true,nil end
    local state = M.state(grant,now)
    if state == "revoked" or state == "expired" then return nil,"DENIED: grant is " .. state end
    if prior and prior.state == "reserved" and operation == "reserve" then return true,nil end
    if expected ~= grant.revision then return nil,"CONFLICT: grant revision differs" end
    local at = clock.stamp(now)
    if operation == "reserve" then
        if state ~= "active" then return nil,"DENIED: grant is " .. state end
        if prior then return nil,"CONFLICT: effect use already ended" end
        err = execute(tx,"INSERT INTO bee_approval_grant_uses(grant_id,effect_key,request_digest,state,created_at) VALUES (?,?,?,'reserved',?)",{grant.grant_id,effect_key,digest,at})
        if err then return nil,err end
        err = execute(tx,"UPDATE bee_approval_grants SET reserved = reserved + 1,revision = revision + 1 WHERE grant_id = ?",{grant.grant_id})
        grant.reserved = grant.reserved + 1
    elseif operation == "admit" or operation == "release" then
        if not prior or prior.state ~= "reserved" then return nil,"CONFLICT: effect is not reserved" end
        err = execute(tx,"UPDATE bee_approval_grant_uses SET state = ?,admitted_at = ? WHERE grant_id = ? AND effect_key = ?",{operation == "admit" and "admitted" or "released",operation == "admit" and at or nil,grant.grant_id,effect_key})
        if err then return nil,err end
        err = execute(tx,"UPDATE bee_approval_grants SET reserved = reserved - 1,used = used + ?,revision = revision + 1 WHERE grant_id = ?",{operation == "admit" and 1 or 0,grant.grant_id})
        grant.reserved = grant.reserved - 1
        if operation == "admit" then grant.used = grant.used + 1 end
    else return nil,"INVALID_ARGUMENT: unknown grant use operation" end
    if err then return nil,err end
    grant.revision = grant.revision + 1
    err = M.history(tx,grant,"grant." .. operation,actor,{effect_key = effect_key,request_digest = digest},at)
    if err then return nil,err end
    return false,nil
end
return M
