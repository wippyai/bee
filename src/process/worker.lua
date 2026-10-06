-- MIT. The loop every background worker runs: it optionally holds a wake
-- name, runs one pass at start and on every wake or tick, and retries a pass
-- that asked for it with doubling backoff, until the worker is cancelled.
-- Each worker keeps its own declared service, actor and policies.
local process = require("process")
local channel = require("channel")
local time = require("time")
local M = {}
M.RETRY_FIRST_MS = 1000
M.RETRY_LAST_MS = 30000

-- Pass runs the worker's work once; false asks for a retry with backoff.
type Pass = () -> boolean
type Options = {
    -- name is registered so wakes and owners can find the worker.
    name: string?,
    -- wake is the message topic that triggers a pass.
    wake: string?,
    -- every is a tick interval such as "5000ms" that triggers a pass.
    every: string?,
    pass: Pass,
}

function M.run(options: Options)
    local lifecycle = assert(process.events())
    local wakes = options.wake and assert(process.listen(options.wake, {message = true})) or nil
    if options.name then
        local registered, register_error = process.registry.register(options.name)
        if not registered then error("register " .. options.name .. ": " .. tostring(register_error)) end
    end
    local ticker = options.every and assert(time.ticker(options.every)) or nil
    local retry_ms = M.RETRY_FIRST_MS
    local retrying = not options.pass()
    while true do
        local cases = {lifecycle:case_receive()}
        if wakes then cases[#cases + 1] = wakes:case_receive() end
        if ticker then cases[#cases + 1] = ticker:channel():case_receive() end
        if retrying then cases[#cases + 1] = time.after(tostring(retry_ms) .. "ms"):case_receive() end
        local selected = channel.select(cases)
        if not selected.ok then break end
        if selected.channel == lifecycle then
            if selected.value.kind == process.event.CANCEL then break end
        else
            retrying = not options.pass()
            retry_ms = retrying and math.min(retry_ms * 2, M.RETRY_LAST_MS) or M.RETRY_FIRST_MS
        end
    end
    if ticker then ticker:stop() end
    if wakes then process.unlisten(wakes) end
end

return M
