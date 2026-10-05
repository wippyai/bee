-- MIT. The public overlay facade projects storage vocabulary at its boundary.
local funcs = require("funcs")
local test = require("test")
local bounds = require("bounds")
local security = require("security")
local time = require("time")

local function call(request: unknown): {[string]: unknown}
    local result, err = funcs.call("bee.gov.binding:overlay_call", request)
    if type(result) ~= "table" then error(tostring(err or "overlay call returned no result")) end
    return assert(bounds.object(result))
end

local function call_as(actor_id: string, workspace_id: string, request: unknown): {[string]: unknown}
    local actor = assert(security.new_actor(actor_id, {workspace_id = workspace_id}))
    local result, err = funcs.new():with_actor(actor):call("bee.gov.binding:overlay_call", request)
    if type(result) ~= "table" then error(tostring(err or "overlay call returned no result")) end
    return assert(bounds.object(result))
end

local function define_tests()
    test.describe("Workspace-owned overlays", function()
        test.it("lets any agent of the workspace continue an overlay another agent started", function()
            local workspace = string.rep("a", 32)
            local overlay = "shared-" .. tostring(time.now():unix_nano())
            local created = call_as("agent-one", workspace, {operation = "create", overlay_id = overlay,
                expected_revision = 0, idempotency_key = overlay .. "-create"})
            test.is_true(created.ok == true, tostring(created.message))
            local first = call_as("agent-one", workspace, {operation = "put", overlay_id = overlay, expected_revision = 1,
                idempotency_key = overlay .. "-one", path = "app.lua", content = "return 1"})
            test.is_true(first.ok == true, tostring(first.message))
            local second = call_as("agent-two", workspace, {operation = "put", overlay_id = overlay, expected_revision = 2,
                idempotency_key = overlay .. "-two", path = "app.lua", content = "return 2"})
            test.is_true(second.ok == true, "a second agent of the workspace continues: " .. tostring(second.message))
            local other = call_as("agent-three", string.rep("b", 32), {operation = "put", overlay_id = overlay,
                expected_revision = 3, idempotency_key = overlay .. "-three", path = "app.lua", content = "return 3"})
            test.is_false(other.ok == true)
        end)
    end)
    test.describe("Source workspace authentication", function()
        test.it("refuses an author with no authenticated workspace metadata", function()
            local result = call({operation = "source", path = "bin/cli"})
            test.eq(result.code, "DENIED")
        end)
    end)
    test.describe("Governance overlay facade vocabulary", function()
        test.it("projects lower-layer workspace failures at the public boundary", function()
            local result = call({operation = "list", overlay_id = "method-vocabulary-missing"})
            test.is_false(result.ok == true)
            test.eq(result.code, "NOT_FOUND")
            test.eq(result.message, "overlay does not exist")
        end)

        test.it("uses overlay terminology for invalid public requests", function()
            local result = call({operation = "publish", overlay_id = "method-vocabulary-invalid"})
            test.is_false(result.ok == true)
            test.eq(result.code, "INVALID")
            test.eq(result.message, "unknown overlay operation")
        end)
    end)
end

return test.run_cases(define_tests)
