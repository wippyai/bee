-- MIT. A driver's hook semantics come from its registry declaration.
local test = require("test")
local registry = require("registry")
local capabilities = require("capabilities")
local response = require("response")
local ID = "bee.tests.threads:echo_hooks"
local function declare(data: {[string]: unknown}?)
    local changes = assert(registry.snapshot()):changes()
    local entry = {id = ID, kind = "registry.entry", meta = {type = capabilities.TYPE, driver_id = "echoagent"}, data = data}
    if registry.get(ID) then
        if data then changes:update(entry) else changes:delete(ID) end
    elseif data then changes:create(entry) end
    assert(changes:apply())
end
local function define_tests()
    test.describe("Driver hook declarations", function()
        test.it("answers no hook point for a driver that declares none", function()
            for _, capability in ipairs(capabilities.for_driver("echoagent")) do
                test.is_false(capability.supported)
                test.eq(capability.reason, capabilities.UNDECLARED)
            end
            test.is_nil(capabilities.seconds("echoagent", "tool.before"))
        end)
        test.it("reads a new driver's declared points, transport and response", function()
            local ok, err = pcall(function()
                declare({response = "hook_specific_output", transport = "command", allow_on_change = true,
                    points = {["tool.before"] = {results = {"pass", "change", "deny"}, reason = "Echo PreToolUse"}}})
                local before = assert(capabilities.at("echoagent", "tool.before"))
                test.is_true(before.supported)
                test.is_true(capabilities.allows(before, "change"))
                test.is_false(capabilities.allows(before, "add_context"))
                test.is_false(assert(capabilities.at("echoagent", "tool.after")).supported)
                test.eq(capabilities.seconds("echoagent", "tool.before"), 3)
                local rendered = response.render("PreToolUse", {changed = true, input = {command = "ls"}}, "echoagent")
                test.eq(rendered.hookSpecificOutput.permissionDecision, "allow")
                declare({transport = "command", points = {["tool.before"] = {results = {"pass"}, reason = "no response named"}}})
                local refused = assert(capabilities.at("echoagent", "tool.before"))
                test.is_false(refused.supported)
                test.is_true(refused.reason:find("names its response", 1, true) ~= nil, refused.reason)
            end)
            declare(nil)
            if not ok then error(tostring(err)) end
        end)
        test.it("keeps each built-in driver's declared semantics", function()
            test.eq(#assert(capabilities.at("claude", "tool.after")).allowed_results, 3)
            test.eq(capabilities.seconds("claude", "session.start"), 3)
            test.eq(capabilities.seconds("claude", "tool.before"), 2)
            test.eq(capabilities.seconds("codex", "tool.before"), 2)
            test.is_false(assert(capabilities.at("opencode", "tool.before")).supported)
            test.eq(capabilities.declaration("wippy").response, "host")
            test.eq(capabilities.declaration("agy").input, "additive")
            test.eq(#assert(capabilities.mcp_meta()), 1)
        end)
    end)
end
return test.run_cases(define_tests)
