-- MIT. Placement evidence fixtures for interactive lifecycle authorization.
local security = require("security")
local M = {}
function M.exited(request: {[string]: unknown}): unknown
    return {ok = true, value = {attempt = {attempt_id = request.attempt_id, execution_state = "exited", exit_source = "fixture", cleanup_state = "complete"}}}
end
function M.running(request: {[string]: unknown}): unknown
    return {ok = true, value = {attempt = {attempt_id = request.attempt_id, execution_state = "running"}}}
end
function M.owner_running(request: {[string]: unknown}): unknown
    local actor = security.actor()
    if not actor or actor:id() ~= "bee.application:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:execution-owner" then
        return {ok = false, error = {code = "DENIED", message = "the attempt belongs to another owner"}}
    end
    return M.running(request)
end
function M.owner_stop(request: {[string]: unknown}): unknown
    return M.owner_running(request)
end
return M
