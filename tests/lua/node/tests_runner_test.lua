-- MIT. The node runs the tests an application's pack carries as that
-- application: with the actor and exact scope the node gives its own
-- instances, for callers that own the overlay it was delivered from.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local time = require("time")
local bounds = require("bounds")

local WORKSPACE = string.rep("c", 32)
local OVERLAY = "runner_fixture"
local APPLICATION = "app.runner_fixture:app"

type Object = {[string]: unknown}

local function agent(id: string, workspace: string?): security.Actor
    return assert(security.new_actor(id, workspace and {workspace_id = workspace} or {}))
end

local function overlay(actor: security.Actor, request: Object): Object
    local raw, err = funcs.new():with_actor(actor):call("bee.gov.binding:overlay_call", request)
    if type(raw) ~= "table" then error(tostring(err or "overlay call returned no result")) end
    return assert(bounds.object(raw))
end

local function tests_call(actor: security.Actor, request: Object): Object
    local raw, err = funcs.new():with_actor(actor):call("bee.node.binding:tests_call", request)
    if type(raw) ~= "table" then error(tostring(err or "tests call returned no result")) end
    return assert(bounds.object(raw))
end

local function value_of(reply: Object): Object
    test.is_true(reply.ok == true, "reply refused: " .. tostring(bounds.object(reply.error) and (reply.error :: Object).message))
    return assert(bounds.object(reply.value))
end

local function code_of(reply: Object): unknown
    test.is_false(reply.ok == true)
    return (assert(bounds.object(reply.error))).code
end

-- completed polls a run until it reports complete; a run is bounded by its
-- tests' own timeouts, so the bound here only ends a runner that never answers.
local function completed(actor: security.Actor, run_id: string): Object
    for _ = 1, 80 do
        local value = value_of(tests_call(actor, {operation = "status", run_id = run_id}))
        if value.state == "complete" then return value end
        time.sleep("250ms")
    end
    error("run " .. run_id .. " did not complete")
end

local function entry_of(value: Object, id: string): Object
    for _, raw in ipairs(value.entries :: {unknown}) do
        local entry = assert(bounds.object(raw))
        if entry.id == id then return entry end
    end
    error("no entry " .. id)
end

local function case_of(entry: Object, name: string): Object
    for _, raw in ipairs(entry.cases :: {unknown}) do
        local case = assert(bounds.object(raw))
        if case.name == name then return case end
    end
    error("no case " .. name .. " in " .. tostring(entry.id) .. ": " .. tostring(entry.error))
end

local function define_tests()
    local author = agent("runner-author", WORKSPACE)
    local other = agent("runner-other", string.rep("d", 32))

    test.describe("application test runs", function()
        test.before_all(function()
            local created = overlay(author, {operation = "create", overlay_id = OVERLAY, expected_revision = 0, idempotency_key = OVERLAY .. "-create"})
            test.is_true(created.ok == true, tostring(created.message))
        end)

        test.it("lists the tests of an application delivered from the caller's overlay", function()
            local value = value_of(tests_call(author, {operation = "list", application = OVERLAY}))
            test.eq(value.application, APPLICATION)
            local ids: {string} = {}
            for _, raw in ipairs(value.tests :: {unknown}) do ids[#ids + 1] = tostring((assert(bounds.object(raw))).id) end
            test.eq(table.concat(ids, " "), "app.runner_fixture:authority_test app.runner_fixture:failing_test app.runner_fixture:slow_test")
            local named = value_of(tests_call(author, {operation = "list", application = APPLICATION, filter = "failing"}))
            test.eq(#(named.tests :: {unknown}), 1)
        end)

        test.it("runs each test as the application with its exact scope and reports structured results", function()
            local started = value_of(tests_call(author, {operation = "run", application = APPLICATION}))
            test.eq(started.total, 3)
            local run_id = tostring(started.run_id)
            local value = completed(author, run_id)
            test.eq(value.application, APPLICATION)

            local authority = entry_of(value, "app.runner_fixture:authority_test")
            test.eq(authority.suite, "fixture")
            for _, name in ipairs({"runs as an instance actor of the application", "holds what the admission grants",
                "is denied what the application boundary leaves out"}) do
                local case = case_of(authority, name)
                test.eq(case.status, "pass", name .. ": " .. tostring(case.error))
            end

            local failing = entry_of(value, "app.runner_fixture:failing_test")
            test.eq(case_of(failing, "passes").status, "pass")
            local failed = case_of(failing, "fails with its message")
            test.eq(failed.status, "fail")
            test.is_true(tostring(failed.error):find("expected", 1, true) ~= nil, tostring(failed.error))
            test.eq(case_of(failing, "is skipped").status, "skip")
            test.is_true(type(failed.duration_ms) == "number")

            local slow = entry_of(value, "app.runner_fixture:slow_test")
            test.is_true(tostring(slow.error):find("timed out", 1, true) ~= nil, tostring(slow.error))

            local totals = assert(bounds.object(value.totals))
            test.eq(totals.passed, 4)
            test.eq(totals.failed, 1)
            test.eq(totals.skipped, 1)
            test.eq(totals.errors, 1)
            local progress = assert(bounds.object(value.progress))
            test.eq(progress.done, 3)
        end)

        test.it("serves a caller holding only the gateway's tests tool policy", function()
            local policy = assert(security.policy("bee.security.gateway:gateway_tool_tests_policy"))
            local executor = funcs.new():with_actor(author):with_scope(security.new_scope({policy}))
            local raw, err = executor:call("bee.node.binding:tests_call", {operation = "list", application = OVERLAY})
            test.is_nil(err, tostring(err))
            local value = value_of(assert(bounds.object(raw)))
            test.eq(#(value.tests :: {unknown}), 3)
            local refused = executor:call("bee.gov.binding:delivery_call", {operation = "status"})
            test.is_false(type(refused) == "table" and (refused :: Object).ok == true)
        end)

        test.it("narrows a run by a substring of the test ids", function()
            local started = value_of(tests_call(author, {operation = "run", application = OVERLAY, filter = "authority"}))
            test.eq(started.total, 1)
            local value = completed(author, tostring(started.run_id))
            test.eq(#(value.entries :: {unknown}), 1)
        end)
    end)

    test.describe("application test run authorization", function()
        test.it("refuses a caller that does not own the overlay", function()
            test.eq(code_of(tests_call(other, {operation = "list", application = OVERLAY})), "DENIED")
            test.eq(code_of(tests_call(other, {operation = "run", application = APPLICATION})), "DENIED")
        end)

        test.it("refuses a caller with no authenticated workspace", function()
            test.eq(code_of(tests_call(agent("runner-anonymous", nil), {operation = "list", application = OVERLAY})), "DENIED")
        end)

        test.it("finds no application in an overlay that delivered none", function()
            local created = overlay(author, {operation = "create", overlay_id = "runner_empty", expected_revision = 0, idempotency_key = "runner-empty-create"})
            test.is_true(created.ok == true, tostring(created.message))
            test.eq(code_of(tests_call(author, {operation = "list", application = "runner_empty"})), "NOT_FOUND")
        end)

        test.it("shows a run only to the actor that started it", function()
            local started = value_of(tests_call(author, {operation = "run", application = OVERLAY, filter = "authority"}))
            local run_id = tostring(started.run_id)
            test.eq(code_of(tests_call(other, {operation = "status", run_id = run_id})), "NOT_FOUND")
            test.eq(code_of(tests_call(author, {operation = "status", run_id = "no-such-run"})), "NOT_FOUND")
            completed(author, run_id)
        end)

        test.it("refuses malformed requests", function()
            test.eq(code_of(tests_call(author, {operation = "run"})), "INVALID")
            test.eq(code_of(tests_call(author, {operation = "status"})), "INVALID")
            test.eq(code_of(tests_call(author, {operation = "list", application = OVERLAY, extra = true})), "INVALID")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
