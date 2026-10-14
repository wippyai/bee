-- MIT. The Sessions owner waits for work within the caller's timeout and
-- wakes when the work settles; a timeout reports pending and cancels nothing.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local harness = require("harness")
local json = require("json")
local session_tools = require("session_tools")

local WORKSPACE = string.rep("c", 32)
local CALLER_POLICY = "bee.tests.sessions:await_test_caller"

local function caller(): funcs.Executor
    local actor = assert(security.new_actor("await-test-agent", {workspace_id = WORKSPACE}))
    local policy = assert(security.policy(CALLER_POLICY))
    return assert(funcs.new():with_actor(actor):with_scope(security.new_scope({policy})))
end

local function value(result: unknown, err: unknown): {[string]: unknown}
    if err then error(tostring(err)) end
    local reply = assert(bounds.object(result))
    if reply.ok ~= true then error("owner refused: " .. tostring(bounds.object(reply.error) and assert(bounds.object(reply.error)).message)) end
    return assert(bounds.object(reply.value))
end

local function owner_call(method: string, request: {[string]: unknown}): {[string]: unknown}
    return value(caller():call("bee.threads.sessions.binding:" .. method, request))
end

local function owner_start(method: string, request: {[string]: unknown}): funcs.Future
    local future, err = caller():async("bee.threads.sessions.binding:" .. method, request)
    if err or not future then error("async " .. method .. ": " .. tostring(err)) end
    return future
end

local function owner_await(future: funcs.Future): {[string]: unknown}
    local _, open = future:response():receive()
    if not open then error("owner call closed without a reply") end
    local result, err = future:result()
    if err or not result then error("owner call: " .. tostring(err)) end
    return value(result:data(), nil)
end

local function settle(journal: harness.Client, session: string, usage: {[string]: unknown}?)
    local reservation = harness.value(journal:call("turn_reserve", {session = session, operation_key = harness.key()}))
    local envelope = harness.value(journal:call("turn_pull", {turn = reservation.turn, claim = reservation.claim}))
    harness.value(journal:call("turn_accept", {turn = reservation.turn, claim = reservation.claim,
        input_digest = envelope.input_digest, checkpoint = {}, operation_key = harness.key()}))
    harness.value(journal:call("work_settle", {turn = reservation.turn, claim = reservation.claim,
        result = {state = "succeeded", schema = "bee:Text@1", value = {text = "done"}, usage = usage}, operation_key = harness.key()}))
end

local function define_tests()
    test.describe("Sessions await", function()
        test.it("waits for work within the timeout and wakes when it settles", function()
            local journal = harness.session_owner(WORKSPACE)
            local session = harness.value(journal:call("session_create", {operation_key = harness.key()})).session
            local work = harness.value(journal:call("work_send", {session = session, operation_key = harness.key(), input = "wait for me"})).work

            local immediate = owner_call("await", {subject = work, timeout_ms = 0})
            test.eq(immediate.tag, "pending")

            local blocked = owner_start("await", {subject = work, timeout_ms = 20000})
            settle(journal, tostring(session))
            local woke = owner_await(blocked)
            test.eq(woke.tag, "ready")
            test.eq(assert(bounds.object(woke.result)).outcome, "succeeded")

            local later = harness.value(journal:call("work_send", {session = session, operation_key = harness.key(), input = "never served"})).work
            local quiet = owner_call("await", {subject = later, timeout_ms = 300})
            test.eq(quiet.tag, "pending")
            test.eq(quiet.reason, "timeout")
            test.eq(harness.value(journal:call("work_describe", {work = later})).phase, "queued")
        end)

        test.it("preserves empty and populated usage as JSON objects in settled replies", function()
            local journal = harness.session_owner(WORKSPACE)
            for _, usage in ipairs({{}, {input_tokens = 2, output_tokens = 4}}) do
                local session = harness.value(journal:call("session_create", {operation_key = harness.key()})).session
                local work = harness.value(journal:call("work_send", {session = session, operation_key = harness.key(), input = "usage"})).work
                settle(journal, tostring(session), usage)
                local reply = owner_call("await", {subject = work, timeout_ms = 0})
                local result = assert(bounds.object(reply.result))
                local reported = assert(bounds.object(result.usage))
                test.eq(reported.input_tokens, usage.input_tokens)
                test.eq(reported.output_tokens, usage.output_tokens)
                local valid, failure = json.validate_string(assert(json.encode(session_tools.OUTPUT_SCHEMAS.session_await)),
                    assert(json.encode({ok = true, value = reply})))
                test.is_true(valid, tostring(failure))
            end
        end)
        test.it("joins works across sessions, deciding as each settles", function()
            local journal = harness.session_owner(WORKSPACE)
            local first_session = harness.value(journal:call("session_create", {operation_key = harness.key()})).session
            local second_session = harness.value(journal:call("session_create", {operation_key = harness.key()})).session
            local first = harness.value(journal:call("work_send", {session = first_session, operation_key = harness.key(), input = "one"})).work
            local second = harness.value(journal:call("work_send", {session = second_session, operation_key = harness.key(), input = "two"})).work

            local any = owner_start("join", {works = {first, second}, policy = "first_success", timeout_ms = 20000, operation_key = harness.key()})
            settle(journal, tostring(second_session))
            local winner = owner_await(any)
            test.eq(winner.tag, "ready")
            test.eq(assert(bounds.array(assert(bounds.object(winner.result)).winners, 2))[1], second)

            local all = owner_start("join", {works = {first, second}, policy = "all_success", timeout_ms = 20000, operation_key = harness.key()})
            settle(journal, tostring(first_session))
            local joined = owner_await(all)
            test.eq(joined.tag, "ready")
            test.is_true(assert(bounds.object(joined.result)).succeeded == true)
        end)
    end)
end

return test.run_cases(define_tests)
