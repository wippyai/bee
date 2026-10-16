-- MIT. Shared conversion from runtime time values to epoch seconds.
local time = require("time")

local M = {}
M.FORMAT = "2006-01-02T15:04:05.000Z07:00"

function M.epoch_seconds(value: time.Time): number
    return value:unix_nano() / 1000000000
end

function M.utc(value: time.Time): string
    return value:utc():format(M.FORMAT)
end

function M.parse(value: unknown): time.Time?
    if type(value) ~= "string" then return nil end
    local parsed, err = time.parse(M.FORMAT, value)
    if err or not parsed or M.utc(parsed) ~= value then return nil end
    return parsed
end

function M.now(): string
    return M.utc(time.now())
end

function M.deadline(duration: string): string
    return M.utc(time.now():add(duration))
end

function M.milliseconds(): integer
    return math.floor(time.now():unix_nano() / 1000000)
end

function M.stamp(milliseconds: integer): string
    return M.utc(time.unix(math.floor(milliseconds / 1000), (milliseconds % 1000) * 1000000))
end

function M.elapsed_ms(started: time.Time, current: time.Time?): integer
    local instant = current or time.now()
    return math.floor(instant:sub(started):milliseconds())
end

function M.elapsed_seconds(current_nanoseconds: integer, previous_nanoseconds: integer): number
    return (current_nanoseconds - previous_nanoseconds) / 1000000000
end

function M.local_time(value: string): string
    local instant = M.parse(value)
    if not instant then return value end
    return instant:in_local():format("2006-01-02 15:04 MST")
end

function M.local_deadline(value: string): string
    local deadline = M.parse(value)
    if not deadline then return value end
    local minutes = math.ceil((M.epoch_seconds(deadline) - M.epoch_seconds(time.now())) / 60)
    local relative = minutes <= 0 and "passed" or (minutes < 60 and ("in " .. tostring(minutes) .. " min")
        or (minutes < 1440 and ("in " .. tostring(math.ceil(minutes / 60)) .. " hr") or ("in " .. tostring(math.ceil(minutes / 1440)) .. " days")))
    return relative .. " · " .. M.local_time(value)
end

return M
