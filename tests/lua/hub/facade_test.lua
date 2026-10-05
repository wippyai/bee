-- MIT. The public Hub facade authorizes each operation against the caller's
-- grants before entering the private execution scope; apply runs in the
-- monitored publication worker and its result returns with the worker's exit.
local test = require("test")
local funcs = require("funcs")
local security = require("security")

type Result = {ok: boolean, code: string?, message: string?, value: unknown, replayed: boolean}

local HUB = "bee.hub.binding:call"

local function caller(names: {string}): funcs.Executor
    local policies: {security.Policy} = {}
    for index, name in ipairs(names) do
        local policy, err = security.policy(name)
        if not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return funcs.new():with_scope(security.new_scope(policies)):with_actor(security.new_actor("bee.tests.hub.person"))
end

local function call(executor: funcs.Executor, request: {[string]: unknown}): Result
    local reply, err = executor:call(HUB, request)
    if err then error("Hub facade: " .. tostring(err)) end
    if type(reply) ~= "table" or type(reply.ok) ~= "boolean" or type(reply.replayed) ~= "boolean" then error("invalid Hub reply") end
    return {ok = reply.ok, code = reply.code, message = reply.message, value = reply.value, replayed = reply.replayed}
end

local MODULES = {"bee.apps.modules:hub_client", "bee.apps.modules:hub_operations", "bee.apps.modules:self_update"}

local function define_tests()
    test.describe("Hub facade", function()
        test.it("denies an operation the caller holds no Hub grant for", function()
            local result = call(caller({"bee.apps.modules:hub_client"}), {operation = "installed"})
            test.eq(result.ok, false)
            test.eq(result.code, "DENIED")
        end)
        test.it("reads the update status with the Settings About grants only", function()
            local about = caller({"bee.apps.settings:hub_client", "bee.apps.settings:hub_updates"})
            local result = call(about, {operation = "updates"})
            test.is_true(result.ok, tostring(result.message))
            local value = result.value
            test.is_true(type(value) == "table" and type(value.modules) == "table" and type(value.bee_update) == "table")
            test.eq(call(about, {operation = "installed"}).code, "DENIED")
        end)
        test.it("refuses a Bee self-update plan without the self-update grant", function()
            local planner = caller({"bee.apps.modules:hub_client", "bee.apps.modules:hub_operations"})
            local result = call(planner, {operation = "plan", request = {action = "update", component = "bee/bee", version = "9.0.0"}})
            test.eq(result.ok, false)
            test.eq(result.code, "DENIED")
            test.eq(result.message, "Bee self-update is not authorized")
        end)
        test.it("returns the publication worker's result through its exit", function()
            local result = call(caller(MODULES), {operation = "apply", expected_digest = string.rep("a", 64),
                request = {action = "uninstall", component = "acme/absent"}})
            test.eq(result.ok, false)
            test.eq(result.code, "INVALID")
            test.eq(result.replayed, false)
            test.eq(result.message, "component has no installed Hub root")
        end)
        test.it("lists the caller's own operation history", function()
            local result = call(caller(MODULES), {operation = "status", request = {page = 1}})
            test.is_true(result.ok, tostring(result.message))
            local value = result.value
            test.is_true(type(value) == "table" and type(value.operations) == "table")
        end)
    end)
end

return test.run_cases(define_tests)
