-- MIT. Explicit test host grants; no fixture identity grants itself authority.
local process = require("process")
local security = require("security")
local time = require("time")
local channel = require("channel")
local io = require("io")
local system = require("system")
local EXECUTION = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
local function main(node: string)
    local events, events_error = process.events()
    if not events then error(tostring(events_error)) end
    local supervisor: string? = nil
    if node == "node-0" then
        local policies: {security.Policy} = {}
        for _, name in ipairs({"bee:hive_supervisor_policy", "bee:hive_catalog_policy", "bee:hive_exposure_policy",
            "bee:hive_dispatch_policy", "bee.desktop_admission_probe:names", "bee.hive.desktop:host_policy"}) do
            local policy, err = security.policy(name)
            if not policy then error(tostring(err)) end
            policies[#policies + 1] = policy
        end
        local pid, err = process.with_options({}):with_scope(security.new_scope(policies)):spawn_monitored(
            "bee.hive.supervisor:main", "bee.hive:supervisor_host", {configured_nodes = {"node-1", "node-2"}, desktop = {
                execution = EXECUTION, expires_at = time.now():add("120s"):utc():format("2006-01-02T15:04:05.000Z07:00"),
                allowed_nodes = {"node-1", "node-2"}, application = "bee.console:app"}})
        if not pid then error(tostring(err)) end
        supervisor = tostring(pid)
        local timeout = time.after("2s")
        local observed = channel.select({events:case_receive(), timeout:case_receive()})
        if observed.ok and observed.channel == events then
            local result: unknown = observed.value.result
            if type(result) == "table" and result.error ~= nil then error("owner boot: " .. tostring(result.error)) end
            error("owner exited during startup")
        end
    end
    local addr, address_error = system.node.addr()
    if not addr then error(tostring(address_error)) end
    io.print("BEE_HIVE_SUPERVISOR ready " .. tostring(addr))
    while true do
        local command, command_error = io.readline()
        if not command then error(tostring(command_error)) end
        if command == "probe" or command == "crash" or command == "recover" or command == "exit" then
            local policy, err = security.policy("bee.desktop_admission_probe:client_policy")
            if not policy then error(tostring(err)) end
            local child, spawn_error = process.with_options({}):with_scope(security.new_scope({policy}))
                :spawn_monitored("bee.desktop_admission_probe:client", "bee.client:native", EXECUTION, command)
            if not child then error(tostring(spawn_error)) end
            local timeout = time.after("45s")
            while true do
                local selected = channel.select({events:case_receive(), timeout:case_receive()})
                if not selected.ok or selected.channel == timeout then error("desktop probe timed out") end
                if selected.channel == events and selected.value.kind == process.event.EXIT then
                    if tostring(selected.value.from) ~= tostring(child) then error("unexpected owner exit") end
                    local result: unknown = selected.value.result
                    if command == "crash" then
                        if type(result) ~= "table" or result.error == nil or not tostring(result.error):find("injected client crash", 1, true) then
                            error("client did not reach its injected crash")
                        end
                    elseif type(result) == "table" and result.error ~= nil then error(tostring(result.error)) end
                    break
                end
            end
            io.print("BEE_HIVE_SUPERVISOR probe_passed")
        elseif command == "stop" then
            if supervisor then process.cancel(supervisor) end
            io.print("BEE_HIVE_SUPERVISOR stopped")
            return
        else error("unknown fixture command") end
    end
end
return {main = main}
