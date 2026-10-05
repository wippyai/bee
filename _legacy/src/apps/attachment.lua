-- MIT. Owner-side attachment records held only by protected resource owners.
local tty = require("tty")
type Record = {recipient: string, mount: string}
type Result = {attachment: Record?, error_code: string, error: string}
type ObserverResult = {mount: string, error_code: string, error: string}
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

function M.remove_recipient(view: tty.Viewport, previous: Record?, recipient: string): Result
    if not previous or previous.recipient ~= recipient then
        return {attachment = previous, error_code = "", error = ""}
    end
    return M.replace(view, previous, "")
end

-- Keep failed revocations owned so detach can retry; never revoke the controller.
function M.observe(view: tty.Viewport, observers: {[string]: string}, recipient: string): ObserverResult
    if recipient == "" then return {mount = "", error_code = "invalid_argument", error = "Observer recipient required"} end
    local previous = observers[recipient]
    if previous then
        local _, err = view:revoke(previous)
        if err then return {mount = "", error_code = "revoke_failed", error = tostring(err)} end
        observers[recipient] = nil
    else
        local count = 0
        for _ in pairs(observers) do count = count + 1 end
        if count >= 16 then return {mount = "", error_code = "busy", error = "Observer capacity reached"} end
    end
    local mount, err = view:mount(recipient, {observe = true})
    if not mount then return {mount = "", error_code = "attachment_failed", error = tostring(err)} end
    observers[recipient] = mount
    return {mount = mount, error_code = "", error = ""}
end

function M.remove_observer(view: tty.Viewport, observers: {[string]: string}, recipient: string): (boolean, string?)
    local mount = observers[recipient]
    if not mount then return true, nil end
    local _, err = view:revoke(mount)
    if err then return false, tostring(err) end
    observers[recipient] = nil
    return true, nil
end

return M
