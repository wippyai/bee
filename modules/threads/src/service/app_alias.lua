-- MIT. Broker-attested application alias: the stable app an instance was
-- opened for, and the family's active threads for revocation fencing.
-- Only the application broker holds the alias action; instances attest
-- nothing themselves, so one app cannot claim another's stable identity.
local sql = require("sql")
local bounds = require("bounds")
local access = require("access")
local reader = require("reader")
local transaction = require("transaction")
local M = {}
type Result = transaction.Result
type Alias = {stable: string, instance: string, workspace_id: string, definition_id: string}
local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end
local function storage(err: string): Result
    if err == "BUSY" then return transaction.storage_failure("thread database is busy") end
    return transaction.failure("INTERNAL", err)
end
-- Both attested identities live under the application prefix in one
-- workspace; the stable suffix carries the admitted definition, never an
-- instance.
local function app_actor(value: unknown): string?
    local id = bounds.id(value)
    if id == nil then return nil end
    local checked: string = id
    if checked:sub(1, 16) ~= "bee.application:" or #checked < 51 then return nil end
    local workspace = checked:sub(17, 48)
    if workspace:find("[^0-9a-f]") or checked:sub(49, 49) ~= ":" or #checked:sub(50) == 0 then return nil end
    return checked
end
local function workspace_of(actor: string): string
    return actor:sub(17, 48)
end
local function decoded(request: unknown, fields: {string}): ({[string]: unknown}?, Result?)
    local object = bounds.object(request)
    if not object then return nil, failure("INVALID_ARGUMENT", "request must be an object") end
    local unknown_field = bounds.fields(object, fields)
    if unknown_field then return nil, failure("INVALID_ARGUMENT", unknown_field) end
    return object, nil
end
local function alias_of(object: {[string]: unknown}): (Alias?, Result?)
    local stable, instance = app_actor(object.stable), app_actor(object.instance)
    if stable == nil or instance == nil then
        return nil, failure("INVALID_ARGUMENT", "stable and instance must name application identities")
    end
    local checked_stable: string, checked_instance: string = stable, instance
    local workspace = bounds.id(object.workspace_id)
    if workspace == nil then
        return nil, failure("INVALID_ARGUMENT", "workspace_id must name the attested workspace")
    end
    local checked_workspace: string = workspace
    local definition = bounds.id(object.definition_id)
    if definition == nil or #definition > 160 then
        return nil, failure("INVALID_ARGUMENT", "definition_id must name the attested app")
    end
    local checked_definition: string = definition
    if checked_workspace ~= workspace_of(checked_stable) or checked_workspace ~= workspace_of(checked_instance) then
        return nil, failure("INVALID_ARGUMENT", "stable, instance and workspace_id must name one attested app")
    end
    return {stable = checked_stable, instance = checked_instance,
        workspace_id = checked_workspace, definition_id = checked_definition}, nil
end
function M.register(db: sql.DB, actor: string, request: unknown): Result
    local object, invalid = decoded(request, {"stable", "instance", "workspace_id", "definition_id"})
    if not object then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local alias, refused = alias_of(object)
    if not alias then return refused or failure("INVALID_ARGUMENT", "invalid request") end
    if not access.may_alias(alias.stable) then return failure("DENIED", "caller may not attest application instances") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local rows, query_err = tx:query("SELECT stable, workspace_id, definition_id FROM bee_thread_app_alias WHERE stable = ? AND instance = ?",
            {alias.stable, alias.instance})
        if query_err or not rows then return storage("read application alias") end
        if #rows > 0 then
            local row = rows[1] :: {[string]: unknown}
            if row.stable ~= alias.stable or row.workspace_id ~= alias.workspace_id or row.definition_id ~= alias.definition_id then
                return failure("CONFLICT", "application alias is already attested")
            end
            return transaction.success({stable = alias.stable, instance = alias.instance}, true)
        end
        local claimed, claimed_err = reader.app_stable(tx, alias.instance)
        if claimed_err then return storage(claimed_err) end
        if claimed then return failure("CONFLICT", "application instance is attested for another app") end
        local _, insert_err = tx:execute("INSERT INTO bee_thread_app_alias (stable, instance, workspace_id, definition_id, created_at) VALUES (?, ?, ?, ?, ?)",
            {alias.stable, alias.instance, alias.workspace_id, alias.definition_id, transaction.now()})
        if insert_err then return storage("record application alias") end
        return transaction.success({stable = alias.stable, instance = alias.instance}, false)
    end)
end
-- A revoked grant removes access: every active member row of the stable
-- family is deactivated, whatever role it holds. Leaving cannot do this:
-- the owner row of a thread the app launched never leaves. The call
-- converges: a second fence finds no active row and fences nothing.
function M.fence(db: sql.DB, actor: string, request: unknown): Result
    local object, invalid = decoded(request, {"stable"})
    if not object then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local stable = app_actor(object.stable)
    if not stable then return failure("INVALID_ARGUMENT", "stable must name an application identity") end
    if not access.may_alias(stable) then return failure("DENIED", "caller may not fence application families") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local threads, read_err = reader.app_family_threads(tx, stable)
        if not threads then return storage(read_err or "read application family") end
        local fenced = 0
        for _, entry in ipairs(threads) do
            local head, head_err = reader.head(tx, entry.thread_id)
            if head_err then return storage(head_err) end
            if head then
                local member, member_err = reader.member(tx, entry.thread_id, entry.actor)
                if member_err then return storage(member_err) end
                if member and member.active then
                    local revision = head.revision + 1
                    local deactivate_err = transaction.set_member(tx, entry.thread_id, entry.actor, member.role, revision, false)
                    if deactivate_err then return storage(deactivate_err) end
                    local advance_err = transaction.set_revision(tx, entry.thread_id, revision, head.state)
                    if advance_err then return storage(advance_err) end
                    fenced = fenced + 1
                end
            end
        end
        return transaction.success({stable = stable, fenced = fenced}, false)
    end)
end
return M
