-- SPDX-License-Identifier: MIT
-- CPU work between authenticated progress checkpoints makes cancellation
-- observable without requiring a long, uninterruptible runtime shutdown.
local process = require("process")
local channel = require("channel")

-- Deliberately never yields. This preserves the original startup/cancel smoke
-- but does not claim that Future:cancel preempts non-yielding CPU work.
local function cpu_spin(target: string): integer
    local sent, send_error = process.send(target, "research.spin.started", {})
    if not sent then error(tostring(send_error)) end
    local count = 0
    while true do count = (count + 1) % 1000 end
    return count
end

local function run(target: string, run_id: string, limit: integer): integer
    local continuations = assert(process.listen("research.spin.continue", {message = true}))
    local events = assert(process.events())
    local worker = tostring(process.pid())
    local chunk = 0
    local checksum = 0
    while limit == 0 or chunk < limit do
        -- Keep each progress boundary preceded by real CPU work. The checksum
        -- prevents the loop from becoming an empty scheduler-only fixture.
        for index = 1, 200000 do checksum = (checksum + index) % 1000003 end
        chunk = chunk + 1
        local sent, send_error = process.send(target, "research.spin.progress", {
            run_id = run_id, worker = worker, chunk = chunk, checksum = checksum,
        })
        if not sent then error(tostring(send_error)) end
        if limit ~= 0 and chunk >= limit then break end

        local selected = channel.select({continuations:case_receive(), events:case_receive()})
        if not selected.ok then error("spin continuation subscription closed") end
        if selected.channel == events then
            if selected.value.kind == process.event.CANCEL then
                process.unlisten(continuations)
                process.unlisten(events)
                return chunk
            end
            error("spin worker received an unexpected process event")
        end
        local message = selected.value
        local data: unknown = message:payload():data()
        if tostring(message:from()) ~= target or type(data) ~= "table"
            or data.run_id ~= run_id or data.chunk ~= chunk then
            error("spin continuation did not match the current caller and chunk")
        end
    end
    process.unlisten(continuations)
    process.unlisten(events)
    return chunk
end

return {run = run, cpu_spin = cpu_spin}
