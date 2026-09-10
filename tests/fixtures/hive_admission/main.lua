-- SPDX-License-Identifier: MIT
-- CLI entrypoint for hive-admission-proof command.
local process = require("process")
local channel = require("channel")
local time = require("time")
local io = require("io")
local protocol = require("protocol")

type CoordinatorResult = {
    status: string,
    phases_completed: integer
}

local function main()
    -- When launched from terminal host, coordinate via worker process.
    local events = assert(process.events())
    local coordinator_pid_raw = assert(process.spawn_monitored("bee.hive_admission:coordinator", "bee.hive_admission:workers"))
    local coordinator_pid: string = tostring(coordinator_pid_raw)

    local deadline = time.after("15s")
    while true do
        local sel = channel.select({events:case_receive(), deadline:case_receive()})
        if not sel.ok then error("Channel closed waiting for coordinator") end
        if sel.channel == deadline then
            error("Timeout waiting for coordinator completion")
        end
        local ev = sel.value
        if ev.kind == process.event.EXIT and tostring(ev.from) == coordinator_pid then
            local res: CoordinatorResult? = nil
            if type(ev.result) == "table" then
                local raw_res = protocol.decode_coordinator_result(ev.result.value)
                if raw_res then res = raw_res end
            end
            if res and res.status == "success" and res.phases_completed == 3 then
                io.print("HIVE_HOST_ADMISSION_OK")
                return
            else
                local err_str: string = "unknown"
                if type(ev.result) == "table" and ev.result.error then
                    err_str = tostring(ev.result.error)
                end
                error("Coordinator failed: " .. err_str)
            end
        end
    end
end

return {main = main}
