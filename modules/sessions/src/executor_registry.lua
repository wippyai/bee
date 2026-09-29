-- MIT. Host selection authorizes executor bindings; registry metadata alone
-- never makes an implementation callable.
local M = {}
local registry_api = require("registry")
local funcs = require("funcs")
local scheduler = require("scheduler")
M.CONTRACT = "bee.sessions:executor"
M.BINDING_TYPE = "bee.sessions.executor_binding"
M.SELECTION_REF = "bee.sessions:executor_selection"
M.METHODS = {"describe", "locate", "negotiate", "prepare", "activate", "pull_turn", "accept_turn", "observe", "reconcile", "cancel"}

type Binding = {ref: string, executor_id: string, version: string, methods: {[string]: string}}
type Registry = {by_id: {[string]: Binding}}
type Entry = {[string]: unknown}
type RegistrySnapshot = {get: (string) -> (unknown?, string?)}
type RuntimeExecutor = scheduler.Executor
type RuntimeRegistry = scheduler.Registry

local function id(value: unknown): string?
    if type(value) ~= "string" or #value == 0 or #value > 256 then return nil end
    if not value:match("^[A-Za-z0-9][A-Za-z0-9_.:-]*$") then return nil end
    return value
end

local function object(value: unknown): Entry?
    if type(value) ~= "table" then return nil end
    return value :: Entry
end

local function selected_binding(ref: string, raw: unknown): (Binding?, string?)
    local entry = object(raw)
    if not entry or entry.kind ~= "contract.binding" then return nil, "INVALID: executor binding " .. ref .. " is not a contract binding" end
    local meta = object(entry.meta)
    if not meta or meta.type ~= M.BINDING_TYPE then return nil, "INVALID: executor binding " .. ref .. " has the wrong type" end
    local executor_id, version = id(meta.executor_id), id(meta.version)
    if not executor_id then return nil, "INVALID: executor binding " .. ref .. " has no executor_id" end
    if not version then return nil, "INVALID: executor binding " .. ref .. " has no version" end
    local data = object(entry.data)
    local contracts = data and data.contracts
    if type(contracts) ~= "table" then return nil, "INVALID: executor binding " .. ref .. " has no contracts" end
    local found: Entry? = nil
    for _, raw_contract in ipairs(contracts :: {unknown}) do
        local contract = object(raw_contract)
        if contract and contract.contract == M.CONTRACT then
            if found then return nil, "INVALID: executor binding " .. ref .. " declares the executor contract twice" end
            found = contract
        end
    end
    if not found then return nil, "INVALID: executor binding " .. ref .. " does not implement " .. M.CONTRACT end
    local methods = object(found.methods)
    if not methods then return nil, "INVALID: executor binding " .. ref .. " has no methods" end
    local mapped: {[string]: string} = {}
    for _, name in ipairs(M.METHODS) do
        local target = id(methods[name])
        if not target then return nil, "INVALID: executor binding " .. ref .. " does not bind " .. name end
        mapped[name] = target
    end
    return {ref = ref, executor_id = executor_id, version = version, methods = mapped}, nil
end

function M.build(entries: {[string]: unknown}, selected_refs: {string}): (Registry?, string?)
    if type(entries) ~= "table" or type(selected_refs) ~= "table" then return nil, "INVALID: executor selection must be a list" end
    local by_id: {[string]: Binding} = {}
    local seen_refs: {[string]: boolean} = {}
    local count = 0
    for key in pairs(selected_refs) do
        if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then return nil, "INVALID: executor selection must be a list" end
        count = count + 1
    end
    if count > 64 then return nil, "INVALID: executor selection exceeds 64 bindings" end
    for index = 1, count do
        local ref = id(selected_refs[index])
        if not ref then return nil, "INVALID: executor binding ref is malformed" end
        if seen_refs[ref] then return nil, "CONFLICT: duplicate selected executor binding " .. ref end
        seen_refs[ref] = true
        local binding, binding_error = selected_binding(ref, entries[ref])
        if not binding then return nil, binding_error end
        if by_id[binding.executor_id] then
            return nil, "CONFLICT: duplicate executor binding for " .. binding.executor_id
        end
        by_id[binding.executor_id] = binding
    end
    return {by_id = by_id}, nil
end

function M.get(registry: Registry, executor_id: string): (Binding?, string?)
    if not id(executor_id) then return nil, "INVALID" end
    local binding = registry.by_id[executor_id]
    if not binding then return nil, "NOT_FOUND" end
    return binding, nil
end

local function invoke(target: string, request: unknown): (unknown?, string?)
    local raw, call_error = funcs.call(target, request)
    if call_error then return nil, tostring(call_error) end
    local reply = object(raw)
    if not reply then return nil, "executor returned a malformed Reply" end
    if reply.ok == true then return reply.value, nil end
    if reply.ok == false then
        local fault = object(reply.error)
        return nil, fault and tostring(fault.message or fault.code) or "executor refused the operation"
    end
    return nil, "executor returned a malformed Reply"
end

local function refs_of(value: unknown): ({string}?, string?)
    if type(value) ~= "table" then return nil, "host executor selection is not a list" end
    local rows = value :: {unknown}
    local count = 0
    for key in pairs(rows) do
        if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then return nil, "host executor selection is not a list" end
        count = count + 1
        if count > 64 then return nil, "host executor selection exceeds 64 bindings" end
    end
    local refs: {string} = {}
    for index = 1, count do
        local ref = id(rows[index])
        if not ref then return nil, "host executor selection contains a malformed binding ref" end
        refs[index] = ref
    end
    return refs, nil
end

function M.runtime(): (RuntimeRegistry?, string?)
    local selected, selection_error = registry_api.get(M.SELECTION_REF)
    if selection_error or not selected then return nil, "host executor selection is unavailable" end
    local selection = object(selected)
    local data = selection and object(selection.data)
    local refs, refs_error = refs_of(data and data.refs)
    if not refs then return nil, refs_error end
    local snapshot, snapshot_error = registry_api.snapshot()
    if snapshot_error or not snapshot then return nil, "executor registry snapshot is unavailable" end
    local pinned = snapshot :: RegistrySnapshot
    local entries: {[string]: unknown} = {}
    for _, ref in ipairs(refs :: {string}) do
        local entry, entry_error = pinned:get(ref)
        if entry_error or not entry then return nil, "selected executor binding " .. ref .. " is unavailable" end
        entries[ref] = entry :: unknown
    end
    local built, build_error = M.build(entries, refs :: {string})
    if not built then return nil, build_error end
    local runtime: {[string]: RuntimeExecutor} = {}
    for executor_id, binding in pairs((built :: Registry).by_id) do
        for name, target in pairs(binding.methods) do
            local raw, entry_error = pinned:get(target)
            local method_entry = object(raw)
            if entry_error or not method_entry or method_entry.kind ~= "function.lua" then
                return nil, "executor binding " .. binding.ref .. " method " .. name .. " is not a registered function"
            end
        end
        local methods = binding.methods
        local negotiate_target = methods.negotiate :: string
        local prepare_target = methods.prepare :: string
        local activate_target = methods.activate :: string
        local reconcile_target = methods.reconcile :: string
        local adapter: RuntimeExecutor = {
            negotiate = function(claim: scheduler.Claim): (scheduler.Plan?, string?)
                local value, err = invoke(negotiate_target, {claim = claim})
                return value :: scheduler.Plan?, err
            end,
            prepare = function(claim: scheduler.Claim, plan: scheduler.Plan, recovery: scheduler.Evidence): (scheduler.Prepared?, string?)
                local value, err = invoke(prepare_target, {claim = claim, plan = plan, recovery = recovery})
                return value :: scheduler.Prepared?, err
            end,
            activate = function(claim: scheduler.Claim, prepared: scheduler.Prepared): (unknown?, string?)
                return invoke(activate_target, {claim = claim, prepared = prepared})
            end,
            reconcile = function(request: {claim: scheduler.Claim, execution: scheduler.ExecutionIntent?}): (scheduler.Evidence?, string?)
                local value, err = invoke(reconcile_target, request)
                return value :: scheduler.Evidence?, err
            end,
        }
        runtime[executor_id] = adapter
    end
    local selected_registry: RuntimeRegistry = {get = function(executor_id: string): (RuntimeExecutor?, string?)
        local executor = runtime[executor_id]
        if not executor then return nil, "NOT_FOUND" end
        return executor, nil
    end}
    return selected_registry, nil
end

return M
