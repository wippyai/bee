-- MIT. A real live process group must never be reported absent.
local exec = require("exec")
local logger = require("logger")
local env = require("env")
local identity = require("identity")
local function main()
    local expected = env.get("bee.identity_probe:expected")
    local executor, executor_error = exec.get("bee.identity_probe:executor")
    if not executor then error(tostring(executor_error)) end
    local child, child_error = executor:exec("/bin/sleep 20", {process_group = true})
    if not child then executor:release(); error(tostring(child_error)) end
    local started, start_error = child:start()
    if not started then child:close(true); executor:release(); error(tostring(start_error)) end
    local pid, pid_error = child:pid()
    if not pid then child:close(true); executor:release(); error(tostring(pid_error)) end
    local absent, probe_error = identity.group_absent(pid)
    logger:info("GROUP_PROBE", {absent = tostring(absent), error = tostring(probe_error)})
    local killed, kill_error = child:signal(9)
    local _, wait_error = child:wait()
    executor:release()
    logger:info("GROUP_CLEANUP", {killed = tostring(killed), error = tostring(kill_error), wait = tostring(wait_error)})
    if not killed or wait_error then error("fixture cleanup: " .. tostring(kill_error or wait_error)) end
    if expected == "unknown" then
        if absent ~= nil or not probe_error then error("failed group probe must remain unknown") end
        logger:info("IDENTITY_GROUP_UNKNOWN_PASS")
        return
    end
    if absent ~= false then error("live process group reported absent/unknown: " .. tostring(absent) .. ": " .. tostring(probe_error)) end
    local gone, gone_error = identity.group_absent(pid)
    if gone ~= true then error("reaped process group not absent: " .. tostring(gone_error)) end
    logger:info("IDENTITY_GROUP_LIFETIME_PASS")
end
return {main = main}
