-- MIT. Host-selected forwarded-operation adapters. The supervisor's routing
-- stays generic: it authenticates the peer, then asks this table which worker
-- runs one forwarded operation. The table is host-owned registry data, and
-- the worker still executes under the host-selected policies the adapter
-- entry names, so metadata selects a route and never grants one.
local bounds = require("bounds")
local M = {}
M.ENTRY = "bee.hive.supervisor:hive_operation_adapters"
M.ENTRY_TYPE = "bee.hive.operation_adapters"
M.MAX_ADAPTERS = 32
M.MAX_OPERATIONS = 32
type Adapter = {operations: {string}, worker: string}
type Table = {list: {Adapter}, index: {[string]: string}}
-- decode: an exact table or nothing; every adapter names at least one
-- operation and one worker, and no operation may be claimed twice.
function M.decode(value: unknown): (Table?, string?)
    local object = bounds.object(value)
    if not object then return nil, "operation adapters must be an object" end
    local unknown_field = bounds.fields(object, {"adapters"})
    if unknown_field then return nil, unknown_field end
    if type(object.adapters) ~= "table" then return nil, "adapters must be a list" end
    local raw = object.adapters
    local count = 0
    for key in pairs(raw) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then
            return nil, "adapters list keys must be dense"
        end
        count = count + 1
    end
    if count > M.MAX_ADAPTERS then return nil, "adapters exceeds " .. tostring(M.MAX_ADAPTERS) .. " entries" end
    local list: {Adapter} = {}
    local index: {[string]: string} = {}
    for position = 1, count do
        local item: unknown = raw[position]
        if item == nil then return nil, "adapters list keys must be dense" end
        local adapter = bounds.object(item)
        if not adapter then return nil, "adapters[" .. tostring(position) .. "] must be an object" end
        local item_error = bounds.fields(adapter, {"operations", "worker"})
        if item_error then return nil, "adapters[" .. tostring(position) .. "]: " .. item_error end
        local worker = bounds.id(adapter.worker)
        if not worker then return nil, "adapters[" .. tostring(position) .. "] worker is not an identifier" end
        local operations, operations_error = bounds.ids(adapter.operations)
        if not operations then return nil, "adapters[" .. tostring(position) .. "] operations: " .. tostring(operations_error) end
        if #operations == 0 or #operations > M.MAX_OPERATIONS then
            return nil, "adapters[" .. tostring(position) .. "] must name between 1 and " .. tostring(M.MAX_OPERATIONS) .. " operations"
        end
        for _, operation in ipairs(operations) do
            if index[operation] then return nil, "adapters repeat operation " .. operation end
            index[operation] = worker
        end
        list[#list + 1] = {operations = operations, worker = worker}
    end
    return {list = list, index = index}, nil
end
-- worker_of: the host-selected worker for one operation, or nothing.
function M.worker_of(table: Table, operation_ref: string): string?
    return table.index[operation_ref]
end
return M
