-- MIT. Host selection authorizes executor bindings; registry metadata alone
-- never makes an implementation callable.
local M = {}
local registry_api = require("registry")
local funcs = require("funcs")
local security = require("security")
local scheduler = require("scheduler")
M.CONTRACT = "bee.sessions:executor"
M.BINDING_TYPE = "bee.sessions.executor_binding"
M.SELECTION_REF = "bee.sessions:executor_selection"

type Entry = {[string]: unknown}
type Snapshot = {get: (string) -> (unknown?, string?)}
type Binding = {ref: string, executor_id: string, version: string, run_turn: string}
type Registry = {by_id: {[string]: Binding}}
type RuntimeRegistry = scheduler.Registry

local function object(value: unknown): Entry?
    if type(value) ~= "table" then return nil end
    return value
end

local function id(value: unknown): string?
    if type(value) ~= "string" or #value == 0 or #value > 256 then return nil end
    if not value:match("^[A-Za-z0-9][A-Za-z0-9_.:-]*$") then return nil end
    return value
end

local function selected_binding(ref: string, raw: unknown): (Binding?, string?)
    local entry = object(raw)
    local meta = entry and object(entry.meta)
    if not entry or entry.kind ~= "contract.binding" or not meta or meta.type ~= M.BINDING_TYPE then
        return nil, "INVALID: selected executor binding " .. ref .. " has the wrong type"
    end
    local executor_id, version = id(meta.executor_id), id(meta.version)
    if not executor_id or not version then return nil, "INVALID: selected executor binding " .. ref .. " has incomplete identity" end
    local data = object(entry.data)
    local contracts = data and data.contracts
    if type(contracts) ~= "table" then return nil, "INVALID: selected executor binding " .. ref .. " has no contracts" end
    local methods: Entry? = nil
    for _, raw_contract in ipairs(contracts) do
        local contract = object(raw_contract)
        if contract and contract.contract == M.CONTRACT then
            if methods then return nil, "INVALID: selected executor binding " .. ref .. " declares its contract twice" end
            methods = object(contract.methods)
        end
    end
    if not methods then return nil, "INVALID: selected executor binding " .. ref .. " does not implement " .. M.CONTRACT end
    local target = id(methods.run_turn)
    if not target then return nil, "INVALID: selected executor binding " .. ref .. " does not bind run_turn" end
    return {ref = ref, executor_id = executor_id, version = version, run_turn = target}, nil
end

function M.build(entries: {[string]: unknown}, selected_refs: {string}): (Registry?, string?)
    if type(entries) ~= "table" or type(selected_refs) ~= "table" then return nil, "INVALID: executor selection must be a list" end
    local count = 0
    for key in pairs(selected_refs) do
        if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then return nil, "INVALID: executor selection must be a list" end
        count = count + 1
        if count > 64 then return nil, "INVALID: executor selection exceeds 64 bindings" end
    end
    local by_id: {[string]: Binding} = {}
    local seen: {[string]: boolean} = {}
    for index = 1, count do
        local ref = id(selected_refs[index])
        if not ref or seen[ref] then return nil, "INVALID: executor binding ref is malformed or repeated" end
        seen[ref] = true
        local binding, failure = selected_binding(ref, entries[ref])
        if not binding then return nil, failure end
        if by_id[binding.executor_id] then return nil, "CONFLICT: duplicate executor binding for " .. binding.executor_id end
        by_id[binding.executor_id] = binding
    end
    return {by_id = by_id}, nil
end

function M.get(selected: Registry, executor_id: string): (Binding?, string?)
    local name = id(executor_id)
    if not name then return nil, "INVALID" end
    local binding = selected.by_id[name]
    if not binding then return nil, "NOT_FOUND" end
    return binding, nil
end

local function invoke(target: string, request: unknown): (unknown?, string?)
    local turn = object(request)
    local admission = turn and object(turn.admission)
    local owner = admission and id(admission.owner_id)
    local workspace = admission and id(admission.workspace_id)
    if not owner or not workspace or #workspace ~= 32 or workspace:find("[^0-9a-f]") then return nil, "turn admission omitted its workspace-bound owner" end
    local actor, actor_error = security.new_actor(owner, {workspace_id = workspace})
    if not actor then return nil, tostring(actor_error) end
    local contextual, context_error = funcs.new():with_actor(actor):with_context({["bee.workspace_id"] = workspace})
    if not contextual then return nil, tostring(context_error) end
    local raw, call_error = contextual:call(target, request)
    if call_error then return nil, tostring(call_error) end
    local reply = object(raw)
    if not reply then return nil, "executor returned a malformed Reply" end
    if reply.ok == true then return reply.value, nil end
    if reply.ok == false then
        local fault = object(reply.error)
        return nil, fault and tostring(fault.message or fault.code) or "executor refused the turn"
    end
    return nil, "executor returned a malformed Reply"
end

function M.runtime(): (RuntimeRegistry?, string?)
    local selected, selection_error = registry_api.get(M.SELECTION_REF)
    if selection_error or not selected then return nil, "host executor selection is unavailable" end
    local selection = object(selected)
    local data = selection and object(selection.data)
    local refs = data and data.refs
    if type(refs) ~= "table" then return nil, "host executor selection is not a list" end
    local snapshot, snapshot_error = registry_api.snapshot()
    if snapshot_error or not snapshot then return nil, "executor registry snapshot is unavailable" end
    local pinned = snapshot
    local entries: {[string]: unknown} = {}
    for _, raw_ref in ipairs(refs) do
        local ref = id(raw_ref)
        if not ref then return nil, "host executor selection contains a malformed binding ref" end
        local entry, entry_error = pinned:get(ref)
        if entry_error or not entry then return nil, "selected executor binding " .. ref .. " is unavailable" end
        entries[ref] = entry
    end
    local built, build_error = M.build(entries, refs)
    if not built then return nil, build_error end
    local executors: {[string]: scheduler.Executor} = {}
    for executor_id, binding in pairs((built).by_id) do
        local target_entry, target_error = pinned:get(binding.run_turn)
        local target = object(target_entry)
        if target_error or not target or target.kind ~= "function.lua" then
            return nil, "executor binding " .. binding.ref .. " run_turn target is not a registered function"
        end
        local run_target = binding.run_turn
        executors[executor_id] = {run_turn = function(turn: scheduler.Turn): (scheduler.Execution?, string?)
            local value, err = invoke(run_target, turn)
            if err then return nil, err end
            return scheduler.execution(value)
        end}
    end
    local runtime: RuntimeRegistry = {get = function(executor_id: string): (scheduler.Executor?, string?)
        local executor = executors[executor_id]
        if not executor then return nil, "NOT_FOUND" end
        return executor, nil
    end}
    return runtime, nil
end

return M
