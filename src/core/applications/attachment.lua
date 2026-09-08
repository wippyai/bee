-- MIT. Owner-side controller attachment; only the broker holds this record.
local tty = require("tty")
type Record = {recipient: string, mount: string}
type Result = {attachment: Record?, error_code: string, error: string}
local M = {}

function M.reference(value: Record?): string
    return value and value.mount or ""
end

-- Native mounts bind authority to an exact execution PID. A failed revocation
-- retains the old record; successful revocation precedes issuing any new grant.
function M.replace(view: tty.Viewport, previous: Record?, recipient: string): Result
    if previous then
        local _, err = view:revoke(previous.mount)
        if err then return {attachment = previous, error_code = "revoke_failed", error = tostring(err)} end
    end
    if recipient == "" then return {error_code = "", error = ""} end
    local mount, err = view:mount(recipient, {observe = true, input = true, resize = true})
    if not mount then return {error_code = "attachment_failed", error = tostring(err)} end
    return {attachment = {recipient = recipient, mount = mount}, error_code = "", error = ""}
end

return M
