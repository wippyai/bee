-- MIT. Collect monitored exits without losing another awaited process's result.
local process = require("process")
local bounds = require("bounds")
local M = {}
type Outcome = {value: {[string]: unknown}?, error: string?}
type Receive = (boolean) -> unknown
function M.collect(pids: {string}, exited: {[string]: Outcome}, receive: Receive, label: string): {[string]: Outcome}
    local function all_done(): boolean
        for _, pid in ipairs(pids) do if not exited[pid] then return false end end
        return true
    end
    local function record(raw: unknown)
        local event = assert(bounds.object(raw), "invalid process event")
        local kind, from = event.kind, event.from
        assert(type(kind) == "string" and type(from) == "string", "invalid process event identity")
        if kind ~= process.event.EXIT then return end
        local result: {[string]: unknown} = {}
        if event.result ~= nil then result = assert(bounds.object(event.result), "invalid process exit result") end
        local value: {[string]: unknown}? = nil
        if type(result.value) == "table" then value = assert(bounds.object(result.value)) end
        exited[from] = {value = value, error = result.error and tostring(result.error) or nil}
    end
    while not all_done() do
        local event = receive(true) or receive(false)
        if event then
            record(event)
        else
            local queued = receive(true)
            while queued do
                record(queued)
                queued = receive(true)
            end
            if not all_done() then error(label .. " did not finish") end
        end
    end
    local outcomes: {[string]: Outcome} = {}
    for _, pid in ipairs(pids) do outcomes[pid] = exited[pid] end
    return outcomes
end
return M
