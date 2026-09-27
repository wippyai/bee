-- MIT. Retry one failed readiness check after the host removes super-edit rows.
local M = {}

type Start<T> = () -> (T?, string?, boolean)
type Disable = () -> (boolean?, string?)
type Cleanup = () -> ()

local function checked<T>(start: Start<T>, cleanup: Cleanup): (T?, string?, boolean)
    local value: T? = nil
    local failure: string? = nil
    local readiness_failed = false
    local ok, raised = pcall(function()
        value, failure, readiness_failed = start()
    end)
    if ok then return value, failure, readiness_failed end
    cleanup()
    return nil, tostring(raised), false
end

function M.run<T>(start: Start<T>, disable: Disable, cleanup: Cleanup): (T?, string?)
    local first, first_error, readiness_failed = checked(start, cleanup)
    if first ~= nil then return first, nil end
    if not readiness_failed then return nil, first_error end

    local changed, disable_error = disable()
    if changed ~= true then return nil, disable_error or first_error end

    local second, second_error = checked(start, cleanup)
    if second ~= nil then return second, nil end
    return nil, "local host startup failed after disabling super-edit overlays: "
        .. tostring(second_error or "readiness was not published")
end

return M
