-- MIT. A removed session's approval requests end: pending ones are
-- withdrawn, and when its thread goes with it no request or undelivered
-- thread post names that thread.
local test = require("test")
local bounds = require("bounds")
local funcs = require("funcs")
local service = require("service")
local thread_harness = require("thread_harness")
local fixture = require("fixture").new()
type Object = {[string]: unknown}
local POLICY = fixture.POLICY
local key = fixture.key
local caller = fixture.caller
local call = fixture.call
local value = fixture.value
local code = fixture.code
local proposal = fixture.proposal
local install_policy = fixture.install_policy

local remover = caller("bee.test.remover", {"bee.tests.approvals:forget_session_test_policy"})

local function opened(workspace: string): (string, string, funcs.Executor)
    local journal = thread_harness.session_owner(workspace)
    local created = thread_harness.value(journal:call("session_create", {operation_key = key(), route = {delivery = "hook", definition = "bee.harness.app:app"}}))
    local session = assert(bounds.id(created.session))
    local thread = assert(bounds.id(thread_harness.value(journal:call("session_describe", {session = session})).thread_ref))
    local agent = caller(session, {"bee.security.approvals:approval_request_policy", "bee.threads.security:observe"}, {workspace_id = workspace})
    return session, thread, agent
end

local function count(statement: string, params: {unknown}): integer
    local db = assert(service.open())
    local rows = assert(db:query(statement, params))
    db:release()
    return math.floor(tonumber(rows[1].count) or -1)
end

local function define_tests()
    test.describe("Approvals of a removed session", function()
        fixture.setup("bee.tests.approvals:forget_session_db", true)
        test.it("withdraws the session's pending requests and keeps them on a kept thread", function()
            install_policy()
            local workspace = string.rep("e", 32)
            local session, thread, agent = opened(workspace)
            local created = value(call(agent, "request", {workspace_id = workspace, idempotency_key = key(), policy = POLICY,
                request_kind = "permission", proposal = proposal(), prompt = {text = "Use Hub?"}, thread_id = thread, ttl_ms = 60000}))
            local forgotten = value(call(remover, "forget_session", {session = session, thread_id = thread, owner_id = "bee.test.owner", history = false}))
            test.eq(forgotten.withdrawn, 1)
            local read = value(call(fixture.manager, "read", {approval_id = created.approval_id}))
            test.eq(read.state, "withdrawn")
            test.eq(count("SELECT COUNT(*) AS count FROM bee_approval_requests WHERE thread_id = ?", {thread}), 1)
            local again = value(call(remover, "forget_session", {session = session, thread_id = thread, owner_id = "bee.test.owner", history = false}))
            test.eq(again.withdrawn, 0)
        end)
        test.it("leaves no request or undelivered post naming a thread removed with the session", function()
            install_policy()
            local workspace = string.rep("f", 32)
            local session, thread, agent = opened(workspace)
            value(call(agent, "request", {workspace_id = workspace, idempotency_key = key(), policy = POLICY,
                request_kind = "permission", proposal = proposal(), prompt = {text = "Use Library?"}, thread_id = thread, ttl_ms = 60000}))
            value(call(remover, "forget_session", {session = session, thread_id = thread, owner_id = "bee.test.owner", history = true}))
            test.eq(count("SELECT COUNT(*) AS count FROM bee_approval_requests WHERE thread_id = ?", {thread}), 0)
            test.eq(count("SELECT COUNT(*) AS count FROM bee_approval_outbox WHERE thread_id = ?", {thread}), 0)
            test.eq(count("SELECT COUNT(*) AS count FROM bee_approval_requests WHERE requester_id = ? AND state = 'pending'", {session}), 0)
        end)
        test.it("refuses a caller that does not remove the session", function()
            local workspace = string.rep("e", 32)
            local session, thread = opened(workspace)
            test.eq(code(call(fixture.outsider, "forget_session", {session = session, thread_id = thread, owner_id = "bee.test.owner", history = true})), "DENIED")
        end)
    end)
end
return test.run_cases(define_tests)
