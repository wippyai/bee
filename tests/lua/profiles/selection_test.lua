-- MIT. Saved profile discovery uses the authorized facade and exposes only
-- the saved identity plus the measured launch plan.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local uuid = require("uuid")
local bounds = require("bounds")
local selection = require("selection")

local WORKSPACE = "saved-profile-workspace"
local DEFINITION = "bee.driver.claude:default_window"

local function fresh(): string
    local id, err = uuid.v7()
    if not id then error(tostring(err)) end
    return id
end

local function policies(names: {string}): security.Scope
    local result: {security.Policy} = {}
    for _, name in ipairs(names) do
        local policy, err = security.policy(name)
        if not policy then error(tostring(err)) end
        result[#result + 1] = policy
    end
    return security.new_scope(result)
end

local function caller(id: string, write: boolean): funcs.Executor
    local grants = {"bee.harness.profiles:test_call", "bee.harness.profiles:test_read"}
    if write then grants[#grants + 1] = "bee.harness.profiles:test_write" end
    return funcs.new():with_actor(security.new_actor(id)):with_scope(policies(grants))
end

local function call(client: funcs.Executor, request: unknown): {[string]: unknown}
    local raw, err = client:call("bee.harness.profiles:call", request)
    if err then error(tostring(err)) end
    local reply = bounds.object(raw)
    if not reply then error("malformed profile reply") end
    return reply
end

local function value(reply: {[string]: unknown}): {[string]: unknown}
    if reply.ok ~= true then error(tostring(reply.code) .. ": " .. tostring(reply.message)) end
    local result = bounds.object(reply.value)
    if not result then error("missing profile value") end
    return result
end

local function put(client: funcs.Executor, id: string, title: string): {[string]: unknown}
    return value(call(client, {operation = "put", workspace_id = WORKSPACE, profile_id = id,
        expected_revision = 0, idempotency_key = fresh(), profile = {
            title = title, definition_ref = DEFINITION, options = {}, mcp_tools = {}, instructions = "",
        }}))
end

local function define_tests()
    test.describe("Saved profile launch selection", function()
        test.it("merges an authorized saved profile without exposing its values", function()
            local writer = caller("profile-selection-writer", true)
            local id = fresh()
            local saved = put(writer, id, "Personal Claude")
            test.eq(saved.revision, 1)

            local listed, err = selection.snapshot(WORKSPACE)
            if not listed then error(tostring(err)) end
            local found = false
            for _, item in ipairs(listed.items) do
                if item.saved_profile_id == id then
                    found = true
                    test.eq(item.saved_profile_revision, 1)
                    test.eq(item.title, "Personal Claude")
                    test.eq(item.definition_ref, DEFINITION)
                    test.eq(item.launch_id, "claude-window")
                    test.eq(item.summary, "Saved profile · Claude Code")
                    test.eq(#item.plan_digest, 64)
                    test.is_nil(item.unavailable)
                    test.is_nil((item :: {[string]: unknown}).instructions)
                    test.is_nil((item :: {[string]: unknown}).options)
                end
            end
            test.is_true(found)
        end)
    end)
end

return test.run_cases(define_tests)
