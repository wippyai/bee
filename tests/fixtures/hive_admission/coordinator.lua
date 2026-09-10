-- SPDX-License-Identifier: MIT
-- Trusted coordinator process running on workers host to orchestrate admission proofs.
local process = require("process")
local channel = require("channel")
local time = require("time")
local io = require("io")
local protocol = require("protocol")
local security = require("security")

type VariantResult = {
    admitted: boolean,
    pid: string?,
    err_msg: string
}

type AttackerReport = {
    phase: integer,
    any_admitted: boolean,
    results: {[string]: VariantResult}
}

type CoordinatorResult = {
    status: string,
    phases_completed: integer
}

local function main(): CoordinatorResult
    local self_pid: string = tostring(process.pid())
    local self_host: string? = protocol.extract_pid_host(self_pid)
    if self_host ~= "bee.hive_admission:workers" then
        error("Coordinator not running on workers host, current host: " .. tostring(self_host))
    end

    local events = assert(process.events())
    local reply_topic: string = "bee.hive_admission.reply"
    local replies = assert(process.listen(reply_topic, {message = true}))

    local function run_negative_phase(phase_num: integer)
        local policies: {security.Policy} = {}
        for _, name in ipairs({"attacker_entry_policy", "attacker_worker_host_policy", "attacker_deny_supervisor_policy", "attacker_context_policy"}) do
            policies[#policies + 1] = assert(security.policy("bee.hive_admission:" .. name))
        end
        local attacker_pid_raw = assert(process.with_options({}):with_scope(security.new_scope(policies))
            :spawn_monitored("bee.hive_admission:attacker", "bee.hive_admission:workers", phase_num))
        local attacker_pid: string = tostring(attacker_pid_raw)
        local deadline = time.after("5s")
        local raw_report: AttackerReport? = nil

        while not raw_report do
            local sel = channel.select({events:case_receive(), deadline:case_receive()})
            if not sel.ok then error("Channel closed waiting for attacker") end
            if sel.channel == deadline then
                error("Timeout waiting for attacker phase " .. tostring(phase_num))
            end
            local ev = sel.value
            if ev.kind == process.event.EXIT and tostring(ev.from) == attacker_pid then
                if type(ev.result) == "table" then
                    raw_report = protocol.decode_attacker_report(ev.result.value)
                end
                if not raw_report then
                    error("Attacker exited without valid report")
                end
            end
        end

        local report: AttackerReport = raw_report
        if report.phase ~= phase_num then error("Attacker report phase mismatch") end
        if report.any_admitted then
            error("NEGATIVE ADMISSION VIOLATION: attacker admitted on supervisor host in phase " .. tostring(phase_num))
        end

        local required_variants: {string} = {"spawn", "spawn_monitored", "spawn_linked", "spawn_linked_monitored", "exec", "with_context", "with_options"}
        for _, v in ipairs(required_variants) do
            local res = report.results[v]
            if not res then error("Missing result for variant: " .. v) end
            if res.admitted then
                error("Variant admitted on supervisor host: " .. v)
            end
            local is_perm_denied: boolean = (string.find(res.err_msg, "not allowed to spawn on host", 1, true) ~= nil)
                or (string.find(res.err_msg, "not allowed to exec on host", 1, true) ~= nil)
            is_perm_denied = is_perm_denied and string.find(res.err_msg, "bee.hive_admission:supervisor_host", 1, true) ~= nil

            local is_capacity_err: boolean = (string.find(res.err_msg, "capacity", 1, true) ~= nil)
                or (string.find(res.err_msg, "max_processes", 1, true) ~= nil)
            local is_notfound_err: boolean = (string.find(res.err_msg, "not found", 1, true) ~= nil)
                or (string.find(res.err_msg, "unknown", 1, true) ~= nil)

            if is_capacity_err then
                error("Variant " .. v .. " failed due to capacity instead of PermissionDenied")
            end
            if is_notfound_err then
                error("Variant " .. v .. " failed due to notfound instead of PermissionDenied")
            end
            if not is_perm_denied then
                error("Variant " .. v .. " did not yield host permission denial: " .. res.err_msg)
            end
        end
    end

    -- Phase 1: Negative Phase (supervisor host empty)
    run_negative_phase(1)

    -- Phase 2: Authorized probe child on supervisor host
    local token: string = "auth-token-" .. tostring(time.now())
    local child_pid_raw = assert(process.spawn_monitored("bee.hive_admission:probe", "bee.hive_admission:supervisor_host", self_pid, reply_topic, token))
    local child_pid: string = tostring(child_pid_raw)

    local child_host: string? = protocol.extract_pid_host(child_pid)
    if child_host ~= "bee.hive_admission:supervisor_host" then
        error("Authorized child PID host mismatch: expected bee.hive_admission:supervisor_host, got " .. tostring(child_host))
    end

    local deadline = time.after("5s")
    local got_reply: boolean = false
    local child_exited: boolean = false
    -- Topic messages and EXIT are independent channels; retain either ordering.
    while not got_reply or not child_exited do
        local sel = channel.select({replies:case_receive(), events:case_receive(), deadline:case_receive()})
        if not sel.ok then error("Channel closed waiting for child reply") end
        if sel.channel == deadline then
            error("Timeout waiting for child reply from supervisor host")
        elseif sel.channel == replies then
            local msg = sel.value
            local sender_pid: string = tostring(msg:from())
            if sender_pid ~= child_pid then
                error("Reply sender mismatch: expected " .. child_pid .. ", got " .. sender_pid)
            end
            local sender_host: string? = protocol.extract_pid_host(sender_pid)
            if sender_host ~= "bee.hive_admission:supervisor_host" then
                error("Sender PID does not show supervisor host: " .. sender_pid)
            end
            local reply = protocol.decode_probe_reply(msg:payload():data())
            if not reply then
                error("Invalid child reply payload: decode failed")
            end
            if reply.token ~= token then
                error("Token mismatch in probe reply")
            end
            got_reply = true
        elseif sel.channel == events then
            local ev = sel.value
            if ev.kind == process.event.EXIT and tostring(ev.from) == child_pid then
                if type(ev.result) == "table" and ev.result.error ~= nil then
                    error("Authorized child failed: " .. tostring(ev.result.error))
                end
                child_exited = true
            end
        end
    end

    -- Phase 3: Repeat negative phase (supervisor host empty again, restart vacancy exercised)
    run_negative_phase(2)

    process.unlisten(replies)

    return {status = "success", phases_completed = 3}
end

return {main = main}
