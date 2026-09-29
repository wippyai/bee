-- MIT. Resolve the host-selected Threads journal binding once per operation.
-- Sessions never reaches into Threads storage or assumes a concrete table.
local registry = require("registry")
local funcs = require("funcs")
local scheduler = require("scheduler")
local M = {}
M.CONTRACT = "bee.threads:journal"
M.BINDING_REF = "bee.sessions:threads_journal_ref"
M.METHODS = {"session_create", "session_describe", "session_scan", "session_transition", "work_send", "work_describe",
    "work_scan", "turn_reserve", "turn_recover", "turn_pull", "turn_accept", "work_settle", "work_uncertain", "work_cancel",
    "operation_lookup", "operation_describe", "feed_read"}

type Entry = {[string]: unknown}
type Targets = {[string]: string}
type Snapshot = {get: (string) -> (unknown?, string?)}

local function object(value: unknown): Entry?
    if type(value) ~= "table" then return nil end
    return value :: Entry
end

local function linked_binding(): (string?, string?)
    local reference, reference_error = registry.get(M.BINDING_REF)
    if reference_error or not reference then return nil, "Threads journal binding is not selected by the host" end
    local ref_data = object(reference.data)
    local ref = ref_data and ref_data.ref
    if type(ref) ~= "string" or ref == "" then return nil, "Threads journal binding requirement is not linked" end
    return ref, nil
end

local function resolve(): (Targets?, string?)
    local ref, ref_error = linked_binding()
    if not ref then return nil, ref_error end
    local pinned, pin_error = registry.snapshot()
    if pin_error or not pinned then return nil, "Threads journal registry snapshot is unavailable" end
    local raw, get_error = (pinned :: Snapshot):get(ref)
    local binding = object(raw)
    if get_error or not binding or binding.kind ~= "contract.binding" then return nil, "selected Threads journal binding is unavailable" end
    local data = object(binding.data)
    local contracts = data and data.contracts
    if type(contracts) ~= "table" then return nil, "selected Threads journal binding has no contracts" end
    local methods: Entry? = nil
    for _, raw_contract in ipairs(contracts :: {unknown}) do
        local contract = object(raw_contract)
        if contract and contract.contract == M.CONTRACT then
            if methods then return nil, "selected Threads journal binding declares its contract twice" end
            methods = object(contract.methods)
        end
    end
    if not methods then return nil, "selected binding does not implement " .. M.CONTRACT end
    local targets: Targets = {}
    for _, name in ipairs(M.METHODS) do
        local target = methods[name]
        if type(target) ~= "string" or target == "" then return nil, "Threads journal binding omits " .. name end
        local entry, entry_error = (pinned :: Snapshot):get(target)
        local target_entry = object(entry)
        if entry_error or not target_entry or target_entry.kind ~= "function.lua" then
            return nil, "Threads journal target " .. name .. " is unavailable"
        end
        targets[name] = target
    end
    return targets, nil
end

function M.invoke(method: string, request: unknown): (unknown?, string?)
    local allowed = false
    for _, name in ipairs(M.METHODS) do if name == method then allowed = true; break end end
    if not allowed then return nil, "UNSUPPORTED: unknown Threads journal operation" end
    local targets, resolve_error = resolve()
    if not targets then return nil, resolve_error end
    local target = (targets :: Targets)[method]
    if not target then return nil, "Threads journal binding omits " .. method end
    local raw, call_error = funcs.call(target, request)
    if call_error then return nil, tostring(call_error) end
    local reply = object(raw)
    if not reply then return nil, "Threads journal returned a malformed Reply" end
    if reply.ok == true then return reply.value, nil end
    if reply.ok == false then
        local fault = object(reply.error)
        return nil, fault and tostring(fault.message or fault.code) or "Threads journal refused the operation"
    end
    return nil, "Threads journal returned a malformed Reply"
end

function M.adapter(): scheduler.Journal
    return {
        enqueue = function(request: {[string]: unknown}): (scheduler.WorkReceipt?, string?)
            local value, err = M.invoke("work_send", request)
            return value :: scheduler.WorkReceipt?, err
        end,
        scan_due = function(request: {limit: integer}): (scheduler.Page?, string?)
            local value, err = M.invoke("work_scan", request)
            return value :: scheduler.Page?, err
        end,
        reserve_turn = function(request: {session: string, operation_key: string}): (scheduler.Reservation?, string?)
            local value, err = M.invoke("turn_reserve", request)
            return value :: scheduler.Reservation?, err
        end,
        recover_turn = function(request: {turn: string, operation_key: string}): (scheduler.Reservation?, string?)
            local value, err = M.invoke("turn_recover", request)
            return value :: scheduler.Reservation?, err
        end,
        pull_turn = function(request: {turn: string, claim: string}): (scheduler.Turn?, string?)
            local value, err = M.invoke("turn_pull", request)
            return value :: scheduler.Turn?, err
        end,
        accept_turn = function(request: {[string]: unknown}): (unknown?, string?)
            return M.invoke("turn_accept", request)
        end,
        settle = function(request: {[string]: unknown}): (unknown?, string?)
            return M.invoke("work_settle", request)
        end,
        mark_uncertain = function(request: {[string]: unknown}): (unknown?, string?)
            return M.invoke("work_uncertain", request)
        end,
        describe_session = function(request: {session: string}): (scheduler.Object?, string?)
            local value, err = M.invoke("session_describe", request)
            return value :: scheduler.Object?, err
        end,
        transition_session = function(request: {[string]: unknown}): (unknown?, string?)
            return M.invoke("session_transition", request)
        end,
    }
end

return M
