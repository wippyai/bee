-- SPDX-License-Identifier: MIT
local test = require("test")
local exchange = require("exchange")
local adapter = require("adapter")
local bounds = require("bounds")
local canonical = require("canonical")
local hash = require("hash")
local json = require("json")
local funcs = require("funcs")
local security = require("security")
local harness = require("harness")
type Object = {[string]: unknown}
local function digest(value: unknown): (string?, string?)
    local text, err = canonical.encode(value)
    if not text then return nil, err end
    return hash.sha256(text)
end
local function run()
    test.describe("Shared permission exchange", function()
        test.it("binds a canonical session turn to the real approvals owner without carrier lifecycle records", function()
            local workspace = string.rep("a", 32)
            local owner = harness.session_owner(workspace)
            local opened = harness.value(owner:call("session_create", {operation_key = harness.key()}))
            local stored = harness.value(owner:call("session_describe", {session = opened.session}))
            harness.value(owner:call("work_send", {session = opened.session, input = "touch proof.txt", operation_key = harness.key()}))
            local reserved = harness.value(owner:call("turn_reserve", {session = opened.session, operation_key = harness.key()}))
            local pulled = harness.value(owner:call("turn_pull", {turn = reserved.turn, claim = reserved.claim}))
            harness.value(owner:call("turn_accept", {turn = reserved.turn, claim = reserved.claim,
                input_digest = pulled.input_digest, checkpoint = {attempt_id = reserved.turn}, operation_key = harness.key()}))
            local grants: {security.Policy} = {}
            for _, name in ipairs(harness.ALL) do grants[#grants + 1] = assert(security.policy(name)) end
            for _, name in ipairs({"bee.approvals:client_test_policy", "bee.security.approvals:approval_request_policy"}) do
                grants[#grants + 1] = assert(security.policy(name))
            end
            local caller = funcs.new():with_actor(assert(security.new_actor(owner.id, {workspace_id = workspace}))):with_scope(security.new_scope(grants))
            local decoded = assert(adapter.decode("fixture:adapter", {
                schema_revision = "bee.permission-adapter@2", event_name = "fixture.permission", event_revision = "1",
                request = {correlation = "id", tool = "tool", input = "input"},
                response = {correlation_field = "id", decision_field = "decision", allow_value = "allow", deny_value = "deny"},
                acknowledgment = {mode = "continued_output"}, deny_acknowledgment = {mode = "unproven"},
                cancellation = "deny_before_close", proof_fixture = "fixture"}))
            local state: exchange.State = {request = {owner_id = owner.id, workspace_id = workspace,
                session_ref = assert(bounds.id(opened.session)), thread_id = assert(bounds.id(stored.thread_ref)),
                action_id = assert(bounds.id(opened.session)), attempt_id = assert(bounds.id(reserved.turn))},
                turn_id = assert(bounds.id(reserved.turn)), plan_digest = string.rep("a", 64), epoch = 1, permissions = {}, proposal_kind = "operation",
                exchange = {adapter = decoded, approver_policy = "workspace-application-delivery", poll_ms = 50, ttl_ms = 1000}}
            local ctx: exchange.Context = {state = state, now_ms = function(): integer return 0 end, approvals = "bee.approvals.binding",
                max_consume_attempts = 3, digest_of = digest, step = function(_: string) end,
                commit = function(_: {Object}): (boolean, string?) return true, nil end,
                call = function(target: string, fields: unknown): (unknown, string?)
                    local value, err = caller:call(target, fields)
                    return value, err and tostring(err) or nil
                end,
                waiting = function(): boolean return true end, settled = function(): boolean return false end,
                revalidate = function(): string? return nil end, write = function(_: string, _: string): (boolean, string?) return true, nil end}
            local records: {Object} = {{body = {type = "extension", event_key = "session-permission",
                data = {event_name = "fixture.permission", event_revision = "1", payload_json = json.encode({id = harness.key(),
                    tool = "Bash", input = {command = "touch proof.txt"}})}}}}
            test.eq(exchange.detect(ctx, records), 1)
            local ok, err = exchange.advance(ctx, false)
            test.ok(ok, tostring(err))
            test.eq(state.permissions[1].phase, "requested")
            test.not_nil(state.permissions[1].approval_id)
            local raw, read_error = caller:call("bee.approvals.binding:read", {approval_id = state.permissions[1].approval_id})
            test.eq(read_error, nil)
            local reply = assert(bounds.object(raw))
            test.eq(reply.ok, true)
            local approval = assert(bounds.object(reply.value))
            local proposal = assert(bounds.object(approval.proposal))
            test.eq(approval.thread_id, stored.thread_ref)
            test.eq(approval.contract_version, 2)
            local contract = assert(bounds.object(approval.contract))
            test.eq(assert(bounds.object(contract.origin)).attempt_id, reserved.turn)
            test.eq(assert(bounds.object(contract.origin)).session_id, opened.session)
            test.eq(assert(bounds.object(contract.scope)).type, "exact")
            test.eq(assert(bounds.object(proposal.payload)).tool_name, "Bash")
            test.eq(proposal.input_digest, assert(digest({command = "touch proof.txt"})))
            test.eq(proposal.kind, "operation")
            test.eq(proposal.ref, reserved.turn)
            test.eq(proposal.revision, state.plan_digest)
            test.eq(assert(bounds.object(proposal.payload)).session_ref, opened.session)
        end)
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
        test.it("uses a referenced runtime lease and refuses its revoked replay", function()
            local decoded = assert(adapter.decode("fixture:lease-adapter", {
                schema_revision = "bee.permission-adapter@2", event_name = "fixture.permission", event_revision = "1",
                request = {correlation = "id", tool = "tool", input = "input"},
                response = {correlation_field = "id", decision_field = "decision", allow_value = "allow", deny_value = "deny"},
                acknowledgment = {mode = "continued_output"}, deny_acknowledgment = {mode = "unproven"},
                cancellation = "deny_before_close", proof_fixture = "fixture"}))
            local point: exchange.State = {request = {owner_id = "owner", attempt_id = "attempt", action_id = "action", thread_id = "thread", workspace_id = "workspace",
                preferences = {options = {}, instructions = "", mcp_tools = {}, bee = {approval_leases = {"lease"}}}},
                plan_digest = string.rep("a", 64), epoch = 1, permissions = {}, exchange = {adapter = decoded, approver_policy = "policy", poll_ms = 50, ttl_ms = 1000, answer_mode = "ask"}}
            local writes, uses, revoked = 0, 0, false
            local ctx: exchange.Context = {state = point, now_ms = function(): integer return 0 end, approvals = "approvals", max_consume_attempts = 3,
                digest_of = digest, step = function(_: string) end, waiting = function(): boolean return true end, settled = function(): boolean return false end,
                revalidate = function(): string? return nil end, commit = function(_: {Object}): (boolean, string?) return true, nil end,
                write = function(_: string, line: string): (boolean, string?) writes = writes + 1; test.eq(assert(bounds.object(json.decode(line))).decision, "allow"); return true, nil end,
                call = function(target: string, raw: unknown): (unknown, string?)
                    test.eq(target, "approvals:runtime_lease")
                    local input = assert(bounds.object(raw))
                    test.eq(input.lease_ref, "lease"); test.eq(input.tool, "Bash"); test.eq(input.workspace_id, "workspace")
                    uses = uses + 1
                    if revoked then return {ok = false, error = {code = "DENIED", message = "revoked"}}, nil end
                    return {ok = true, value = {lease_ref = "lease", consumed = true}}, nil
                end}
            local records: {Object} = {{body = {type = "extension", event_key = "lease-request", data = {event_name = "fixture.permission", event_revision = "1",
                payload_json = json.encode({id = "req", tool = "Bash", input = {command = "ls"}})}}}}
            test.eq(exchange.detect(ctx, records), 1)
            test.is_true(exchange.advance(ctx, true))
            test.eq(writes, 1); test.eq(uses, 2); test.eq(point.permissions[1].lease_ref, "lease")
            point.permissions[1].phase = "consumed"; revoked = true
            test.is_false(exchange.advance(ctx, true))
            test.eq(writes, 1)
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
                            return {ok = true, value = {requesting_session = "session", approval_id = "approval", workspace_id = "workspace", proposal_digest = proposal_digest,
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
