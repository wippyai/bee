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

return M
