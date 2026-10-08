-- MIT
local registry = require("registry")
local bounds = require("bounds")
local application = require("application")
local app_tools = require("app_tools")
local application_tests = require("application_tests")
local receiver = require("receiver")
local operations = require("operations")
local protocol = require("protocol")
local canonical = require("canonical")
local tests = require("tests")
local test_runs = require("test_runs")
local backend = require("backend")
local grants = require("grants")
local M = {}
type Object = {[string]: unknown}
type Selection = {workspace: string, application: string, owner: string}

local function selections(): {Selection}
    local found: {Selection} = {}
    local seen: {[string]: boolean} = {}
    for _, entry in ipairs(registry.find({["meta.type"] = grants.SCHEMA}) or {}) do
        local data = bounds.object(entry.data)
        local workspace = data and bounds.id(data.workspace_id) or nil
        local app = data and bounds.id(data.application) or nil
        local owner = data and bounds.id(data.overlay_owner) or nil
        if workspace and app and owner then
            local key = workspace .. "\n" .. app
            if not seen[key] then found[#found + 1] = {workspace = workspace, application = app, owner = owner}; seen[key] = true end
        end
    end
    return found
end

function M.inspect(ref: string, selected: Selection, caller: string, node: string): receiver.Invocation?
    local entry = registry.get(ref)
    local operation = entry and operations.decode(entry) or nil
    if not operation or operation.application_ref ~= selected.application then return nil end
    return receiver.authorize({application = selected.application, workspace_id = selected.workspace,
        service = operation.service, operation = operation.name, arguments = {}}, caller, node, true)
end

function M.discover(raw: unknown, caller: string, node: string): protocol.Reply
    local request = bounds.object(raw)
    if not request then return protocol.fail("discovery requires an object") end
    local extra = bounds.fields(request, {})
    if extra then return protocol.fail(extra) end
    local tools: {Object} = {}
    local seen: {[string]: boolean} = {}
    local collisions: {[string]: boolean} = {}
    for _, selected in ipairs(selections()) do
        local found = app_tools.discover(selected.workspace)
        for _, tool in ipairs(found and found.tools or {}) do
            if tool.definition_id == selected.application then
                local invocation = M.inspect(tool.ref, selected, caller, node)
                if invocation then
                    local operation = invocation.operation
                    if seen[tool.alias] then collisions[tool.alias] = true end
                    seen[tool.alias] = true
                    tools[#tools + 1] = {alias = tool.alias, ref = tool.ref, definition_id = tool.definition_id,
                        description = tool.description, input_schema = tool.input_schema, output_schema = tool.output_schema,
                        annotations = tool.annotations, workspace_id = selected.workspace, service = operation.service,
                        operation = operation.name, revision = operation.revision, effect = operation.effect}
                end
            end
        end
    end
    for _, entry in ipairs(application.host_entries("bee.hive.host_exposure")) do
        local data = bounds.object(entry.data)
        local app = data and bounds.id(data.application_ref)
        local refs = data and bounds.ids(data.operations, true)
        for _, ref in ipairs(refs or {}) do
            local raw_entry = registry.get(ref)
            local meta = raw_entry and bounds.object(raw_entry.meta)
            local alias = meta and bounds.line(meta.hive_alias, 64)
            local op = operations.decode(raw_entry, true)
            if app and op and alias then
                local invocation = receiver.authorize({application = app, service = op.service, operation = op.name, arguments = {}}, caller, node, true)
                if invocation then
                    if seen[alias] then collisions[alias] = true end
                    seen[alias] = true
                    tools[#tools + 1] = {alias = alias, ref = ref, definition_id = app, description = "Destination-approved " .. op.service .. "." .. op.name,
                        input_schema = op.input, output_schema = op.output, annotations = {readOnlyHint = op.effect == "read"},
                        workspace_id = invocation.request.workspace_id, service = op.service, operation = op.name, revision = op.revision, effect = op.effect}
                end
            end
        end
    end
    local kept: {Object} = {}
    for _, tool in ipairs(tools) do if not collisions[tostring(tool.alias)] then kept[#kept + 1] = tool end end
    table.sort(kept, function(a: Object, b: Object): boolean return tostring(a.alias) < tostring(b.alias) end)
    if #kept > app_tools.MAX_TOOLS then return protocol.fail("remote discovery exceeds its tool bound") end
    local reply = protocol.ok({tools = kept, diagnostics = {}})
    if not canonical.encode(reply, protocol.MAX_BYTES) then return protocol.fail("remote discovery exceeds its byte bound") end
    return reply
end

local function planned(selected: Selection, caller: string, node: string, filter: string?): {test_runs.Planned}
    local overlay = registry.overlay(selected.owner)
    local rows = overlay and overlay:entries() or nil
    if not rows then return {} end
    local associated: {[string]: boolean} = {}
    for _, entry in ipairs(rows) do associated[entry.id] = true end
    local found = application_tests.select(rows, selected.application, associated)
    local plan: {test_runs.Planned} = {}
    for _, entry in ipairs(found or {}) do
        if not filter or entry.id:find(filter, 1, true) then
            local invocation = M.inspect(entry.id, selected, caller, node)
            if invocation then
                local meta = bounds.object(entry.meta) or {}
                plan[#plan + 1] = {id = entry.id, suite = bounds.line(meta.suite, 160) or "other",
                    timeout = bounds.line(meta.timeout, 32) or tests.DEFAULT_TIMEOUT,
                    hive = {caller = caller, node = node, service = invocation.operation.service, operation = invocation.operation.name}}
            end
        end
    end
    table.sort(plan, function(a: test_runs.Planned, b: test_runs.Planned): boolean return a.id < b.id end)
    return plan
end

local function handle_tests(raw: unknown, caller: string, node: string): protocol.Reply
    local request, invalid = tests.decode(raw)
    if not request then return protocol.fail(invalid or "invalid tests request") end
    if request.node ~= nil then return protocol.fail("receiver does not accept a caller-selected node") end
    local actor = "bee.hive.peer:" .. protocol.node_of(caller, node)
    if request.operation == "status" then
        local row, row_error = test_runs.get(assert(request.run_id), nil, actor)
        if not row then return protocol.fail(row_error or "no remote run for this authenticated peer") end
        for _, test in ipairs(row.plan) do
            if not M.inspect(test.id, {workspace = row.workspace_id, application = row.application, owner = row.overlay}, caller, node) then
                return protocol.fail("test exposure or application admission is revoked")
            end
        end
        local value = row.result or {run_id = row.run_id, application = row.application, state = "running",
            progress = {done = 0, total = #row.plan}}
        value.node = node
        return protocol.ok(value)
    end
    local selected: Selection? = nil
    local plan: {test_runs.Planned} = {}
    for _, candidate in ipairs(selections()) do
        if candidate.application == request.application then
            local allowed = planned(candidate, caller, node, request.filter)
            if #allowed > 0 then
                if selected then return protocol.fail("remote application is ambiguous across workspaces") end
                selected, plan = candidate, allowed
            end
        end
    end
    if not selected then return protocol.fail("no exposed associated tests for this authenticated peer") end
    if #plan > tests.MAX_TESTS then return protocol.fail("remote test plan exceeds its bound") end
    if request.operation == "list" then
        local listed: {Object} = {}
        for _, item in ipairs(plan) do listed[#listed + 1] = {id = item.id, suite = item.suite, timeout = item.timeout} end
        return protocol.ok({node = node, application = selected.application, tests = listed})
    end
    if not request.idempotency_key then return protocol.fail("remote test run requires an idempotency key") end
    local invocation = assert(M.inspect(plan[1].id, selected, caller, node))
    invocation.operation.effect = "mutation"
    invocation.request.service = "application.tests"
    invocation.request.operation = "run"
    local fingerprint: {Object} = {}
    for _, item in ipairs(plan) do
        local approved = assert(M.inspect(item.id, selected, caller, node))
        fingerprint[#fingerprint + 1] = {id = item.id, revision = approved.operation.revision,
            input = approved.operation.input, output = approved.operation.output}
    end
    invocation.request.arguments = {plan = fingerprint}
    invocation.request.idempotency_key = request.idempotency_key
    local fresh, replay, claim_error = receiver.claim(invocation)
    if not fresh then return replay or protocol.fail(tostring(claim_error)) end
    local definition, definition_error = application.definition(selected.application)
    if not definition then return receiver.save(invocation, protocol.fail(tostring(definition_error))) end
    local result = backend.start(selected.workspace, actor, selected.owner, {definition = definition, tests = plan})
    if not result.ok then return receiver.save(invocation, protocol.fail(result.error and result.error.message or "test run failed")) end
    local value = assert(bounds.object(result.value))
    value.node = node
    return receiver.save(invocation, protocol.ok(value))
end
function M.tests(raw: unknown, caller: string, node: string): protocol.Reply
    local result = handle_tests(raw, caller, node)
    local reply = result.ok and tests.succeed(result.value) or tests.fail("DENIED", result.error or "remote tests failed")
    local envelope = protocol.ok({reply = reply})
    if not canonical.encode(envelope, protocol.MAX_BYTES) then return protocol.fail("remote tests reply exceeds its byte bound") end
    return envelope
end
return M
