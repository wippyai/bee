local database = require("database")
local grants = require("grants")
local authority = require("authority")
local bounds = require("bounds")
local function handle(raw: unknown): {[string]: unknown}
    local input = assert(bounds.object(raw))
    local db = assert(database.open())
    local parent = assert(grants.read(db, tostring(input.parent_grant_id)))
    db:release()
    local decision, decision_error = authority.folder_decision(tostring(input.approval_id), parent.workspace_id)
    if not decision then return {ok = false, message = decision_error} end
    db = assert(database.open())
    local tx = assert(db:begin())
    local record, err = authority.save_folder(tx, parent, tostring(input.canonical_workdir), tostring(input.driver_binding_ref), tostring(input.approval_id), decision)
    if record then assert(tx:commit()) else tx:rollback() end
    db:release()
    return {ok = record ~= nil, message = err, grant_id = record and record.grant_id}
end
return {handle = handle}
