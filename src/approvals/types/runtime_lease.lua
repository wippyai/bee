-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local M = {}
M.REF = "bee.approvals:runtime-lease"
type Ceiling = {subject: string, workspace_id: string, tool: string, input_digest: string, expires_ms: integer, max_uses: integer}
function M.decode(raw: unknown): (Ceiling?, string?)
    local value = bounds.object(raw)
    if not value or bounds.fields(value, {"subject", "workspace_id", "tool", "input_digest", "expires_ms", "max_uses"}) then return nil, "runtime lease ceiling has unknown fields" end
    local subject, workspace, tool = bounds.id(value.subject), bounds.id(value.workspace_id), bounds.id(value.tool)
    local digest = bounds.line(value.input_digest, 64)
    local expires, uses = bounds.count(value.expires_ms), bounds.count(value.max_uses)
    if not subject or not workspace or not tool or not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$")
        or not expires or expires == 0 or not uses or uses == 0 or uses > 10000 then return nil, "runtime lease needs an exact subject, workspace, tool/input digest, expiry and 1..10000 uses" end
    return {subject = subject, workspace_id = workspace, tool = tool, input_digest = digest, expires_ms = expires, max_uses = uses}, nil
end
return M
