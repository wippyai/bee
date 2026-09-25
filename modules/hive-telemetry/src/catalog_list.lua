-- MIT. Open operation: the public summaries of what this node exposes.
local catalog = require("catalog")
local types = require("types")
local bounds = require("bounds")
local function handle(request: unknown): {[string]: unknown}
    local after = ""
    local input = bounds.object(request)
    if input and input.after_operation_ref ~= nil then after = tostring(input.after_operation_ref) end
    local snapshot, err = catalog.snapshot()
    if not snapshot then return {operations = {}, generation = 0, unavailable = err} end
    local page: {{operation_ref: string, mode: string, revision: string, title: string}} = {}
    local has_more = false
    for _, summary in ipairs(catalog.summaries(snapshot)) do
        if summary.operation_ref > after then
            if #page < bounds.MAX_LIST_ITEMS then page[#page + 1] = summary else has_more = true end
        end
    end
    local result: {[string]: unknown} = {operations = page, generation = snapshot.generation, has_more = has_more}
    if has_more then result.next_after_operation_ref = page[#page].operation_ref end
    return result
end
return {handle = handle}
