-- MIT. Collect monitored exits without losing another awaited process's result.
local process = require("process")
local bounds = require("bounds")
local M = {}
type Outcome = {value: {[string]: unknown}?, error: string?}
type Receive = (boolean) -> unknown
local function record(exited: {[string]: Outcome}, raw: unknown)
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
function M.collect(pids: {string}, exited: {[string]: Outcome}, receive: Receive, label: string): {[string]: Outcome}
    local function all_done(): boolean
        for _, pid in ipairs(pids) do if not exited[pid] then return false end end
        return true
    end
    while not all_done() do
        local event = receive(true) or receive(false)
        if event then
            record(exited, event)
        else
            local queued = receive(true)
            while queued do
                record(exited, queued)
                queued = receive(true)
            end
            if not all_done() then error(label .. " did not finish") end
        end
    end
    local outcomes: {[string]: Outcome} = {}
    for _, pid in ipairs(pids) do outcomes[pid] = exited[pid] end
    return outcomes
end
function M.paused(pid: string, wanted: string, exited: {[string]: Outcome}, receive: Receive)
    while true do
        -- EXIT and barrier reports have separate delivery queues. A barrier
        -- already sent by the exiting carrier precedes the absent-barrier result.
        local raw = receive(true)
        if not raw then
            local outcome = exited[pid]
            if outcome then
                error(pid .. " exited before " .. wanted .. ": " .. (outcome.error or require("json").encode(outcome.value)))
            end
            raw = receive(false)
        end
        local event = assert(bounds.object(raw), "barrier observation channel closed")
        if event.kind == "pause" and event.from == pid and event.step == wanted then return end
        if event.kind ~= "pause" then record(exited, event) end
    end
end
return M
