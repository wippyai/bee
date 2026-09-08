-- MIT. Pure pending-dialog ownership. The broker authenticates callers and
-- supplies fresh presentation IDs; app retries cannot reuse a user's old reply.
local protocol = require("protocol")
type Pending = {spec: protocol.Spec, client_request_id: string, execution_pid: string, closing: boolean}
type State = {items: {[string]: Pending}}
local M = {}
function M.new(): State return {items = {}} end
function M.add(state: State, spec: protocol.Spec, client_request_id: string, execution_pid: string, closing: boolean): boolean
    if state.items[spec.id] then return false end
    local count = 0
    for _ in pairs(state.items) do count = count + 1 end
    if count >= 16 then return false end
    -- Copy the projection: callers cannot mutate an admitted request later.
    local copy: protocol.Spec = {request_id = spec.request_id, id = spec.id, instance_id = spec.instance_id,
        kind = spec.kind, title = spec.title, message = spec.message, accept = spec.accept, initial = spec.initial}
    state.items[spec.id] = {spec = copy, client_request_id = client_request_id, execution_pid = execution_pid, closing = closing}
    return true
end
function M.remove(state: State, id: string): Pending?
    local item = state.items[id]
    state.items[id] = nil
    return item
end
function M.resolve(state: State, response: protocol.Response): Pending?
    local item = state.items[response.id]
    if not item or item.spec.instance_id ~= response.instance_id or item.spec.request_id ~= response.request_id then return nil end
    if item.spec.kind == "confirm" and response.value ~= "" then return nil end
    return M.remove(state, response.id)
end
function M.snapshot(state: State): {protocol.Spec}
    local result: {protocol.Spec} = {}
    for _, item in pairs(state.items) do
        local spec = item.spec
        result[#result + 1] = {request_id = spec.request_id, id = spec.id, instance_id = spec.instance_id,
            kind = spec.kind, title = spec.title, message = spec.message, accept = spec.accept, initial = spec.initial}
    end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end
return M
