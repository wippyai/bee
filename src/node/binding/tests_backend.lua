-- MIT. The private side of the application test facade. It runs only under
-- the node's test backend scope, takes a request the facade authorized (the
-- caller's workspace and actor, and the overlay it verified the caller owns),
-- plans the tests of the application admitted from that overlay, writes the
-- run into the node database and wakes the runner with the run's id. Status
-- reads the stored results.
local process = require("process")
local registry = require("registry")
local uuid = require("uuid")
local application = require("application")
local tests = require("tests")
local test_runs = require("test_runs")
local discovery = require("discovery")

type Object = {[string]: unknown}
type Found = {id: string, name: string, group: string, meta: {[string]: any}}
type Plan = {definition: application.Definition, tests: {test_runs.Planned}}

local APP_ROOT = "app."

-- plan finds the bee.app entry in namespace app.<overlay> admitted in the
-- workspace, from that overlay when governance admitted it, and its test
-- entries narrowed by filter.
local function plan(workspace_id: string, overlay: string, filter: string?): (Plan?, tests.Reply?)
    local namespace = APP_ROOT .. overlay
    local definition: application.Definition? = nil
    for _, entry in ipairs(registry.find({[".kind"] = "process.lua", ["meta.type"] = "bee.app"}) or {}) do
        if entry.id:match("^([^:]+):") == namespace then
            definition = application.definition(entry.id)
            break
        end
    end
    if not definition then return nil, tests.fail("NOT_FOUND", "application " .. namespace .. " is not installed") end
    local binding, record, admission_error = application.admission(definition.process, workspace_id)
    if admission_error then return nil, tests.fail("UNAVAILABLE", admission_error) end
    if not binding or (record and record.source_workspace ~= overlay) then
        return nil, tests.fail("DENIED", "application " .. definition.process .. " is not admitted in your workspace from your overlay")
    end
    local found: {Found} = {}
    for _, entry in ipairs(registry.find({[".kind"] = "function.lua", ["meta.type"] = "test"}) or {}) do
        if entry.id:match("^([^:]+):") == namespace then
            found[#found + 1] = {id = entry.id, name = entry.id, group = namespace, meta = entry.meta or {}}
        end
    end
    if filter then found = discovery.filter_tests(found, {filter}) end
    local suites, no_suite = discovery.group_by_suite(found)
    local planned: {test_runs.Planned} = {}
    local function add(list: {any}, suite: string)
        for _, entry in ipairs(list) do
            local timeout = type(entry.meta.timeout) == "string" and entry.meta.timeout or tests.DEFAULT_TIMEOUT
            planned[#planned + 1] = {id = entry.id, suite = suite, timeout = timeout}
        end
    end
    for _, suite in ipairs(discovery.sorted_keys(suites :: {[string]: any})) do add(suites[suite] or {}, suite) end
    add(no_suite, "other")
    return {definition = definition, tests = planned}, nil
end

local function handle(raw: unknown): tests.Reply
    local request = raw :: Object
    local workspace_id, actor_id = request.workspace_id :: string, request.actor_id :: string
    if request.operation == "status" then
        local run, run_error = test_runs.get(request.run_id :: string, workspace_id, actor_id)
        if run_error then return tests.fail("UNAVAILABLE", run_error) end
        if not run then return tests.fail("NOT_FOUND", "no run " .. tostring(request.run_id)) end
        return tests.succeed(run.result or {run_id = run.run_id, application = run.application, state = "running",
            progress = {done = 0, total = #run.plan}})
    end
    local planned, fault = plan(workspace_id, request.overlay :: string, request.filter :: string?)
    if not planned then return fault or tests.fail("INTERNAL", "unresolved application") end
    if request.operation == "list" then
        return tests.succeed({application = planned.definition.process, tests = planned.tests})
    end
    if #planned.tests == 0 then return tests.fail("NOT_FOUND", "no tests in " .. APP_ROOT .. tostring(request.overlay) .. " match") end
    if #planned.tests > tests.MAX_TESTS then
        return tests.fail("INVALID", #planned.tests .. " tests match; at most " .. tests.MAX_TESTS .. " run at once, narrow the filter")
    end
    local run: test_runs.Row = {run_id = tostring(uuid.v7()), workspace_id = workspace_id, actor_id = actor_id,
        overlay = request.overlay :: string, application = planned.definition.process, plan = planned.tests,
        state = "pending", result = nil}
    local created, code, message = test_runs.create(run)
    if not created then return tests.fail(code or "UNAVAILABLE", message or "the run was not recorded") end
    -- The wake is a hint; the run waits in the database whether or not it arrives.
    local pid = process.registry.lookup(tests.NAME)
    if pid then process.send(pid, tests.WAKE, {run_id = run.run_id}) end
    return tests.succeed({run_id = run.run_id, application = run.application, total = #run.plan})
end

return {handle = handle}
