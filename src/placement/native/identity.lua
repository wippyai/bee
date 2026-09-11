-- MIT. Execution identity on Linux: the leader pid with its start ticks and
-- the boot id. A pid alone is reusable; pid, ticks and boot together name
-- one process. Where they cannot be read, identity is unknown and every
-- later decision says so.
local exec = require("exec")
local resources = require("resources")
local M = {}
type Identity = {pid: integer, pgid: integer?, start_ticks: integer?, boot_id: string?}
type Observation = {observed: boolean, alive: boolean?, detail: string}
local function capture(executor: exec.Executor, command: string): (string?, string?, integer?)
    local proc, exec_error = executor:exec(command)
    if not proc then return nil, tostring(exec_error) end
    local stdout = proc:stdout_stream()
    local started, start_error = proc:start()
    if not started then return nil, tostring(start_error) end
    local chunks: {string} = {}
    while true do
        local chunk = stdout:read(4096)
        if not chunk then break end
        chunks[#chunks + 1] = tostring(chunk)
    end
    local code, wait_error = proc:wait()
    stdout:close()
    if wait_error then return nil, "identity command failed: " .. tostring(wait_error), nil end
    if type(code) ~= "number" or code ~= math.floor(code) then return nil, "identity command returned no exit code", nil end
    return table.concat(chunks), nil, math.floor(code)
end
local function stat_command(pid: integer): string
    local stat = "/proc/" .. tostring(pid) .. "/stat"
    return "sh -c 'if [ -r " .. stat .. " ]; then sed -e \"s/^.*) //\" " .. stat .. " | cut -d\" \" -f20; fi; cat /proc/sys/kernel/random/boot_id; ps -o pgid= -p " .. tostring(pid) .. "'"
end
-- Reads ticks, boot id and pgid for a pid that this runner just started.
function M.read(executor: exec.Executor, pid: integer): (Identity?, string?)
    local output, err = capture(executor, stat_command(pid))
    if not output then return nil, "read execution identity: " .. tostring(err) end
    local lines: {string} = {}
    for line in (output .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    local identity: Identity = {pid = pid}
    if #lines >= 3 then
        identity.start_ticks = tonumber(lines[1])
        identity.boot_id = lines[2] ~= "" and lines[2] or nil
        identity.pgid = tonumber((lines[3]:gsub("%s", "")))
    elseif #lines == 2 then
        identity.boot_id = lines[1] ~= "" and lines[1] or nil
        identity.pgid = tonumber((lines[2]:gsub("%s", "")))
    end
    return identity, nil
end
-- Compares the recorded identity with what the kernel reports now.
function M.observe(recorded: Identity): Observation
    if not recorded.start_ticks or not recorded.boot_id then return {observed = false, detail = "no execution identity recorded"} end
    local executor, executor_error = exec.get(resources.EXECUTOR)
    if not executor then return {observed = false, detail = "executor unavailable: " .. tostring(executor_error)} end
    local output, err = capture(executor, stat_command(recorded.pid))
    executor:release()
    if not output then return {observed = false, detail = "identity probe failed: " .. tostring(err)} end
    local lines: {string} = {}
    for line in (output .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    if #lines < 2 then return {observed = false, detail = "identity probe returned nothing"} end
    local boot = #lines >= 3 and lines[2] or lines[1]
    if boot ~= recorded.boot_id then return {observed = true, alive = false, detail = "different boot"} end
    if #lines < 3 or lines[1] == "" then return {observed = true, alive = false, detail = "pid " .. tostring(recorded.pid) .. " is absent"} end
    if tonumber(lines[1]) ~= recorded.start_ticks then return {observed = true, alive = false, detail = "pid " .. tostring(recorded.pid) .. " is another process"} end
    return {observed = true, alive = true, detail = "pid " .. tostring(recorded.pid) .. " identified alive"}
end
-- Whether any process remains in the recorded group. A group id survives
-- as long as one member lives, so "gone" is proof and "alive" may be a
-- reused id: the safe direction for cleanup.
function M.group_absent(pgid: integer): (boolean?, string?)
    if pgid <= 1 then return nil, "invalid process group" end
    local executor, executor_error = exec.get(resources.EXECUTOR)
    if not executor then return nil, "executor unavailable: " .. tostring(executor_error) end
    -- A failed kill probe can mean unsupported shell syntax or denied access.
    -- Only a successful, fully decoded process table proves group absence.
    local output, err, code = capture(executor, "ps -e -o pgid=")
    executor:release()
    if not output then return nil, err end
    if code ~= 0 then return nil, "group probe failed with exit " .. tostring(code) end
    local seen, present = false, false
    for line in output:gmatch("[^\r\n]+") do
        local digits = line:match("^%s*(%d+)%s*$")
        local group = digits and tonumber(digits) or nil
        if not group then return nil, "group probe returned an invalid process table" end
        seen = true
        if group == pgid then present = true end
    end
    if not seen then return nil, "group probe returned nothing" end
    return not present, nil
end
-- Signals the identified leader's group, or nothing when identity is not
-- proven alive first.
function M.signal_group(recorded: Identity, signal: integer): (boolean, string?)
    local observation = M.observe(recorded)
    if not observation.observed then return false, observation.detail end
    if not observation.alive then return false, observation.detail end
    if not recorded.pgid then return false, "no process group recorded" end
    local executor, executor_error = exec.get(resources.EXECUTOR)
    if not executor then return false, "executor unavailable: " .. tostring(executor_error) end
    local _, err = capture(executor, "kill -s " .. tostring(signal) .. " -- -" .. tostring(recorded.pgid))
    executor:release()
    if err then return false, err end
    return true, nil
end
return M
