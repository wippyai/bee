-- MIT. An application reaches node names only through the Library's two policies:
-- the call of the names read and the one action that read needs.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local system = require("system")
local bounds = require("bounds")
local app_scope = require("app_scope")

type Object = {[string]: unknown}

local WORKSPACE = "0123456789abcdef0123456789abcdef"

local function caller(policies: {string}): funcs.Executor
    local actor = assert(security.new_actor("bee.application:" .. WORKSPACE .. ":names-test", {workspace_id = WORKSPACE}))
    return funcs.new():with_actor(actor):with_scope(app_scope.boundary(policies))
end

local function define_tests()
    test.describe("Library node names", function()
        test.it("names this node for an application that holds the Library's policies", function()
            local node = assert(system.node.id())
            local raw, err = caller({"bee.apps.library:names_client", "bee.apps.library:names_read"})
                :call("bee.node.binding:names", {nodes = {node}})
            test.is_nil(err, tostring(err))
            local reply = assert(bounds.object(raw))
            test.is_true(reply.ok == true)
            local names = assert(bounds.object(assert(bounds.object(reply.value)).names))
            test.is_true(type(names[node]) == "string")
        end)

        test.it("refuses an application that may call the read but does not hold its action", function()
            local raw, err = caller({"bee.apps.library:names_client"}):call("bee.node.binding:names", {nodes = {assert(system.node.id())}})
            test.is_nil(err, tostring(err))
            local reply = assert(bounds.object(raw))
            test.is_false(reply.ok == true)
            test.eq(assert(bounds.object(reply.error)).code, "DENIED")
        end)
    end)
end

return test.run_cases(define_tests)
