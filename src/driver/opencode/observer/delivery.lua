-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local M = {}
type Object = {[string]: unknown}
type IO = {submit: (Object) -> Object?, permission: (string, Object) -> (), record: (string) -> ()}
function M.send(io: IO, row: Object): boolean
    local ok = pcall(function()
        local response = io.submit(row)
        if row.hook_event_name ~= "PermissionRequest" or not response then return end
        local output = bounds.object(response.hookSpecificOutput) or {}
        local decision = bounds.object(output.decision) or {}
        if decision.behavior == "allow" or decision.behavior == "deny" then
            io.permission(tostring(row.permission_id), {reply = decision.behavior == "allow" and "once" or "reject", message = decision.message})
        end
    end)
    if not ok then io.record(tostring(row.hook_event_name) .. ": hook delivery failed") end
    return ok
end
return M
