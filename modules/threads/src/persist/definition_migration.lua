-- SPDX-License-Identifier: MIT
local sql = require("sql")
local identity = require("identity")
local M = {}
local definitions: {[string]: string} = {
    ["bee.settings:app"] = "bee.settings.app:app",
    ["bee.console:app"] = "bee.console.app:app",
    ["bee.host.processes:app"] = "bee.host.processes.app:app",
    ["bee.gov.overlays:app"] = "bee.gov.overlays.app:app",
}
local columns: {{table: string, column: string}} = {
    {table = "bee_thread_heads", column = "owner_actor"},
    {table = "bee_thread_members", column = "actor"},
    {table = "bee_thread_commands", column = "actor"},
    {table = "bee_thread_subscriptions", column = "actor"},
    {table = "bee_thread_notices", column = "watcher_actor"},
    {table = "bee_thread_inbox_items", column = "sender_actor"},
    {table = "bee_thread_inbox_outbox", column = "sender_actor"},
    {table = "bee_sessions", column = "owner_actor"},
    {table = "bee_session_operations", column = "owner_actor"},
    {table = "bee_session_work", column = "sender_id"},
}
function M.apply(db: sql.DB): (boolean, string?)
    local tx, begin_error = db:begin()
    if not tx then return false, "begin thread definition migration: " .. tostring(begin_error) end
    local function fail(message: string): (boolean, string?) tx:rollback(); return false, message end
    local marker, marker_error = tx:query("SELECT id FROM bee_thread_definition_migrations WHERE id = 1")
    if not marker or marker_error then return fail("read thread definition migration ledger") end
    if #marker > 0 then tx:rollback(); return true, nil end
    local rows, read_error = tx:query("SELECT DISTINCT stable, workspace_id, definition_id FROM bee_thread_app_alias")
    if not rows or read_error then return fail("read thread application definitions") end
    for _, row in ipairs(rows) do
        local definition = row.definition_id
        if type(definition) ~= "string" then return fail("thread application definition is invalid") end
        local target = definitions[definition]
        if target then
            local stable = row.stable
            local prior = identity.stable(row.workspace_id, definition)
            local next = identity.stable(row.workspace_id, target)
            if type(stable) ~= "string" or not prior or not next or prior.id ~= stable then
                return fail("thread application identity does not match its definition")
            end
            for _, field in ipairs(columns) do
                local _, update_error = tx:execute("UPDATE " .. field.table .. " SET " .. field.column .. " = ? WHERE " .. field.column .. " = ?", {next.id, stable})
                if update_error then return fail("migrate thread application identity in " .. field.table) end
            end
            local _, allow_error = tx:execute("UPDATE bee_thread_inbox_rules SET sender_value = ? WHERE sender_kind = 'actor' AND sender_value = ?", {next.id, stable})
            if allow_error then return fail("migrate thread sender allowlist") end
            for _, field in ipairs({{table = "bee_thread_commands", column = "request_json"}, {table = "bee_thread_commands", column = "reply_json"}, {table = "bee_thread_subscriptions", column = "filter_json"}, {table = "bee_session_operations", column = "receipt_json"}}) do
                local _, receipt_error = tx:execute("UPDATE " .. field.table .. " SET " .. field.column .. " = replace(" .. field.column .. ", ?, ?)", {'"' .. stable .. '"', '"' .. next.id .. '"'})
                if receipt_error then return fail("migrate thread identity receipt in " .. field.table) end
            end
            local _, alias_error = tx:execute("UPDATE bee_thread_app_alias SET stable = ?, definition_id = ? WHERE stable = ?", {next.id, target, stable})
            if alias_error then return fail("migrate thread application aliases") end
        end
    end
    local _, record_error = tx:execute("INSERT INTO bee_thread_definition_migrations (id) VALUES (1)")
    if record_error then return fail("record thread definition migration") end
    local _, commit_error = tx:commit()
    if commit_error then return fail("commit thread definition migration") end
    return true, nil
end
return M
