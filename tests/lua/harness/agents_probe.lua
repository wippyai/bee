-- MIT. Test-only caller of the application agents library: it runs as the
-- actor and scope the suite calls it with, as an application process would.
local agents = require("agents")
local function handle(request: {[string]: unknown}): {[string]: unknown}
    local launch = request.launch :: agents.Launch
    local run, fault = agents.launch(launch)
    if not run then return {ok = false, error = fault} end
    if request.cancel == true then
        local cancelled: agents.Status? = nil
        for _ = 1, 100 do
            local current, refused = agents.cancel(run)
            if current then cancelled = current break end
            if not refused or refused.code ~= "NOT_STARTED" then return {ok = false, error = refused} end
            local waited = agents.wait(run, 100)
            if waited and waited.state == "ended" then return {ok = false, error = {code = "ENDED", message = "the run ended before it was cancelled"}} end
        end
        if not cancelled then return {ok = false, error = {code = "NOT_STARTED", message = "the run never started"}} end
    end
    local final, wait_fault = agents.wait(run, math.floor(tonumber(request.timeout_ms) or 30000))
    if not final then return {ok = false, error = wait_fault} end
    return {ok = true, run = run, status = final}
end
return {handle = handle}
