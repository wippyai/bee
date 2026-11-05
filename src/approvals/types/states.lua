-- MIT. The kinds of request an approval answers and the states it moves through.
local M = {}

type RequestKind = "permission" | "question"
type ApprovalState = "pending" | "decided" | "expired" | "withdrawn" | "superseded" | "invalidated"

function M.request_kind(value: unknown): RequestKind?
    if value == "permission" then return "permission" end
    if value == "question" then return "question" end
    return nil
end

function M.approval_state(value: unknown): ApprovalState?
    if value == "pending" then return "pending" end
    if value == "decided" then return "decided" end
    if value == "expired" then return "expired" end
    if value == "withdrawn" then return "withdrawn" end
    if value == "superseded" then return "superseded" end
    if value == "invalidated" then return "invalidated" end
    return nil
end

return M
