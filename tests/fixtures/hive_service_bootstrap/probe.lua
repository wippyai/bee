-- MIT. Two-runtime native supervised service bootstrap probe.
local process = require("process")
local time = require("time")
local io = require("io")
local system = require("system")
local types = require("types")
local client = require("client")

local function main(remote: string)
    local deadline = time.now():add("10s")
    local sup_pid: string? = nil
    while time.now():before(deadline) do
        local pid, _ = client.supervisor()
        if pid then
            sup_pid = pid
            break
        end
        time.sleep("20ms")
    end
    if not sup_pid then
        local _, lookup_err = client.supervisor()
        error("supervisor did not register its local name: " .. tostring(lookup_err))
    end
    local _, host = types.pid_parts(sup_pid)
    if host ~= types.SUPERVISOR_HOST then
        error("supervisor host mismatch: expected " .. types.SUPERVISOR_HOST .. ", got " .. tostring(host))
    end
    assert(io.print("BEE_HIVE_SERVICE ready " .. tostring(assert(system.node.addr()))))

    while true do
        local command = tostring(assert(io.readline()))
        if command == "probe" then
            local handle, open_error = client.open()
            if not handle then error(tostring(open_error)) end
            local probe_deadline = time.now():add("30s")
            local reply: types.Reply? = nil
            while time.now():before(probe_deadline) do
                reply = handle:call({node_id = remote, service_id = "bee.hive.telemetry"},
                    {operation_ref = "bee.hive.telemetry:presence"}, {}, {timeout = "1s"})
                if reply.ok then break end
                if reply.error and reply.error.code ~= "UNAVAILABLE" then
                    error("remote call refused: " .. reply.error.code .. ": " .. reply.error.message)
                end
                time.sleep("100ms")
            end
            if not reply or not reply.ok then error("remote supervisor never established") end
            local value: unknown = reply.value
            if type(value) ~= "table" or value.node_id ~= remote then
                error("telemetry did not execute on destination")
            end
            local denied = handle:call({node_id = remote, service_id = "bee.hive.telemetry", resource_ref = "forbidden"},
                {operation_ref = "bee.hive.telemetry:stats"}, {}, {timeout = "3s"})
            if not denied.error or denied.error.code ~= "INVALID_ARGUMENT" then
                error("resource scope was not refused")
            end
            handle:close()
            assert(io.print("BEE_HIVE_SERVICE probe_passed"))
        elseif command == "verify-security" then
            -- 1. Deny spawning supervisor on protected supervisor host
            local p_pid, p_err = process.spawn("bee.hive.supervisor:main", types.SUPERVISOR_HOST)
            if p_pid ~= nil or p_err == nil then
                error("ordinary application was able to spawn on supervisor host: " .. tostring(p_pid))
            end

            -- 2. Deny spawning any process on protected supervisor host
            local h_pid, h_err = process.spawn("bee.hive.service.bootstrap:probe", types.SUPERVISOR_HOST)
            if h_pid ~= nil or h_err == nil then
                error("ordinary application was able to spawn probe on supervisor host: " .. tostring(h_pid))
            end

            -- 3. Deny actor-name registration (distinct from registry publication).
            local reg_ok, reg_err = process.registry.register("malicious.alias")
            if reg_ok ~= nil or reg_err == nil then
                error("ordinary application was able to register name: " .. tostring(reg_ok))
            end

            -- 4. Deny process cancel of supervisor
            local cancel_ok, cancel_err = process.cancel(sup_pid)
            if cancel_ok ~= nil or cancel_err == nil then
                error("ordinary application was able to cancel supervisor: " .. tostring(cancel_ok))
            end

            assert(io.print("BEE_HIVE_SERVICE security_verified"))
        elseif command == "stop" then
            assert(io.print("BEE_HIVE_SERVICE stopped"))
            return
        else
            error("unexpected command: " .. command)
        end
    end
end

return {main = main}
