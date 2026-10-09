-- MIT. Plans associated application tests and records authenticated runs.
local demand = require("demand")
local registry = require("registry")
local uuid = require("uuid")
local application = require("application")
local tests = require("tests")
local test_runs = require("test_runs")
local discovery = require("discovery")
local bounds = require("bounds")
local application_tests = require("application_tests")
local activation_profiles = require("activation_profiles")

type Object = {[string]: unknown}
type Plan = {definition: application.Definition, tests: {test_runs.Planned}}

local function plan(workspace_id: string, selector: string, owned: {[string]: boolean}, filter: string?): (Plan?, tests.Reply?)
    local snapshot, snapshot_error = registry.snapshot()
    local state = snapshot and snapshot:state() or nil
    if not state then return nil, tests.fail("UNAVAILABLE", tostring(snapshot_error or "registry state is unavailable")) end
    local definition: application.Definition? = nil
    local associated: {[string]: boolean} = {}
    for _, entry in ipairs(state.entries) do
        local meta = bounds.object(entry.meta)
        if entry.kind == "process.lua" and meta and meta.type == "bee.app" then
            local binding, record, admission_error = application.admission(entry.id, workspace_id)
            if admission_error then return nil, tests.fail("UNAVAILABLE", admission_error) end
            local alias = record and record.source_workspace or bounds.id(meta.test_overlay)
            if entry.id == selector or alias == selector then
                if not binding then return nil, tests.fail("DENIED", "application is not admitted in your workspace") end
                if meta.test_overlay and not owned[tostring(meta.test_overlay)] then
                    return nil, tests.fail("DENIED", "application is not delivered from an overlay you own")
                end
                if record then
                    local overlay, overlay_error = registry.overlay(record.overlay_owner)
                    local rows = overlay and overlay:entries() or nil
                    if not rows then return nil, tests.fail("UNAVAILABLE", tostring(overlay_error or "application entries are unavailable")) end
                    for _, raw in ipairs(rows) do associated[raw.id] = true end
                    local hub = activation_profiles.hub_identity(workspace_id, record.source_workspace)
                    local admitted_hub = hub and hub.overlay_owner == record.overlay_owner
                    if associated[entry.id] and not admitted_hub and not owned[record.source_workspace] then
                        return nil, tests.fail("DENIED", "application is not delivered from an overlay you own")
                    end
                end
                if not record then
                    local declared, declared_error = application.test_entries(entry.id)
                    if declared_error then return nil, tests.fail("UNAVAILABLE", declared_error) end
                    if declared then
                        associated[entry.id] = true
                        for _, id in ipairs(declared) do associated[id] = true end
                    end
                end
                definition = application.definition(entry.id)
                break
            end
        end
    end
    if not definition then
        return nil, tests.fail(owned[selector] and "NOT_FOUND" or "DENIED", "application " .. selector .. " is not installed or admitted")
    end
    local found, discovery_error = application_tests.select(state.entries, definition.process, associated)
    if not found then return nil, tests.fail("UNAVAILABLE", discovery_error or "application tests are unavailable") end
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

local start: (string, string, string, Plan) -> tests.Reply

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
    local planned, fault = plan(workspace_id, request.application :: string, request.owned :: {[string]: boolean}, request.filter :: string?)
    if not planned then return fault or tests.fail("INTERNAL", "unresolved application") end
    if request.operation == "list" then
        return tests.succeed({application = planned.definition.process, tests = planned.tests})
    end
    if #planned.tests == 0 then return tests.fail("NOT_FOUND", "no tests in " .. tostring(request.application) .. " match") end
    if #planned.tests > tests.MAX_TESTS then
        return tests.fail("INVALID", #planned.tests .. " tests match; at most " .. tests.MAX_TESTS .. " run at once, narrow the filter")
    end
    return start(workspace_id, actor_id, request.application :: string, planned)
end

start = function(workspace_id: string, actor_id: string, overlay: string, planned: Plan): tests.Reply
    local run: test_runs.Row = {run_id = tostring(uuid.v7()), workspace_id = workspace_id, actor_id = actor_id,
        overlay = overlay, application = planned.definition.process, plan = planned.tests,
        state = "pending", result = nil}
    local created, code, message = test_runs.create(run)
    if not created then return tests.fail(code or "UNAVAILABLE", message or "the run was not recorded") end
    local signalled, wake_error = demand.wake(tests.NAME)
    if not signalled then return tests.fail("UNAVAILABLE", "run " .. run.run_id .. " is recorded: " .. tostring(wake_error)) end
    return tests.succeed({run_id = run.run_id, application = run.application, total = #run.plan})
end

return {handle = handle, start = start}
