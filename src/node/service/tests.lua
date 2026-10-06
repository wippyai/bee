-- MIT. The node's application test runner: runs the tests an application's
-- pack carries and keeps each run's results in memory. A test runs as its
-- application, with the actor and scope the node gives the app's own instances,
-- so it holds the authority the person approved for the app and nothing more.
--
-- A request names the caller's workspace, actor and the overlays it owns. The
-- application must be admitted in that workspace from one of those overlays;
-- a run is readable only by the actor that started it. Each test is one
-- function entry of meta.type test, run the way the framework's own runner
-- runs it: one at a time, its case events received on a topic of the run, its
-- completion awaited for the test's own meta.timeout.
local process = require("process")
local channel = require("channel")
local registry = require("registry")
local funcs = require("funcs")
local time = require("time")
local uuid = require("uuid")
local logger = require("logger")
local application = require("application")
local tests = require("tests")
local discovery = require("discovery")

type Object = {[string]: unknown}
type Case = {name: string, status: string, error: string?, duration_ms: integer}
type Entry = {id: string, suite: string, timeout: string, cases: {Case}, error: string?, truncated: boolean}
type Run = {id: string, workspace_id: string, actor_id: string, application: string, definition: application.Definition,
    entries: {Entry}, done: integer, finished: boolean, cases: integer, dropped: integer}
type Found = {id: string, name: string, group: string, meta: {[string]: any}}
type Target = {overlay: string, definition: application.Definition, entries: {Entry}}

local TEST_TYPE = "test"
local APP_ROOT = "app."
-- The framework's runner drains a finished test's completion event for this long.
local COMPLETION_GRACE = "1s"

local function now_ms(): integer
    return math.floor(time.now():unix_nano() / 1000000)
end

-- overlay_of names the overlay an application argument refers to: an
-- application definition id app.<overlay>:<name> or the overlay id itself.
local function overlay_of(application_id: string): string
    local namespace = application_id:match("^([^:]+):")
    if namespace then return namespace:match("^" .. APP_ROOT:gsub("%.", "%%.") .. "([^.]+)$") or "" end
    return application_id
end

-- target resolves the application of a caller's overlay: the bee.app process
-- entry in namespace app.<overlay> admitted in the caller's workspace, from
-- that overlay when governance admitted it, and its test entries narrowed by filter.
local function target(request: Object): (Target?, tests.Reply?)
    local overlay = overlay_of(request.application :: string)
    local owned = false
    for _, id in ipairs(request.overlays :: {string}) do
        if id == overlay then owned = true end
    end
    if not owned then return nil, tests.fail("DENIED", "application " .. tostring(request.application) .. " is not delivered from an overlay you own") end
    local namespace = APP_ROOT .. overlay
    local definition: application.Definition? = nil
    for _, entry in ipairs(registry.find({[".kind"] = "process.lua", ["meta.type"] = "bee.app"}) or {}) do
        if entry.id:match("^([^:]+):") == namespace then
            definition = application.definition(entry.id)
            break
        end
    end
    if not definition then return nil, tests.fail("NOT_FOUND", "application " .. namespace .. " is not installed") end
    local binding, record, admission_error = application.admission(definition.process, request.workspace_id :: string)
    if admission_error then return nil, tests.fail("UNAVAILABLE", admission_error) end
    if not binding or (record and record.source_workspace ~= overlay) then
        return nil, tests.fail("DENIED", "application " .. definition.process .. " is not admitted in your workspace from your overlay")
    end
    local found: {Found} = {}
    for _, entry in ipairs(registry.find({[".kind"] = "function.lua", ["meta.type"] = TEST_TYPE}) or {}) do
        if entry.id:match("^([^:]+):") == namespace then found[#found + 1] = {id = entry.id, name = entry.id, group = namespace, meta = entry.meta or {}} end
    end
    if request.filter then found = discovery.filter_tests(found, {request.filter :: string}) end
    local suites, no_suite = discovery.group_by_suite(found)
    local entries: {Entry} = {}
    local function add(list: {any}, suite: string)
        for _, entry in ipairs(list) do
            local timeout = type(entry.meta.timeout) == "string" and entry.meta.timeout or tests.DEFAULT_TIMEOUT
            entries[#entries + 1] = {id = entry.id, suite = suite, timeout = timeout, cases = {}, error = nil, truncated = false}
        end
    end
    for _, suite in ipairs(discovery.sorted_keys(suites :: {[string]: any})) do add(suites[suite] or {}, suite) end
    add(no_suite, "other")
    return {overlay = overlay, definition = definition, entries = entries}, nil
end

local function describe(entry: Entry): Object
    return {id = entry.id, suite = entry.suite, timeout = entry.timeout}
end

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

-- proceed runs the entries of a run one after another.
local function proceed(run: Run, workspace_id: string)
    local inbox = assert(process.listen(tests.UPDATE .. run.id, {message = true}))
    local executor, authority_error = authority(run, workspace_id)
    for _, entry in ipairs(run.entries) do
        if executor then execute(run, entry, executor, inbox)
        else fail_entry(entry, tostring(authority_error)) end
        run.done = run.done + 1
    end
    process.unlisten(inbox)
end

-- start runs a run in a coroutine of this process; a failure ends that run,
-- never the service.
local function start(run: Run, workspace_id: string)
    coroutine.spawn(function()
        local proceeded, failure = pcall(proceed, run, workspace_id)
        if not proceeded then
            logger:error("Test run failed", {run = run.id, error = tostring(failure)})
            for _, entry in ipairs(run.entries) do
                if #entry.cases == 0 and not entry.error then fail_entry(entry, "the run failed: " .. tostring(failure)) end
            end
        end
        run.finished = true
    end)
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

local function main()
    local registered, register_error = process.registry.register(tests.NAME)
    if not registered then error("register test runner: " .. tostring(register_error)) end
    local requests = assert(process.listen(tests.REQUEST, {message = true}))
    local lifecycle = assert(process.events())
    local runs: {[string]: Run} = {}
    local order: {string} = {}

    -- room frees the oldest finished run when the retained runs are at their
    -- bound and reports whether a new run fits.
    local function room(): boolean
        local active = 0
        for _, run in pairs(runs) do if not run.finished then active = active + 1 end end
        if active >= tests.MAX_ACTIVE then return false end
        while #order >= tests.MAX_RUNS do
            local evicted = false
            for index, id in ipairs(order) do
                if runs[id].finished then
                    runs[id] = nil
                    table.remove(order, index)
                    evicted = true
                    break
                end
            end
            if not evicted then return false end
        end
        return true
    end

    local function handle(request: Object): tests.Reply
        if request.operation == "status" then
            local run = runs[request.run_id :: string]
            if not run or run.actor_id ~= request.actor_id or run.workspace_id ~= request.workspace_id then
                return tests.fail("NOT_FOUND", "no run " .. tostring(request.run_id))
            end
            return tests.succeed(summary(run))
        end
        local found, fault = target(request)
        if not found then return fault or tests.fail("INTERNAL", "unresolved application") end
        if request.operation == "list" then
            local listed: {Object} = {}
            for _, entry in ipairs(found.entries) do listed[#listed + 1] = describe(entry) end
            return tests.succeed({application = found.definition.process, tests = listed})
        end
        if #found.entries == 0 then return tests.fail("NOT_FOUND", "no tests in " .. APP_ROOT .. found.overlay .. " match") end
        if #found.entries > tests.MAX_TESTS then
            return tests.fail("INVALID", #found.entries .. " tests match; at most " .. tests.MAX_TESTS .. " run at once, narrow the filter")
        end
        if not room() then return tests.fail("BUSY", "too many test runs are in progress or unread; wait for one to complete") end
        local run: Run = {id = tostring(uuid.v7()), workspace_id = request.workspace_id :: string, actor_id = request.actor_id :: string,
            application = found.definition.process, definition = found.definition, entries = found.entries,
            done = 0, finished = false, cases = 0, dropped = 0}
        runs[run.id] = run
        order[#order + 1] = run.id
        start(run, run.workspace_id)
        return tests.succeed({run_id = run.id, application = run.application, total = #run.entries})
    end

    logger:info("Test runner ready")
    while true do
        local selected = channel.select({lifecycle:case_receive(), requests:case_receive()})
        if selected.channel == lifecycle then
            if not selected.ok or selected.value.kind == process.event.CANCEL then return end
        else
            if not selected.ok then return end
            local message = selected.value
            local data: unknown = message:payload():data()
            if type(data) == "table" and type(data.reply_topic) == "string" then
                local handled, outcome = pcall(handle, data)
                if not handled then
                    logger:error("Test run request failed", {error = tostring(outcome)})
                    outcome = tests.fail("INTERNAL", "the test runner failed this request")
                end
                process.send(message:from(), data.reply_topic, outcome)
            end
        end
    end
end

return {main = main}
