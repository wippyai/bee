-- SPDX-License-Identifier: MIT
local test = require("test")
local registry = require("registry")
local json = require("json")
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local adapter = require("adapter")
local exchange = require("exchange")
local hook_exchange = require("hook_exchange")
local hooks = require("hooks")
type Object = {[string]: unknown}
local function digest(value: unknown): (string?, string?)
    local text, err = canonical.encode(value)
    if not text then return nil, err end
    return hash.sha256(text)
end
local function run()
    test.describe("Carrier permission hook exchange", function()
        for _, decision in ipairs({"approved", "denied"}) do
            test.it("persists and replays one " .. decision .. " response without a stdin write", function()
                local entry = assert(registry.get("bee.driver.permission:permission_request_hook"))
                local decoded = assert(adapter.decode(entry.id, assert(bounds.object(entry.data)).adapter))
                local state: exchange.State = {request = {owner_id = "owner", attempt_id = "attempt", action_id = "action", thread_id = "thread",
                        workspace_id = "workspace"}, plan_digest = string.rep("a", 64), epoch = 1, permissions = {},
                    exchange = {adapter = decoded, approver_policy = "policy", poll_ms = 50, ttl_ms = 1000}}
                local requested, consumed, prepared = 0, 0, 0
                local proposal_digest = ""
                local revoked = false
                local ctx: exchange.Context = {state = state, approvals = "approvals", max_consume_attempts = 3,
                    now_ms = function(): integer return 0 end, digest_of = digest, step = function(_: string) end,
                    waiting = function(): boolean return true end, settled = function(): boolean return false end,
                    revalidate = function(): string? return revoked and "attachment changed" or nil end,
                    commit = function(_: {Object}): (boolean, string?) return true, nil end,
                    write = function(_: string, line: string): (boolean, string?)
                        prepared = prepared + 1
                        test.eq(assert(bounds.object(assert(bounds.object(json.decode(line))).hookSpecificOutput)).hookEventName, "PermissionRequest")
                        return true, nil
                    end,
                    call = function(target: string, input: unknown): (unknown, string?)
                        local fields = assert(bounds.object(input))
                        if target == "approvals:request" then
                            requested = requested + 1; proposal_digest = assert(digest(fields.proposal))
                            return {ok = true, value = {approval_id = "approval", workspace_id = "workspace", proposal_digest = proposal_digest,
                                owner_incarnation = 1, state = "pending"}}, nil
                        elseif target == "approvals:consume" then consumed = consumed + 1; return {ok = true, value = {}}, nil end
                        test.eq(target, "approvals:read")
                        return {ok = true, value = {approval_id = "approval", workspace_id = "workspace", proposal_digest = proposal_digest,
                            owner_incarnation = 1, state = "decided", decision = decision}}, nil
                    end}
                local payload: Object = {session_id = "native-session", tool_name = "bash", tool_input = {command = "printf fixture-tool"}}
                local normalized = assert(hooks.normalize("PermissionRequest", payload))
                local evidence: Object = {event_id = "hook-1", event = "PermissionRequest", digest = normalized.digest, status = "queued"}
                local altered: Object = {session_id = "native-session", tool_name = "bash", tool_input = {command = "altered"}}
                test.is_false(hook_exchange.request(ctx, "hook-1", altered, evidence))
                test.eq(#state.permissions, 0)
                test.is_true(hook_exchange.request(ctx, "hook-1", payload, evidence))
                test.is_nil(hook_exchange.response(ctx, "hook-1"))
                test.is_true(exchange.advance(ctx, true))
                local line = assert(hook_exchange.response(ctx, "hook-1"))
                local output = assert(bounds.object(assert(bounds.object(json.decode(line))).hookSpecificOutput))
                test.eq(assert(bounds.object(output.decision)).behavior, decision == "approved" and "allow" or "deny")
                test.is_true(hook_exchange.request(ctx, "hook-1", payload, evidence))
                test.is_true(exchange.advance(ctx, true))
                test.eq(hook_exchange.response(ctx, "hook-1"), line)
                test.eq(requested, 1); test.eq(consumed, decision == "approved" and 1 or 0); test.eq(prepared, 1)
                revoked = true
                local replay, err = hook_exchange.response(ctx, "hook-1")
                test.is_nil(replay); test.eq(err, "attachment changed")
            end)
        end
    end)
end
return test.run_cases(run)
