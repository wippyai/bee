-- MIT. The functions an app calls run in the app's scope, so the boundary
-- every app runs in leaves the node's stores to the functions that own them:
-- Sessions lists its sessions from inside its own scope.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local system = require("system")
local bounds = require("bounds")
local client = require("client")
local app_scope = require("app_scope")

local function home(): string
    local value, err = client.call(assert(system.node.id()), "watch", {})
    if not value then error("watch: " .. tostring(err)) end
    return assert(client.state(value)).home
end

local function define_tests()
    test.describe("application scope", function()
        test.it("lets the Inbox read its node and reach the hive from inside its scope", function()
            local workspace = home()
            local actor = assert(security.new_actor("bee.application:" .. workspace .. ":inbox-scope-test",
                {workspace_id = workspace, definition_id = "bee.approvals.inbox.app:app", definition_revision = "1", execution_generation = 1}))
            local scope = app_scope.scope("bee.approvals.inbox.app:app")
            test.eq(scope:evaluate(actor, "system.read", "node"), "allow")
            test.eq(scope:evaluate(actor, "system.read", "cluster"), "allow")
        end)

        test.it("lets Sessions list sessions through the store functions from inside its scope", function()
            local workspace = home()
            local actor = assert(security.new_actor("bee.application:" .. workspace .. ":sessions-scope-test",
                {workspace_id = workspace, definition_id = "bee.harness.app:app", definition_revision = "1", execution_generation = 1}))
            local executor = funcs.new():with_actor(actor):with_scope(app_scope.scope("bee.harness.app:app", nil, true))
            local raw, err = executor:call("bee.threads.sessions.binding:list", {})
            test.is_nil(err, tostring(err))
            local reply = assert(bounds.object(raw))
            local fault = bounds.object(reply.error)
            test.is_true(reply.ok == true, "list refused: " .. tostring(fault and fault.message))
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
