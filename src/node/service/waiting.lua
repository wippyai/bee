-- MIT. A request an app instance asked for and waits on marks that
-- instance's window with the review banner while the request is pending.
local bounds = require("bounds")
local principal = require("principal")
local part_handover = require("part_handover")
local M = {}
type Instance = part_handover.Instance

-- mark applies request to instances: a requested pending request marks the
-- instance that asked for it under title, and a settled one clears every
-- mark that names it. It returns the ids whose mark changed.
function M.mark(instances: {[string]: Instance}, workspace_id: string, request: {[string]: unknown}, title: string?): {string}
    local changed: {string} = {}
    local approval_id = bounds.id(request.approval_id)
    if not approval_id then return changed end
    local pending = request.state == "pending"
    for id, instance in pairs(instances) do
        if title and pending and instance.workspace == workspace_id and request.requester_id == principal.actor_id(workspace_id, id) then
            instance.review = {approval_id = approval_id, title = title}
            changed[#changed + 1] = id
        elseif not pending and instance.review and instance.review.approval_id == approval_id then
            instance.review = nil
            changed[#changed + 1] = id
        end
    end
    return changed
end

return M
