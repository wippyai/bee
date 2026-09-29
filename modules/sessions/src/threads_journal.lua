-- MIT. Resolve the host-selected Threads journal binding once per operation.
-- Sessions never reaches into Threads storage or assumes a concrete table.
local registry = require("registry")
local funcs = require("funcs")
local scheduler = require("scheduler")
local M = {}
M.CONTRACT = "bee.threads:journal"
M.BINDING_REF = "bee.sessions:threads_journal_ref"
M.METHODS = {"open", "enqueue", "lookup_operation", "claim_owner", "renew_owner", "reserve_turn", "pull_turn",
    "accept_turn", "checkpoint", "append_event", "record_effect_intent", "record_effect_receipt",
    "record_effect_resolution", "link_execution", "link_child", "settle_turn", "request_control",
    "commit_control", "apply_guidance", "register_wait", "consume_wait", "decide_join", "transfer",
    "snapshot", "scan_due"}

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
        enqueue = function(request: scheduler.SendRequest): (scheduler.WorkReceipt?, string?)
            local value, err = M.invoke("enqueue", request)
            return value :: scheduler.WorkReceipt?, err
        end,
        scan_due = function(request: {limit: integer}): (scheduler.DuePage?, string?)
            local value, err = M.invoke("scan_due", request)
            return value :: scheduler.DuePage?, err
        end,
        reserve_turn = function(request: {work: string, session: string}): (scheduler.Claim?, string?)
            local value, err = M.invoke("reserve_turn", request)
            return value :: scheduler.Claim?, err
        end,
        link_execution = function(claim: scheduler.Claim, intent: scheduler.ExecutionIntent): (boolean, string?)
            local value, err = M.invoke("link_execution", {claim = claim, intent = intent})
            if err then return false, err end
            if value ~= true then return false, "Threads did not confirm execution intent" end
            return true, nil
        end,
    }
end

return M
