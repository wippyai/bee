local sql = require("sql")
local json = require("json")
local security = require("security")
local bounds = require("bounds")
local transaction = require("transaction")
local traits = require("traits")
local supervisor = require("supervisor")
local M = {}
function M.read(db: sql.DB, _actor: string, raw: unknown): transaction.Result
    local request = bounds.object(raw)
    local ref = request and bounds.id(request.record_ref)
    local actor = security.actor()
    local meta = actor and bounds.object(actor:meta())
    if not ref or not request or bounds.fields(request, {"record_ref"}) or not actor or not meta or actor:id():match("^bee%.hive%.member%.") then
        return transaction.failure("DENIED", "original retrieval requires the approved app")
    end
    return transaction.read(db, function(tx: sql.Transaction): transaction.Result
        local rows, failure = tx:query("SELECT * FROM bee_session_hook_originals WHERE record_ref=?", {ref})
        if not rows or failure then return transaction.storage_failure("read original hook output") end
        if #rows ~= 1 then return transaction.failure("DENIED", "original is outside the app's consent") end
        local row = rows[1]
        local aliases, alias_error = tx:query("SELECT stable FROM bee_thread_app_alias WHERE instance=? AND active=1 AND workspace_id=? AND definition_id=?",
            {actor:id(), meta.workspace_id, meta.definition_id})
        if not aliases or alias_error or #aliases ~= 1 then return transaction.failure("DENIED", "original retrieval requires an admitted app instance") end
        local selection = traits.read(tx, assert(bounds.id(row.session_ref)), assert(bounds.id(row.trait_id)))
        if not selection or selection.grant_id ~= row.grant_id or meta.workspace_id ~= selection.workspace_id
            or meta.definition_id ~= selection.declaration.application_ref or meta.definition_revision ~= selection.declaration.application_revision
            or traits.consent(tx, selection) then return transaction.failure("DENIED", "original is outside the app's live consent") end
        return transaction.success({record_ref = ref, session_ref = selection.session_ref, trait_id = selection.trait_id,
            output = json.decode(assert(bounds.text(row.original_json, supervisor.MAX_TURN_BYTES)))}, false)
    end)
end
return M
