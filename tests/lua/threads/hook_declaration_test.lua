-- MIT. A driver's hook semantics come from its registry declaration.
local test = require("test")
local registry = require("registry")
local capabilities = require("capabilities")
local response = require("response")
local security = require("security")
local funcs = require("funcs")
local canonical = require("canonical")
local ID = "bee.tests.threads:echo_hooks"
local READ = "bee.threads.sessions.security:owner_registry_read_policy"
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
                declare({response = "bee.driver.descriptor:hook_specific_output_allowing_changes", transport = "command",
                    points = {["tool.before"] = {results = {"pass", "change", "deny"}, reason = "Echo PreToolUse"}}})
                local before = assert(capabilities.at("echoagent", "tool.before"))
                test.is_true(before.supported)
                test.is_true(capabilities.allows(before, "change"))
                test.is_false(capabilities.allows(before, "add_context"))
                test.is_false(assert(capabilities.at("echoagent", "tool.after")).supported)
                test.eq(capabilities.seconds("echoagent", "tool.before"), 3)
                local rendered = assert(response.render("PreToolUse", {changed = true, input = {command = "ls"}}, "echoagent"))
                test.eq(rendered.hookSpecificOutput.permissionDecision, "allow")
                declare({transport = "command", points = {["tool.before"] = {results = {"pass"}, reason = "no response named"}}})
                local refused = assert(capabilities.at("echoagent", "tool.before"))
                test.is_false(refused.supported)
                test.is_true(refused.reason:find("names its response", 1, true) ~= nil, refused.reason)
            end)
            declare(nil)
            if not ok then error(tostring(err)) end
        end)
        test.it("is found by meta under any id with the Agents stack's registry read", function()
            local ok, err = pcall(function()
                declare({response = "bee.driver.descriptor:hook_specific_output", transport = "command",
                    points = {["tool.before"] = {results = {"pass", "deny"}, reason = "Echo PreToolUse"}}})
                local scope = security.new_scope({assert(security.policy(READ))})
                local actor = security.new_actor("fixture:hook-endpoint", {})
                local found, find_error = funcs.new():with_actor(actor):with_scope(scope):call("bee.tests.threads:hook_declaration_probe", "echoagent")
                test.is_nil(find_error, tostring(find_error))
                test.eq(found, "Echo PreToolUse")
            end)
            declare(nil)
            if not ok then error(tostring(err)) end
        end)
        test.it("gives the registry read to the hook endpoints and not to a launched agent's tool scope", function()
            for _, id in ipairs({"bee.gateway.api:hook_http", "bee.gateway.api:hook_mcp_http"}) do
                local entry = assert(registry.get(id)) :: {[string]: any}
                local granted = false
                for _, policy in ipairs(entry.data.security.policies) do if policy == READ then granted = true end end
                test.is_true(granted, id .. " reads the drivers' hook declarations")
            end
            local actor = security.new_actor("fixture:agent-session", {})
            local agent = security.new_scope({assert(security.policy("bee.security.gateway:gateway_tool_session_policy"))})
            test.is_false(agent:evaluate(actor, "registry.get", "bee.drivers.claude.binding:binding") == "allow",
                "an agent session's gateway tool scope reads no arbitrary entry")
            local stack = security.new_scope({assert(security.policy(READ))})
            test.eq(stack:evaluate(actor, "registry.get", "bee.drivers.claude.binding:binding"), "allow")
        end)
        test.it("keeps each built-in driver's declared semantics", function()
            test.eq(#assert(capabilities.at("claude", "tool.after")).allowed_results, 3)
            test.eq(capabilities.seconds("claude", "session.start"), 3)
            test.eq(capabilities.seconds("claude", "tool.before"), 2)
            test.eq(capabilities.seconds("codex", "tool.before"), 2)
            test.is_false(assert(capabilities.at("opencode", "tool.before")).supported)
            test.is_true(capabilities.declaration("wippy").host)
            test.eq(capabilities.declaration("agy").input, "additive")
            test.eq(#assert(capabilities.mcp_meta()), 1)
        end)
        test.it("shapes each built-in driver's answers as its CLI reads them", function()
            local cases = {
                {"claude", "PreToolUse", {denied = true, reason = "no", additional_context = "ctx"},
                    '{"hookSpecificOutput":{"additionalContext":"ctx","hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"no"}}'},
                {"claude", "UserPromptSubmit", {denied = true, reason = "no"}, '{"decision":"block","reason":"no"}'},
                {"claude", "PreToolUse", {changed = true, input = {command = "ls"}}, '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{"command":"ls"}}}'},
                {"codex", "PreToolUse", {changed = true, input = {command = "ls"}}, '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":"ls"}}}'},
                {"claude", "PostToolUse", {original_refs = {"r"}, output = "x"}, '{"hookSpecificOutput":{"hookEventName":"PostToolUse","updatedToolOutput":"x"}}'},
                {"claude", "PostToolUse", {original_refs = {}, additional_context = ""}, "{}"},
                {"agy", "PreToolUse", {denied = true, reason = "no", changed = true, input = {a = 1}}, '{"decision":"deny","reason":"no"}'},
                {"agy", "PreToolUse", {changed = true, input = {a = 1}, additional_context = "ctx"}, '{"overwrite":{"a":1}}'},
                {"agy", "UserPromptSubmit", {denied = true, reason = "no", additional_context = "ctx"}, '{"injectSteps":[{"ephemeralMessage":"ctx"}]}'},
                {"agy", "PostToolUse", {original_refs = {"r"}, output = "x"}, "{}"},
            }
            for _, case in ipairs(cases) do
                local rendered, render_error = response.render(case[2], case[3], case[1])
                local answer = assert(rendered, render_error)
                if case[4] == "{}" then test.is_nil(next(answer), case[1] .. " " .. case[2])
                else test.eq(canonical.encode(answer), case[4], case[1] .. " " .. case[2]) end
            end
            local decision = {hookSpecificOutput = {hookEventName = "PermissionRequest", decision = {behavior = "deny", message = "no"}}}
            test.eq(canonical.encode(assert(response.permission(decision, "agy"))), '{"decision":"deny","reason":"no"}')
            local allowed = {hookSpecificOutput = {hookEventName = "PermissionRequest", decision = {behavior = "allow"}}}
            test.eq(canonical.encode(assert(response.permission(allowed, "agy"))), '{"decision":"allow"}')
            test.eq(assert(response.permission(decision, "claude")), decision)
        end)
    end)
end
return test.run_cases(define_tests)
