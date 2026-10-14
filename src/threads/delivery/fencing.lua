local sql = require("sql")
local M = {}
local function execute(tx: sql.Transaction | sql.DB, statement: string, args: {unknown}): string?
    local _, err = tx:execute(statement,args)
    return err and tostring(err) or nil
end
function M.revoke(tx: sql.Transaction | sql.DB, grant_id: string, at: string): string?
    local statements = {
        [[UPDATE bee_session_trait_intervals SET end_sequence = (SELECT h.head_sequence FROM bee_session_traits t JOIN bee_thread_heads h ON h.thread_id=t.thread_id WHERE t.session_ref=bee_session_trait_intervals.session_ref AND t.trait_id=bee_session_trait_intervals.trait_id) WHERE end_sequence IS NULL AND EXISTS (SELECT 1 FROM bee_session_traits t WHERE t.grant_id=? AND t.session_ref=bee_session_trait_intervals.session_ref AND t.trait_id=bee_session_trait_intervals.trait_id)]],
        [[UPDATE bee_thread_subscription_pages SET acknowledged=1 WHERE subscription_id IN (SELECT s.subscription_id FROM bee_thread_subscriptions s JOIN bee_session_traits t ON json_extract(s.filter_json,'$.session_ref')=t.session_ref AND json_extract(s.filter_json,'$.trait_id')=t.trait_id WHERE t.grant_id=?)]],
        [[UPDATE bee_session_traits SET selected=0,revision=revision+1 WHERE grant_id=? AND selected=1]],
    }
    for _, statement in ipairs(statements) do
        local err = execute(tx, statement, {grant_id})
        if err then return err end
    end
    return execute(tx, [[UPDATE bee_thread_subscriptions SET closed_at=? WHERE subscription_id IN (SELECT s.subscription_id FROM bee_thread_subscriptions s JOIN bee_session_traits t ON json_extract(s.filter_json,'$.session_ref')=t.session_ref AND json_extract(s.filter_json,'$.trait_id')=t.trait_id WHERE t.grant_id=?)]], {at,grant_id})
end
return M
