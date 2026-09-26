-- MIT. Retry one failed readiness check after the host removes super-edit rows.
local M = {}

type Start = () -> (unknown?, string?, boolean)
type Disable = () -> (boolean?, string?)

function M.run(start: Start, disable: Disable): (unknown?, string?)
    local first, first_error, readiness_failed = start()
    if first ~= nil then return first, nil end
    if not readiness_failed then return nil, first_error end

    local changed, disable_error = disable()
    if changed ~= true then return nil, disable_error or first_error end

    local second, second_error = start()
    if second ~= nil then return second, nil end
    return nil, "local host startup failed after disabling super-edit overlays: "
        .. tostring(second_error or "readiness was not published")
end

return M
