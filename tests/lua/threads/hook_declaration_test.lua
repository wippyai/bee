-- MIT. A driver's hook semantics come from its registry declaration.
local test = require("test")
local registry = require("registry")
local capabilities = require("capabilities")
local response = require("response")
local security = require("security")
local ID = "bee.tests.echoagent.descriptor:hooks"
local MISNAMED = "bee.tests.threads:echo_hooks"
local function declare(data: {[string]: unknown}?, id: string?)
    local selected = id or ID
    local changes = assert(registry.snapshot()):changes()
    local entry = {id = selected, kind = "registry.entry", meta = {type = capabilities.TYPE, driver_id = "echoagent"}, data = data}
    if registry.get(selected) then
        if data then changes:update(entry) else changes:delete(selected) end
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
        test.it("lets a hook transport read hook declarations and no other entry", function()
            local scope = security.new_scope({assert(security.policy("bee.threads.hooks:declaration_read"))})
            local actor = security.new_actor("fixture:hook-endpoint", {})
            test.eq(scope:evaluate(actor, "registry.get", "bee.driver.claude.descriptor:hooks"), "allow")
            test.eq(scope:evaluate(actor, "registry.get", "bee.driver.echoagent.descriptor:hooks"), "allow")
            test.is_false(scope:evaluate(actor, "registry.get", "bee.driver.claude.descriptor:command") == "allow")
            test.is_false(scope:evaluate(actor, "registry.get", "bee.drivers.claude.binding:binding") == "allow")
            test.is_false(scope:evaluate(actor, "registry.get", "bee.gateway:external_profile") == "allow")
        end)
        test.it("refuses a declaration a hook transport could not read", function()
            local ok, err = pcall(function()
                declare({response = "hook_specific_output", transport = "command",
                    points = {["tool.before"] = {results = {"pass"}, reason = "misnamed"}}}, MISNAMED)
                local before = assert(capabilities.at("echoagent", "tool.before"))
                test.is_false(before.supported)
                test.is_true(before.reason:find("descriptor:hooks", 1, true) ~= nil, before.reason)
            end)
            declare(nil, MISNAMED)
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
