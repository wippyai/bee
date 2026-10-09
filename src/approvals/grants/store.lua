local sql = require("sql")
local json = require("json")
local hash = require("hash")
local registry = require("registry")
local security = require("security")
local time = require("time")
local bounds = require("bounds")
local canonical = require("canonical")
local clock = require("clock")
local M = {}
type Object = {[string]: unknown}
type Grant = {grant_id: string, domain: string, owner_node: string, workspace_id: string, requester_id: string,
    granted_by: string, granted_definition: string?, subject: Object, scope: Object, terms: Object, provenance: Object,
    metadata: Object, state: string, revision: integer, used: integer, reserved: integer, until_ms: integer?, max_uses: integer?,
    created_at: string, approval_id: string?, decision_id: string?, revoked_at: string?, revoked_by: string?}
local function execute(tx: sql.Transaction | sql.DB, statement: string, args: {unknown}): string?
    local _, err = tx:execute(statement,args)
    return err and tostring(err) or nil
end
function M.principal(fallback: string): (string,string?)
    local actor = security.actor()
    if not actor then return fallback,nil end
    local metadata = bounds.object(actor:meta())
    return actor:id(),metadata and bounds.id(metadata.definition_id)
end
function M.permanent_allowed(domain: string): boolean
    local entries, err = registry.find({["meta.type"] = "bee.approvals.grant-policy",["meta.domain"] = domain})
    if not entries or err or #entries ~= 1 then return false end
    local meta = bounds.object(entries[1].meta)
    return meta ~= nil and meta.allow_permanent == true
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
    local subject = type(row.subject_json) == "string" and bounds.object(json.decode(row.subject_json)) or bounds.object(row.subject)
    local scope = type(row.scope_json) == "string" and bounds.object(json.decode(row.scope_json)) or bounds.object(row.scope)
    local terms = type(row.terms_json) == "string" and bounds.object(json.decode(row.terms_json)) or bounds.object(row.terms)
    local provenance = type(row.provenance_json) == "string" and bounds.object(json.decode(row.provenance_json)) or bounds.object(row.provenance)
    local metadata = type(row.metadata_json) == "string" and bounds.object(json.decode(row.metadata_json)) or bounds.object(row.metadata)
    local created = bounds.timestamp(row.created_at)
    if not created and provenance and provenance.kind == "legacy" and type(row.created_at) == "string" then
        local instant = time.parse("2006-01-02T15:04:05Z07:00",row.created_at)
        if instant then created = clock.utc(instant) end
    end
    if not id or not domain or not owner or not workspace or not requester or not issuer or not state or not revision
        or revision < 1 or not used or used < 0 or not reserved or reserved < 0 or not subject or not scope or not terms
        or not provenance or not metadata or not created then return nil,"grant record is corrupt" end
    return {grant_id = id,domain = domain,owner_node = owner,workspace_id = workspace,requester_id = requester,
        granted_by = issuer,granted_definition = bounds.id(row.granted_definition),subject = subject,scope = scope,terms = terms,
        provenance = provenance,metadata = metadata,state = state,revision = revision,used = used,reserved = reserved,
        until_ms = bounds.integer(row.until_ms),max_uses = bounds.integer(row.max_uses),created_at = created,
        approval_id = bounds.id(row.approval_id),decision_id = bounds.id(row.decision_id),revoked_at = bounds.timestamp(row.revoked_at),revoked_by = bounds.id(row.revoked_by)},nil
end
function M.read(tx: sql.Transaction | sql.DB, id: string): (Grant?, string?)
    local rows, err = tx:query("SELECT * FROM bee_approval_grants WHERE grant_id = ?",{id})
    if not rows or err then return nil,"read grant: " .. tostring(err) end
    if #rows == 0 then return nil,nil end
    local grant, invalid = M.decode(rows[1])
    if not grant then return nil,invalid end
    local context_error = M.observe(tx,grant)
    if context_error then return nil,context_error end
    return grant,nil
end
function M.observe(tx: sql.Transaction | sql.DB, grant: Grant): string?
    if grant.terms.kind ~= "binding" then return nil end
    local entries, err = registry.find({["meta.type"] = "bee.approvals.grant-context",["meta.domain"] = grant.domain})
    if not entries or err then return "grant context discovery: " .. tostring(err) end
    if #entries ~= 1 then
        local ids: {string} = {}
        for _, entry in ipairs(entries) do ids[#ids + 1] = entry.id end
        return "grant context is not uniquely registered for " .. grant.domain .. " (" .. tostring(#entries) .. ": " .. table.concat(ids,",") .. ")"
    end
    local meta = assert(bounds.object(entries[1].meta))
    local fields: {[string]: string} = {}
    for _, name in ipairs({"table_name","identity_field","expires_field","revoked_field","sealed_field"}) do
        local field = bounds.text(meta[name],128)
        if not field or not field:match("^[a-z][a-z0-9_]*$") then return "invalid grant context projection" end
        fields[name] = field
    end
    local key = bounds.id(meta.metadata_key)
    local identity = key and bounds.id(grant.metadata[key])
    if not identity then return "grant context identity is missing" end
    local rows, query_error = tx:query("SELECT " .. fields.expires_field .. " AS expires_at," .. fields.revoked_field .. " AS revoked_at," .. fields.sealed_field .. " AS sealed_at FROM " .. fields.table_name .. " WHERE " .. fields.identity_field .. " = ?",{identity})
    if not rows or query_error then return "read grant context: " .. tostring(query_error) end
    if #rows ~= 1 then grant.state = "revoked"; return nil end
    local row = assert(bounds.object(rows[1]))
    if row.revoked_at ~= nil or row.sealed_at ~= nil then grant.state = "revoked" end
    local expires = bounds.text(row.expires_at,64)
    local instant = expires and (clock.parse(expires) or time.parse("2006-01-02T15:04:05Z07:00",expires))
    if not instant then return "grant context expiry is invalid" end
    local deadline = math.floor(instant:unix_nano() / 1000000)
    if not grant.until_ms or deadline < grant.until_ms then grant.until_ms = deadline end
    return nil
end
function M.history(tx: sql.Transaction | sql.DB, grant: Grant, kind: string, actor: string, body: Object, at: string): string?
    return execute(tx,"INSERT INTO bee_approval_grant_history(grant_id,revision,kind,actor_id,body_json,at) VALUES (?,?,?,?,?,?)",
        {grant.grant_id,grant.revision,kind,actor,canonical.encode(body),at})
end
function M.create(tx: sql.Transaction | sql.DB, grant: Grant): string?
    if grant.terms.kind == "until_revoked" and grant.provenance.kind ~= "legacy" and not M.permanent_allowed(grant.domain) then return "FORBIDDEN: policy does not permit persistent grants" end
    local err = execute(tx,[[INSERT INTO bee_approval_grants(grant_id,approval_id,decision_id,subject_json,scope_json,terms_json,state,revision,used,reserved,until_ms,max_uses,created_at,domain,owner_node,workspace_id,requester_id,granted_by,granted_definition,provenance_json,metadata_json,revoked_at,revoked_by) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)]],
        {grant.grant_id,grant.approval_id or sql.NULL,grant.decision_id or sql.NULL,canonical.encode(grant.subject),canonical.encode(grant.scope),canonical.encode(grant.terms),grant.state,grant.revision,grant.used,grant.reserved,grant.until_ms or sql.NULL,grant.max_uses or sql.NULL,grant.created_at,grant.domain,grant.owner_node,grant.workspace_id,grant.requester_id,grant.granted_by,grant.granted_definition or sql.NULL,canonical.encode(grant.provenance),canonical.encode(grant.metadata),grant.revoked_at or sql.NULL,grant.revoked_by or sql.NULL})
    if err then return err end
    return M.history(tx,grant,"grant.created",grant.granted_by,grant.provenance,grant.created_at)
end
local function fence_traits(tx: sql.Transaction | sql.DB, grant: Grant, at: string): string?
    local proposal = bounds.object(grant.scope.parameters)
    local payload = proposal and bounds.object(proposal.payload)
    if grant.domain ~= "gateway_access" or #(payload and bounds.array(payload.declarations, 16) or {}) == 0 then return nil end
    local statements = {
        [[UPDATE bee_session_trait_intervals SET end_sequence = (SELECT h.head_sequence FROM bee_session_traits t JOIN bee_thread_heads h ON h.thread_id=t.thread_id WHERE t.session_ref=bee_session_trait_intervals.session_ref AND t.trait_id=bee_session_trait_intervals.trait_id) WHERE end_sequence IS NULL AND EXISTS (SELECT 1 FROM bee_session_traits t WHERE t.grant_id=? AND t.session_ref=bee_session_trait_intervals.session_ref AND t.trait_id=bee_session_trait_intervals.trait_id)]],
        [[UPDATE bee_thread_subscription_pages SET acknowledged=1 WHERE subscription_id IN (SELECT s.subscription_id FROM bee_thread_subscriptions s JOIN bee_session_traits t ON json_extract(s.filter_json,'$.session_ref')=t.session_ref AND json_extract(s.filter_json,'$.trait_id')=t.trait_id WHERE t.grant_id=?)]],
        [[UPDATE bee_session_traits SET selected=0,revision=revision+1 WHERE grant_id=? AND selected=1]],
    }
    for _, statement in ipairs(statements) do
        local err = execute(tx, statement, {grant.grant_id})
        if err then return err end
    end
    return execute(tx, [[UPDATE bee_thread_subscriptions SET closed_at=? WHERE subscription_id IN (SELECT s.subscription_id FROM bee_thread_subscriptions s JOIN bee_session_traits t ON json_extract(s.filter_json,'$.session_ref')=t.session_ref AND json_extract(s.filter_json,'$.trait_id')=t.trait_id WHERE t.grant_id=?)]], {at,grant.grant_id})
end
function M.revoke(tx: sql.Transaction | sql.DB, grant: Grant, expected: integer, actor: string, now: integer): string?
    local rows, query_error = tx:query("SELECT * FROM bee_approval_grants WHERE grant_id = ?",{grant.grant_id})
    if not rows or query_error then return "read grant revocation: " .. tostring(query_error) end
    if #rows ~= 1 then return "NOT_FOUND: grant is missing" end
    local live, read_error = M.decode(rows[1])
    if not live then return read_error end
    if live.state == "revoked" then grant.state,grant.revision = live.state,live.revision; return nil end
    if live.revision ~= grant.revision or grant.revision ~= expected then return "CONFLICT: grant revision differs" end
    local at = clock.stamp(now)
    local err = execute(tx,"UPDATE bee_approval_grants SET state = 'revoked',revision = revision + 1,revoked_at = ?,revoked_by = ? WHERE grant_id = ? AND revision = ?",{at,actor,grant.grant_id,expected})
    if err then return err end
    err = execute(tx,"UPDATE bee_approval_grant_uses SET state = 'fenced' WHERE grant_id = ? AND state = 'reserved'",{grant.grant_id})
    if err then return err end
    err = fence_traits(tx, grant, at)
    if err then return err end
    grant.state,grant.revision,grant.revoked_at,grant.revoked_by = "revoked",grant.revision + 1,at,actor
    return M.history(tx,grant,"grant.revoked",actor,{},at)
end
function M.expire(tx: sql.Transaction | sql.DB, grant: Grant, now: integer): string?
    if grant.state ~= "active" or not grant.until_ms or grant.until_ms > now then return nil end
    local err = execute(tx,"UPDATE bee_approval_grants SET state = 'expired',revision = revision + 1 WHERE grant_id = ? AND revision = ?",{grant.grant_id,grant.revision})
    if err then return err end
    err = execute(tx,"UPDATE bee_approval_grant_uses SET state = 'fenced' WHERE grant_id = ? AND state = 'reserved'",{grant.grant_id})
    if err then return err end
    err = fence_traits(tx, grant, clock.stamp(now))
    if err then return err end
    grant.state,grant.revision = "expired",grant.revision + 1
    return M.history(tx,grant,"grant.expired",grant.owner_node,{},clock.stamp(now))
end
function M.use(tx: sql.Transaction | sql.DB, grant: Grant, operation: string, effect_key: string, digest: string, expected: integer, actor: string, now: integer): (boolean?, string?)
    local rows, query_error = tx:query("SELECT request_digest,state FROM bee_approval_grant_uses WHERE grant_id = ? AND effect_key = ?",{grant.grant_id,effect_key})
    if not rows or query_error then return nil,"read grant use" end
    local err: string? = nil
    local prior = #rows == 1 and rows[1] or nil
    if prior and prior.request_digest ~= digest then return nil,"CONFLICT: effect scope differs" end
    if prior and prior.state == "admitted" and (operation == "admit" or operation == "consume") then return true,nil end
    if operation == "release" and prior and prior.state == "released" then return true,nil end
    local live, read_error = M.read(tx,grant.grant_id)
    if not live then return nil,read_error or "NOT_FOUND: grant is missing" end
    local state = M.state(live,now)
    if state == "revoked" or state == "expired" then return nil,"DENIED: grant is " .. state end
    if prior and prior.state == "reserved" and operation == "reserve" then return true,nil end
    if expected ~= grant.revision or live.revision ~= grant.revision then return nil,"CONFLICT: grant revision differs" end
    local at = clock.stamp(now)
    if operation == "reserve" then
        if state ~= "active" then return nil,"DENIED: grant is " .. state end
        if prior then return nil,"CONFLICT: effect use already ended" end
        err = execute(tx,"INSERT INTO bee_approval_grant_uses(grant_id,effect_key,request_digest,state,created_at) VALUES (?,?,?,'reserved',?)",{grant.grant_id,effect_key,digest,at})
        if err then return nil,err end
        err = execute(tx,"UPDATE bee_approval_grants SET reserved = reserved + 1,revision = revision + 1 WHERE grant_id = ?",{grant.grant_id})
        grant.reserved = grant.reserved + 1
    elseif operation == "consume" then
        if prior or state ~= "active" then return nil,"DENIED: grant cannot admit another effect" end
        err = execute(tx,"INSERT INTO bee_approval_grant_uses(grant_id,effect_key,request_digest,state,created_at,admitted_at) VALUES (?,?,?,'admitted',?,?)",{grant.grant_id,effect_key,digest,at,at})
        if err then return nil,err end
        err = execute(tx,"UPDATE bee_approval_grants SET used = used + 1,revision = revision + 1 WHERE grant_id = ?",{grant.grant_id})
        grant.used = grant.used + 1
    elseif operation == "admit" or operation == "release" then
        if not prior or prior.state ~= "reserved" then return nil,"CONFLICT: effect is not reserved" end
        err = execute(tx,"UPDATE bee_approval_grant_uses SET state = ?,admitted_at = ? WHERE grant_id = ? AND effect_key = ?",{operation == "admit" and "admitted" or "released",operation == "admit" and at or sql.NULL,grant.grant_id,effect_key})
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
