-- MIT. Placement evidence fixtures for interactive lifecycle authorization.
local M = {}
function M.exited(request: {[string]: unknown}): unknown
    return {ok = true, value = {attempt = {attempt_id = request.attempt_id, execution_state = "exited", exit_source = "fixture", cleanup_state = "complete"}}}
end
function M.running(request: {[string]: unknown}): unknown
    return {ok = true, value = {attempt = {attempt_id = request.attempt_id, execution_state = "running"}}}
end
return M
