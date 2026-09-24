-- MIT. Execution identity: the leader pid with its kernel start stamp and
-- the boot identity. A pid alone is reusable; pid, start stamp and boot
-- together name one process. Linux reports start in clock ticks since boot
-- from /proc and the boot id from the kernel; macOS reports start in seconds
-- since the epoch from the process table and the boot session UUID from
-- sysctl. Stamps compare only within one host and boot. Where they cannot be
-- read, identity is unknown and every later decision says so.
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
        local chunk, read_error = stdout:read(4096)
        if read_error then
            stdout:close()
            proc:close(true)
            return nil, "identity output failed: " .. tostring(read_error), nil
        end
        if not chunk then break end
        chunks[#chunks + 1] = tostring(chunk)
    end
    local code, wait_error = proc:wait()
    stdout:close()
    if wait_error then return nil, "identity command failed: " .. tostring(wait_error), nil end
    if type(code) ~= "number" or code ~= math.floor(code) then return nil, "identity command returned no exit code", nil end
    return table.concat(chunks), nil, math.floor(code)
end
type Facts = {start_ticks: integer?, boot_id: string?, pgid: integer?}
local MONTHS: {[string]: integer} = {Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
    Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12}
-- The probe prints one labeled fact per line; an absent fact prints an empty
-- value, so no fact can be read in another's place.
local function probe_command(pid: integer): string
    local p = tostring(pid)
    return "sh -c 'case \"$(uname -s)\" in "
        .. "Linux) echo \"linux_start=$(if [ -r /proc/" .. p .. "/stat ]; then sed -e \"s/^.*) //\" /proc/" .. p .. "/stat | cut -d\" \" -f20; fi)\"; "
        .. "echo \"linux_boot=$(cat /proc/sys/kernel/random/boot_id)\";; "
        .. "Darwin) echo \"darwin_start=$(LC_ALL=C TZ=UTC0 ps -o lstart= -p " .. p .. ")\"; "
        .. "echo \"darwin_boot=$(/usr/sbin/sysctl -n kern.bootsessionuuid)\";; "
        .. "esac; echo \"pgid=$(ps -o pgid= -p " .. p .. ")\"'"
end
-- Seconds since the epoch for a C-locale UTC `ps -o lstart` stamp such as
-- "Thu Sep 24 11:24:20 2026".
local function lstart_seconds(text: string): (integer?, string?)
    local month_name, day, hour, minute, second, year = text:match("^%a+%s+(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)%s+(%d+)$")
    local month = month_name and MONTHS[month_name] or nil
    if not month then return nil, "invalid process start time " .. string.format("%q", text) end
    local y, d = math.floor(tonumber(year) :: number), math.floor(tonumber(day) :: number)
    local h, mi, s = math.floor(tonumber(hour) :: number), math.floor(tonumber(minute) :: number), math.floor(tonumber(second) :: number)
    if d < 1 or d > 31 or h > 23 or mi > 59 or s > 60 then return nil, "invalid process start time " .. string.format("%q", text) end
    -- Days from 1970-01-01 in the proleptic Gregorian calendar.
    if month <= 2 then y = y - 1 end
    local era = y // 400
    local year_of_era = y - era * 400
    local day_of_year = (153 * (month + (month > 2 and -3 or 9)) + 2) // 5 + d - 1
    local day_of_era = year_of_era * 365 + year_of_era // 4 - year_of_era // 100 + day_of_year
    local days = era * 146097 + day_of_era - 719468
    return days * 86400 + h * 3600 + mi * 60 + s, nil
end
-- Decodes the probe's labeled facts. Every line must be a known label; an
-- empty value is an unknown fact, a malformed one refuses the whole probe.
function M.decode(output: string): (Facts?, string?)
    local facts: Facts = {}
    for line in output:gmatch("[^\n]+") do
        local label, raw = line:match("^([%w_]+)=(.*)$")
        if not label then return nil, "identity probe returned an unlabeled line" end
        local text = (raw :: string):match("^%s*(.-)%s*$") :: string
        if label == "linux_start" then
            if text ~= "" then
                if not text:match("^%d+$") then return nil, "invalid process start ticks" end
                facts.start_ticks = math.floor(tonumber(text) :: number)
            end
        elseif label == "darwin_start" then
            if text ~= "" then
                local seconds, start_error = lstart_seconds(text)
                if not seconds then return nil, start_error end
                facts.start_ticks = seconds
            end
        elseif label == "linux_boot" or label == "darwin_boot" then
            if text ~= "" then
                if not text:match("^[%x%-]+$") then return nil, "invalid boot identity" end
                facts.boot_id = text
            end
        elseif label == "pgid" then
            if text ~= "" then
                if not text:match("^%d+$") then return nil, "invalid process group" end
                facts.pgid = math.floor(tonumber(text) :: number)
            end
        else
            return nil, "identity probe returned unknown label " .. label
        end
    end
    return facts, nil
end
-- Reads start stamp, boot identity and pgid for a pid that this runner just
-- started.
function M.read(executor: exec.Executor, pid: integer): (Identity?, string?)
    local output, err = capture(executor, probe_command(pid))
    if not output then return nil, "read execution identity: " .. tostring(err) end
    local facts, decode_error = M.decode(output)
    if not facts then return nil, "read execution identity: " .. tostring(decode_error) end
    return {pid = pid, pgid = facts.pgid, start_ticks = facts.start_ticks, boot_id = facts.boot_id}, nil
end
-- Compares the recorded identity with what the kernel reports now.
function M.observe(recorded: Identity): Observation
    if not recorded.start_ticks or not recorded.boot_id then return {observed = false, detail = "no execution identity recorded"} end
    local executor_ref, reference_error = resources.executor()
    local executor, executor_error
    if executor_ref then executor, executor_error = exec.get(executor_ref) else executor_error = reference_error end
    if not executor then return {observed = false, detail = "executor unavailable: " .. tostring(executor_error)} end
    local output, err = capture(executor, probe_command(recorded.pid))
    executor:release()
    if not output then return {observed = false, detail = "identity probe failed: " .. tostring(err)} end
    local facts, decode_error = M.decode(output)
    if not facts then return {observed = false, detail = "identity probe failed: " .. tostring(decode_error)} end
    if not facts.boot_id then return {observed = false, detail = "identity probe returned no boot identity"} end
    if facts.boot_id ~= recorded.boot_id then return {observed = true, alive = false, detail = "different boot"} end
    if not facts.start_ticks then return {observed = true, alive = false, detail = "pid " .. tostring(recorded.pid) .. " is absent"} end
    if facts.start_ticks ~= recorded.start_ticks then return {observed = true, alive = false, detail = "pid " .. tostring(recorded.pid) .. " is another process"} end
    return {observed = true, alive = true, detail = "pid " .. tostring(recorded.pid) .. " identified alive"}
end
-- Whether any process remains in the recorded group. A group id survives
-- as long as one member lives, so "gone" is proof and "alive" may be a
-- reused id: the safe direction for cleanup.
function M.group_absent(pgid: integer): (boolean?, string?)
    if pgid <= 1 then return nil, "invalid process group" end
    local executor_ref, reference_error = resources.executor()
    local executor, executor_error
    if executor_ref then executor, executor_error = exec.get(executor_ref) else executor_error = reference_error end
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
    local executor_ref, reference_error = resources.executor()
    local executor, executor_error
    if executor_ref then executor, executor_error = exec.get(executor_ref) else executor_error = reference_error end
    if not executor then return false, "executor unavailable: " .. tostring(executor_error) end
    local _, err, code = capture(executor, "kill -s " .. tostring(signal) .. " -- -" .. tostring(recorded.pgid))
    executor:release()
    if err then return false, err end
    if code ~= 0 then return false, "group signal failed with exit " .. tostring(code) end
    return true, nil
end
return M
