-- SPDX-License-Identifier: MIT
local test = require("test")
local exchange = require("exchange")
local adapter = require("adapter")
local bounds = require("bounds")
local canonical = require("canonical")
local hash = require("hash")
local json = require("json")
type Object = {[string]: unknown}
local function digest(value: unknown): (string?, string?)
    local text, err = canonical.encode(value)
    if not text then return nil, err end
    return hash.sha256(text)
end
local function run()
    test.describe("Shared permission exchange", function()
        test.it("encodes hook answers without inventing a protocol correlation field", function()
            local hook = assert(adapter.decode("fixture:hook", {
                schema_revision = "bee.permission-adapter@2", event_name = "permission.hook", event_revision = "1",
                request = {correlation = "event_id", tool = "tool_name", input = "tool_input"},
                response = {mode = "hook", envelope = {hookSpecificOutput = {hookEventName = "PermissionRequest"}},
                    decision_field = "hookSpecificOutput.decision.behavior", allow_value = "allow", deny_value = "deny",
                    reason_field = "hookSpecificOutput.decision.message"},
                acknowledgment = {mode = "continued_output"}, deny_acknowledgment = {mode = "unproven"},
                cancellation = "deny_before_close", proof_fixture = "hook"}))
            local found = assert(adapter.request(hook, {type = "extension", event_key = "hook:1",
                data = {event_name = "permission.hook", event_revision = "1", payload_json = json.encode({event_id = "hook:1",
                    tool_name = "Bash", tool_input = {command = "touch proof.txt"}})}}))
            local denied = assert(bounds.object(json.decode(assert(adapter.deny(hook, found, "person denied")))))
            test.eq(denied.id, nil)
            local output = assert(bounds.object(denied.hookSpecificOutput))
            test.eq(output.hookEventName, "PermissionRequest")
            local decision = assert(bounds.object(output.decision))
            test.eq(decision.behavior, "deny")
            test.eq(decision.message, "person denied")
        end)
        test.it("checkpoints the command and consumes only Allow before writing", function()
            local decoded = assert(adapter.decode("fixture:adapter", {
                schema_revision = "bee.permission-adapter@2", event_name = "fixture.permission", event_revision = "1",
                request = {correlation = "id", tool = "tool", input = "input", prompt = "description"},
                response = {envelope = {}, correlation_field = "id", decision_field = "decision", allow_value = "allow", deny_value = "deny"},
                acknowledgment = {mode = "continued_output"}, deny_acknowledgment = {mode = "unproven"},
                cancellation = "deny_before_close", proof_fixture = "fixture"}))
            for _, decision in ipairs({"approved", "denied", "expired", "withdrawn", "automatic_deny"}) do
                local point: exchange.State = {request = {owner_id = "owner", attempt_id = "attempt", action_id = "action", thread_id = "thread",
                    workspace_id = "workspace", session_ref = "session"}, plan_digest = string.rep("a", 64), epoch = 1,
                    exchange = {adapter = decoded, approver_policy = "policy", poll_ms = 50, ttl_ms = 1000, answer_mode = decision == "automatic_deny" and "deny" or "ask"}, permissions = {}}
                local proposal_digest = ""
                local consumes, writes, commits = 0, 0, 0
                local ctx: exchange.Context = {state = point, now_ms = function(): integer return 0 end, max_consume_attempts = 3, approvals = "approvals",
                    digest_of = digest, step = function(_: string) end,
                    waiting = function(): boolean return true end, settled = function(): boolean return false end,
                    revalidate = function(): string? return nil end,
                    commit = function(records: {Object}): (boolean, string?)
                        commits = commits + 1
                        test.ok(#point.permissions > 0)
                        return true, nil
                    end,
                    write = function(_: string, line: string): (boolean, string?)
                        writes = writes + 1
                        local body = assert(bounds.object(json.decode(line)))
                        test.eq(body.decision, decision == "approved" and "allow" or "deny")
                        test.ok(commits >= 3)
                        return true, nil
                    end,
                    call = function(target: string, fields: unknown): (unknown, string?)
                        if decision == "automatic_deny" then error("Deny preference must not request or consume an approval") end
                        local input = assert(bounds.object(fields))
                        if target == "approvals:consume" then consumes = consumes + 1; return {ok = true, value = {}}, nil end
                        if target == "approvals:request" then
                            proposal_digest = assert(digest(input.proposal))
                            local prompt = assert(bounds.object(input.prompt))
                            local text = assert(bounds.text(prompt.text))
                            for _, label in ipairs({"session", "workspace", "Bash", "touch proof.txt", "leave a marker"}) do
                                test.ok(text:find(label, 1, true) ~= nil, text)
                            end
                            return {ok = true, value = {approval_id = "approval", workspace_id = "workspace", proposal_digest = proposal_digest,
                                owner_incarnation = 1, state = "pending"}}, nil
                        end
                        return {ok = true, value = {approval_id = "approval", workspace_id = "workspace", proposal_digest = proposal_digest,
                            owner_incarnation = 1, state = (decision == "approved" or decision == "denied") and "decided" or decision,
                            decision = (decision == "approved" or decision == "denied") and decision or nil}}, nil
                    end}
                local records: {Object} = {{body = {type = "extension", event_key = "request:1",
                    data = {event_name = "fixture.permission", event_revision = "1", payload_json = json.encode({id = "req", tool = "Bash",
                        input = {command = "touch proof.txt"}, description = "leave a marker"})}}}}
                test.eq(exchange.detect(ctx, records), 1)
                test.ok(ctx.commit(records))
                test.ok(exchange.advance(ctx, true))
                test.eq(writes, 1)
                test.eq(consumes, decision == "approved" and 1 or 0)
                test.ok(exchange.advance(ctx, true))
                test.eq(writes, 1)
                test.eq(exchange.detect(ctx, records), 0)
            end
        end)
    end)
end
return test.run_cases(run)
