-- MIT. Host selection authorizes executor bindings; registry metadata alone
-- never makes an implementation callable.
local M = {}
M.CONTRACT = "bee.sessions:executor"
M.BINDING_TYPE = "bee.sessions.executor_binding"
M.METHODS = {"describe", "locate", "negotiate", "prepare", "activate", "pull_turn", "accept_turn", "observe", "reconcile", "cancel"}

type Binding = {ref: string, executor_id: string, version: string, methods: {[string]: string}}
type Registry = {by_id: {[string]: Binding}}
type Entry = {[string]: unknown}

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

return M
