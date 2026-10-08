-- SPDX-License-Identifier: MIT
local test = require("test")
local delivery = require("delivery")
local function define_tests()
    test.describe("OpenCode HTTP hook delivery", function()
        test.it("relays the existing allow and deny decisions to the permission API", function()
            for _, behavior in ipairs({"allow", "deny"}) do
                local reply: {[string]: unknown} = {}
                local id = ""
                test.is_true(delivery.send({submit = function(_: {[string]: unknown}): {[string]: unknown}?
                    return {hookSpecificOutput = {decision = {behavior = behavior, message = "Decision reason"}}}
                end, permission = function(request_id: string, body: {[string]: unknown}) id = request_id; reply = body end,
                record = function(_: string) error("permission delivery failed") end}, {hook_event_name = "PermissionRequest", permission_id = "per_fixture"}))
                test.eq(id, "per_fixture")
                test.eq(reply.reply, behavior == "allow" and "once" or "reject")
                test.eq(reply.message, "Decision reason")
            end
        end)
        test.it("records delivery and permission API failures without throwing or poisoning later events", function()
            local failures: {string} = {}
            local calls = {attempts = 0}
            local io = {submit = function(_: {[string]: unknown}): {[string]: unknown}?
                calls.attempts = calls.attempts + 1
                if calls.attempts == 1 then error("fixture HTTP failure") end
                return {hookSpecificOutput = {decision = {behavior = "allow"}}}
            end, permission = function(_: string, _: {[string]: unknown}) error("fixture permission API failure") end,
            record = function(detail: string) failures[#failures + 1] = detail end}
            test.is_false(delivery.send(io, {hook_event_name = "UserPromptSubmit"}))
            test.is_false(delivery.send(io, {hook_event_name = "PermissionRequest", permission_id = "p"}))
            test.is_true(delivery.send(io, {hook_event_name = "Stop"}))
            test.eq(#failures, 2)
            test.eq(calls.attempts, 3)
        end)
    end)
end
return test.run_cases(define_tests)
