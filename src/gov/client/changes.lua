-- MIT. Governance's change feed. Governance owns its activation records and
-- names the tables whose commits change what a governance client shows; a
-- client follows this feed and never names them.
local cdc = require("cdc")
local M = {}
M.SOURCE = "bee:changes"
local ACTIVATION_TABLES = {"bee_governance_activation_execution", "bee_governance_follow_progress", "bee_governance_activation_intents"}
-- activations: a capture of every commit that changes an activation's
-- intent, execution or follow progress.
function M.activations()
    local stream, err = cdc.stream(M.SOURCE, {tables = ACTIVATION_TABLES})
    if not stream then error("capture governance activation changes: " .. tostring(err)) end
    return stream
end
return M
