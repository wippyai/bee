-- MIT. A case owns its brokers and the application messages they publish.
local process = require("process")
local channel = require("channel")
local time = require("time")
type State = {events: Channel<process.Event>, brokers: {[string]: boolean},
    catalogs: Channel<process.Message>, replies: Channel<process.Message>, ready: Channel<process.Message>,
    cleanup: {() -> ()}}
local M = {}
local function drain(messages: Channel<process.Message>, topic: string)
    -- Ordinary messages retained behind a full listener survive unlisten.
    -- After all publishers exit, a same-topic marker bounds that backlog.
    local owner = tostring(process.pid())
    assert(process.send(owner, topic, {}))
    local deadline = time.after("30s")
    while true do
        local selected = channel.select({messages:case_receive(), deadline:case_receive()})
        assert(selected.ok and selected.channel == messages, topic .. " did not drain")
        if tostring(selected.value:from()) == owner then return end
    end
end
function M.join(state: State, pid: string)
    local deadline = time.after("30s")
    while state.brokers[pid] do
        local selected = channel.select({state.events:case_receive(), deadline:case_receive()})
        assert(selected.ok and selected.channel == state.events, pid .. " did not exit")
        local event = selected.value
        local from = tostring(event.from)
        if event.kind == process.event.EXIT and state.brokers[from] then
            state.brokers[from] = nil
            assert(not (event.result and event.result.error), from .. " failed: " .. tostring(event.result and event.result.error))
        end
    end
end
function M.case(run: (State) -> ()): () -> ()
    return function()
        local state: State = {events = assert(process.events()), brokers = {}, cleanup = {},
            catalogs = assert(process.listen("bee.app.catalog", {message = true})),
            replies = assert(process.listen("bee.app.reply", {message = true})),
            ready = assert(process.listen("bee.app.ready", {message = true}))}
        local ok, fault = pcall(run, state)
        local restored, restore_error = pcall(function()
            for _, cleanup in ipairs(state.cleanup) do cleanup() end
        end)
        local stopped, stop_error = pcall(function()
            for pid in pairs(state.brokers) do
                local _, problem = process.cancel(pid, "application fixture cleanup")
                if problem and problem:kind() == errors.PERMISSION_DENIED then error(tostring(problem)) end
            end
            for pid in pairs(state.brokers) do M.join(state, pid) end
        end)
        local released, release_error = pcall(function()
            drain(state.catalogs, "bee.app.catalog")
            drain(state.replies, "bee.app.reply")
            drain(state.ready, "bee.app.ready")
            assert(process.unlisten(state.catalogs))
            assert(process.unlisten(state.replies))
            assert(process.unlisten(state.ready))
        end)
        assert(restored, tostring(restore_error))
        assert(stopped, tostring(stop_error))
        assert(released, tostring(release_error))
        assert(ok, tostring(fault))
    end
end
return M
