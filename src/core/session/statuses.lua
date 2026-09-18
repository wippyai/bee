-- MIT. One session-owned reader per thread shown by its committed tabs.
-- A minimized tab still displays status in the bar. Presenter lifetimes do not
-- participate here; the session reconciles bindings only after owner changes.
local bindings = require("bindings")
local driver = require("driver")
local reader = require("reader")
local model = require("model")
local M = {}
type State = {bindings: bindings.State, readers: {[string]: driver.State}, start: driver.Start, closed: boolean}
type TabValue = {tab_id: string, instance_id: string, value: reader.Value}
function M.new(start: driver.Start): State
    return {bindings = bindings.new(), readers = {}, start = start, closed = false}
end
local function reconcile(state: State, now: integer)
    local wanted: {[string]: boolean} = {}
    for _, item in ipairs(state.bindings.items) do
        if item.thread_id then wanted[item.thread_id] = true end
    end
    for id, current in pairs(state.readers) do
        if not wanted[id] then driver.close(current); state.readers[id] = nil end
    end
    for id in pairs(wanted) do
        if not state.readers[id] then
            local current = driver.new(state.start)
            driver.bind(current, id, now)
            state.readers[id] = current
        end
    end
end
function M.apply(state: State, snapshot: bindings.Snapshot, scene: model.Scene, workspace: string, now: integer): boolean
    if state.closed then return false end
    local next_state = bindings.apply(state.bindings, snapshot, scene, workspace)
    if not next_state then return false end
    state.bindings = next_state
    reconcile(state, now)
    return true
end
function M.layout(state: State, scene: model.Scene, workspace: string, now: integer)
    if state.closed then return end
    state.bindings.items = bindings.prune(state.bindings.items, scene, workspace)
    reconcile(state, now)
end
function M.values(state: State): {TabValue}
    local values: {TabValue} = {}
    if state.closed then return values end
    for _, item in ipairs(state.bindings.items) do
        local current = item.thread_id and state.readers[item.thread_id] or nil
        if current then
            values[#values + 1] = {tab_id = item.tab_id, instance_id = item.instance_id, value = reader.value(current.reader)}
        end
    end
    return values
end
function M.close(state: State)
    if state.closed then return end
    state.closed = true
    for _, current in pairs(state.readers) do driver.close(current) end
    state.readers = {}
    state.bindings.items = {}
end
return M
