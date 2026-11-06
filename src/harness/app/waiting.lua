local funcs = require("funcs")
local bounds = require("bounds")
local M = {}
type Review = {approval_id: string, title: string}
function M.read(thread_id: string): (Review?, string?)
    local raw, err = funcs.call("bee.approvals.binding:waiting", {thread_id = thread_id})
    local reply = bounds.object(raw)
    if err then return nil, tostring(err) end
    if not reply or reply.ok ~= true then
        local fault = reply and bounds.object(reply.error)
        return nil, fault and bounds.text(fault.message, 512) or "waiting request unavailable"
    end
    local value = bounds.object(reply.value)
    if value and value.request == false then return nil, nil end
    local review = value and bounds.object(value.request)
    local id, title = review and bounds.id(review.approval_id), review and bounds.line(review.title, 160)
    if not id or not title then return nil, "invalid waiting request" end
    return {approval_id = id, title = title}, nil
end
return M
