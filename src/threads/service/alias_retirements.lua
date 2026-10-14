-- SPDX-License-Identifier: MIT
local sql = require("sql")
local access = require("access")
local transaction = require("transaction")
type Alias = {stable: string, instance: string, workspace_id: string, definition_id: string}
local M = {}
function M.enqueue(tx: sql.Transaction, alias: Alias): string?
    if not access.may_alias(alias.stable) then return "caller may not retire application instances" end
    local rows, problem = tx:query("SELECT generation FROM bee_thread_app_alias WHERE stable = ? AND instance = ? AND workspace_id = ? AND definition_id = ?",
        {alias.stable, alias.instance, alias.workspace_id, alias.definition_id})
    if not rows or problem then return "read application alias retirement generation" end
    if #rows ~= 1 then return "application alias changed before retirement intent" end
    local _, err = tx:execute("INSERT INTO bee_thread_app_alias_retirements (stable, instance, generation) VALUES (?, ?, ?) ON CONFLICT DO NOTHING",
        {alias.stable, alias.instance, rows[1].generation})
    return err and "record application alias retirement intent" or nil
end
function M.drain(db: sql.DB): string?
    local result = transaction.write(db, function(tx: sql.Transaction): transaction.Result
        local _, update_error = tx:execute([[UPDATE bee_thread_app_alias SET active = 0
            WHERE active = 1 AND EXISTS (SELECT 1 FROM bee_thread_app_alias_retirements r
                WHERE r.stable = bee_thread_app_alias.stable AND r.instance = bee_thread_app_alias.instance
                    AND r.generation = bee_thread_app_alias.generation)]])
        if update_error then return transaction.storage_failure("retire application alias generations") end
        local _, delete_error = tx:execute("DELETE FROM bee_thread_app_alias_retirements")
        if delete_error then return transaction.storage_failure("complete application alias retirement intents") end
        return transaction.success({}, false)
    end)
    if not result.ok then return result.message or "application alias retirement failed" end
    return nil
end
return M
