-- MIT. Actual supervisor process: local client, asynchronous dispatch and refusal.
local test = require("test")
local process = require("process")
local time = require("time")
local channel = require("channel")
local security = require("security")
local types = require("types")
local client = require("client")
local function define_tests()
    test.describe("Hive supervisor process", function()
        test.it("serves bounded telemetry and retains authority after rejected calls", function()
            local events = assert(process.events())
            local policies: {security.Policy} = {}
            for _, name in ipairs({"bee:hive_supervisor_policy", "bee:hive_catalog_policy", "bee:hive_exposure_policy",
                "bee:hive_dispatch_policy", "bee.hive.supervisor:execute_policy", "bee.hive.supervisor:local_name_policy"}) do
                local policy, err = security.policy(name)
                if not policy then error(tostring(err)) end
                policies[#policies + 1] = policy
            end
            local supervisor = tostring(assert(process.with_options({}):with_scope(security.new_scope(policies))
                :spawn_monitored("bee.hive.supervisor:main", types.SUPERVISOR_HOST, {configured_nodes = {}})))
            local handle = assert(client.open())
            local ok, err = pcall(function()
                local timeout = time.now():add("3s")
                local found: string? = nil
                while not found and time.now():before(timeout) do
                    found = client.supervisor()
                    if not found then time.sleep("10ms") end
                end
                test.eq(found, tostring(supervisor))
                local node = types.pid_parts(tostring(process.pid()))
                if not node then error("native node") end
                if node == "" then node = "local" end
                local owner: types.OwnerRef = {node_id = node, service_id = "bee.hive.telemetry"}
                local target: types.Target = {operation_ref = "bee.hive.telemetry:stats"}
                local result = handle:call(owner, target, {}, {timeout = "3s"})
                if not result.ok then error("supervisor stats failed: " .. tostring(result.error and result.error.message)) end
                test.is_true(type(result.value) == "table")
                local wrong = handle:call({node_id = node, service_id = "wrong"}, target, {}, {timeout = "3s"})
                test.eq(wrong.error and wrong.error.code, "INVALID_ARGUMENT")
                local foreign = handle:call({node_id = "not-enrolled", service_id = "bee.hive.telemetry"}, target, {}, {timeout = "3s"})
                test.eq(foreign.error and foreign.error.code, "UNAVAILABLE")
                local invalid = handle:call(owner, target, {extra = true}, {timeout = "3s"})
                test.is_false(invalid.ok)
                local again = handle:call(owner, {operation_ref = "bee.hive.telemetry:presence"}, {}, {timeout = "3s"})
                test.is_true(again.ok)
            end)
            handle:close()
            local canceled, cancel_error = process.cancel(supervisor)
            if not canceled then error("supervisor stopped: " .. tostring(cancel_error) .. "; test: " .. tostring(err)) end
            local deadline = time.after("3s")
            while true do
                local selected = channel.select({events:case_receive(), deadline:case_receive()})
                if selected.channel == deadline or not selected.ok then error("supervisor did not stop") end
                if selected.value.kind == process.event.EXIT and tostring(selected.value.from) == tostring(supervisor) then
                    local result: unknown = selected.value.result
                    if type(result) == "table" and result.error ~= nil then error("supervisor exit: " .. tostring(result.error)) end
                    break
                end
            end
            if not ok then error(tostring(err)) end
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
