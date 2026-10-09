-- MIT. The node's application test runner: runs the tests an application's
-- pack carries and writes each run's results to the node database. A test runs
-- as its application, with the actor and scope the node gives the app's own
-- instances, so it holds the authority the person approved for the app and
-- nothing more.
--
-- A run is a row the authorized backend wrote: workspace, actor, application
-- and the tests planned. A message to this process is only a hint that a row
-- waits; the runner reads the request from the row and trusts no message field.
-- Each test is one function entry of meta.type test, run the way the
-- framework's own runner runs it: one at a time, its case events received on a
-- topic of the run, its completion awaited for the test's own meta.timeout.
local process = require("process")
local channel = require("channel")
local funcs = require("funcs")
local time = require("time")
local logger = require("logger")
local application = require("application")
local tests = require("tests")
local test_runs = require("test_runs")
local receiver = require("receiver")
local bounds = require("bounds")
local demand = require("demand")

type Object = {[string]: unknown}
type Case = {name: string, status: string, error: string?, duration_ms: integer}
type Entry = {id: string, suite: string, timeout: string, cases: {Case}, error: string?, truncated: boolean, hive: Object?}
type Run = {id: string, workspace_id: string, definition: application.Definition,
    entries: {Entry}, done: integer, finished: boolean, cases: integer, dropped: integer}

-- The framework's runner drains a finished test's completion event for this long.
local COMPLETION_GRACE = "1s"

-- record keeps one case of an entry within the run's case bound.
local function record(run: Run, entry: Entry, case: Case)
    if run.cases >= tests.MAX_CASES then
        run.dropped = run.dropped + 1
        return
    end
    run.cases = run.cases + 1
    local text, cut = case.error, false
    if text then text, cut = tests.truncate(text) end
    case.error = text
    if cut then entry.truncated = true end
    entry.cases[#entry.cases + 1] = case
end

local function fail_entry(entry: Entry, message: string)
    local text, cut = tests.truncate(message)
    entry.error = text
    entry.truncated = entry.truncated or cut
end

local CASE_STATUS: {[string]: string} = {["test:case:pass"] = "pass", ["test:case:fail"] = "fail", ["test:case:skip"] = "skip"}

-- observe folds one framework event into the entry and reports whether it
-- completed the test.
local function observe(run: Run, entry: Entry, message: unknown): boolean
    local payload: unknown = type(message) == "table" and message or nil
    if not payload then return false end
    local event = (payload :: Object).type
    local data: Object = type((payload :: Object).data) == "table" and (payload :: Object).data :: Object or {}
    if event == "test:complete" then return true end
    local status = CASE_STATUS[tostring(event)]
    if status then
        local seconds = tonumber(data.duration) or 0
        record(run, entry, {name = tostring(data.test or ""), status = status,
            error = type(data.error) == "string" and data.error or nil, duration_ms = math.floor(seconds * 1000 + 0.5)})
    end
    return false
end

-- execute runs one test entry and waits for it as the framework's runner does:
-- until the function answers or its timeout passes, then a moment for the
-- completion event the function sent before it returned.
local function execute(run: Run, entry: Entry, executor: funcs.Executor, inbox: channel.Channel<unknown>)
    local topic = tests.UPDATE .. run.id
    local future, start_error = executor:async(entry.id, {pid = tostring(process.pid()), topic = topic, ref_id = entry.id})
    if not future then
        fail_entry(entry, tostring(start_error))
        return
    end
    local response = future:response()
    local deadline = time.after(entry.timeout)
    local answered, completed = false, false
    while not answered do
        local selected = channel.select({inbox:case_receive(), response:case_receive(), deadline:case_receive()})
        if selected.channel == inbox then
            if selected.ok then completed = observe(run, entry, selected.value:payload():data()) or completed end
        elseif selected.channel == response then
            answered = true
        else
            local _, result_error = future:result()
            fail_entry(entry, result_error and tostring(result_error) or "test timed out after " .. entry.timeout)
            future:cancel()
            return
        end
    end
    local grace = time.after(COMPLETION_GRACE)
    while not completed do
        local selected = channel.select({inbox:case_receive(), grace:case_receive()})
        if selected.channel ~= inbox or not selected.ok then break end
        completed = observe(run, entry, selected.value:payload():data())
    end
    if #entry.cases == 0 then
        local payload, result_error = future:result()
        if result_error then
            fail_entry(entry, tostring(result_error))
        elseif payload and payload:data() == false then
            fail_entry(entry, "test returned false")
        else
            record(run, entry, {name = entry.id:match(":([^:]+)$") or entry.id, status = "pass", error = nil, duration_ms = 0})
        end
    end
end

-- authority is the executor that runs a test as the application: its actor
-- and exact scope, in the run's workspace.
local function authority(run: Run, workspace_id: string): (funcs.Executor?, string?)
    local actor, actor_error = application.actor(workspace_id, "test-" .. run.id, run.definition, 1)
    if not actor then return nil, actor_error end
    local scope, scope_error = application.scope(run.definition, workspace_id)
    if not scope then return nil, scope_error end
    local acted = funcs.new():with_actor(actor)
    local scoped = acted and acted:with_scope(scope)
    if not scoped then return nil, "application authority is unavailable to the runner" end
    return scoped, nil
end

local function summary(run: Run): Object
    local passed, failed, skipped, errors = 0, 0, 0, 0
    local entries: {Object} = {}
    for _, entry in ipairs(run.entries) do
        local cases: {Object} = {}
        for _, case in ipairs(entry.cases) do
            if case.status == "pass" then passed = passed + 1
            elseif case.status == "fail" then failed = failed + 1
            else skipped = skipped + 1 end
            cases[#cases + 1] = {name = case.name, status = case.status, error = case.error, duration_ms = case.duration_ms}
        end
        if entry.error then errors = errors + 1 end
        entries[#entries + 1] = {id = entry.id, suite = entry.suite, cases = cases, error = entry.error,
            truncated = entry.truncated or nil}
    end
    local value: Object = {run_id = run.id, application = run.definition.process, state = run.finished and "complete" or "running",
        progress = {done = run.done, total = #run.entries}}
    if run.finished then
        value.entries = entries
        value.totals = {passed = passed, failed = failed, skipped = skipped, errors = errors}
        if run.dropped > 0 then value.truncated = {cases = run.dropped} end
    end
    return value
end

-- publish writes the run's progress or final results where status reads them.
local function publish(run: Run): boolean
    local saved, save_error = test_runs.save(run.id, run.finished and "complete" or "running", summary(run))
    if not saved then logger:error("Test run results not saved", {run = run.id, error = tostring(save_error)}) end
    return saved
end

-- proceed runs the entries of a run one after another.
local function proceed(run: Run)
    local inbox = assert(process.listen(tests.UPDATE .. run.id, {message = true}))
    local executor, authority_error = authority(run, run.workspace_id)
    for _, entry in ipairs(run.entries) do
        local scoped, authorization_error = executor, authority_error
        if entry.hive then
            local invocation, denied = receiver.authorize({application = run.definition.process, workspace_id = run.workspace_id,
                service = entry.hive.service, operation = entry.hive.operation, arguments = {}},
                tostring(entry.hive.caller), tostring(entry.hive.node), true)
            if not invocation or invocation.operation.ref ~= entry.id then scoped, authorization_error = nil, denied or "remote test ownership changes"
            elseif scoped then scoped = scoped:with_context({["bee.hive.caller"] = invocation.caller}) end
        end
        if scoped then execute(run, entry, scoped, inbox)
        else fail_entry(entry, tostring(authorization_error)) end
        run.done = run.done + 1
        if run.done < #run.entries then publish(run) end
    end
    process.unlisten(inbox)
end

-- start runs a run in a coroutine of this process; a failure ends that run,
-- never the service.
local function start(run: Run, completed: channel.Channel<boolean>)
    coroutine.spawn(function()
        local proceeded, failure = pcall(proceed, run)
        if not proceeded then
            logger:error("Test run failed", {run = run.id, error = tostring(failure)})
            for _, entry in ipairs(run.entries) do
                if #entry.cases == 0 and not entry.error then fail_entry(entry, "the run failed: " .. tostring(failure)) end
            end
        end
        run.finished = true
        completed:send(publish(run))
    end)
end

-- take runs the waiting run run_id names, as the row stored it.
local function take(run_id: string, completed: channel.Channel<boolean>): boolean
    local row, take_error = test_runs.take(run_id)
    if take_error then error("Test run not read: " .. take_error) end
    if not row then return false end
    local definition, definition_error = application.definition(row.application)
    local entries: {Entry} = {}
    for _, planned in ipairs(row.plan) do
        entries[#entries + 1] = {id = planned.id, suite = planned.suite, timeout = planned.timeout, cases = {}, error = nil, truncated = false, hive = bounds.object(planned.hive)}
    end
    if not definition then
        for _, entry in ipairs(entries) do fail_entry(entry, tostring(definition_error)) end
        assert(test_runs.save(row.run_id, "complete", {run_id = row.run_id, application = row.application, state = "complete",
            progress = {done = #entries, total = #entries}, totals = {passed = 0, failed = 0, skipped = 0, errors = #entries}}))
        return false
    end
    start({id = row.run_id, workspace_id = row.workspace_id, definition = definition, entries = entries,
        done = 0, finished = false, cases = 0, dropped = 0}, completed)
    return true
end

local function main()
    local registered, register_error = process.registry.register(tests.NAME)
    if not registered then error("register test runner: " .. tostring(register_error)) end
    local wakes = assert(process.listen(tests.WAKE, {message = true}))
    local lifecycle = assert(process.events())
    local demanded = assert(process.listen(demand.WAKE, {message = true}))
    assert(demand.ready(tests.NAME))
    local interrupted, interrupt_error = test_runs.interrupt()
    if not interrupted then logger:error("Interrupted test runs not recorded", {error = interrupt_error}) end
    local active = 0
    local generation = 0
    local completed = channel.new(16) :: channel.Channel<boolean>
    local function sweep()
        local waiting, waiting_error = test_runs.waiting()
        if not waiting then error("Waiting test runs not listed: " .. tostring(waiting_error)) end
        for _, id in ipairs(waiting) do if take(id, completed) then active = active + 1 end end
    end
    sweep()
    logger:info("Test runner ready")
    while true do
        if active == 0 and generation > 0 then
            local waiting, problem = test_runs.waiting()
            assert(waiting, problem)
            if #waiting == 0 then assert(demand.quiet(tests.NAME, generation)) else sweep() end
        end
        local selected = channel.select({lifecycle:case_receive(), wakes:case_receive(), demanded:case_receive(), completed:case_receive()})
        if selected.channel == lifecycle then
            if not selected.ok or selected.value.kind == process.event.CANCEL then return end
        elseif selected.channel == completed then
            assert(selected.ok and selected.value == true, "Test run final result is not durable")
            active = active - 1
            sweep()
        else
            if not selected.ok then return end
            if selected.channel == demanded then
                local supervisor = process.registry.lookup(demand.SUPERVISOR, process.registry.LOCAL)
                local message = selected.value
                local value = bounds.object(message:payload():data())
                if not supervisor or tostring(message:from()) ~= tostring(supervisor) or not value
                    or type(value.generation) ~= "number" then goto continue end
                generation = math.floor(value.generation)
            end
            -- A wake is a hint: it names no request, and what waits is read from the database.
            sweep()
        end
        ::continue::
    end
end

return {main = main}
