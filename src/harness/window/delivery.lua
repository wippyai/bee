-- MIT. One funcs.async future for window hook delivery. Completions match
-- the exact pending identity; a cancelled future keeps its commit request.
local funcs = require("funcs")
local channel = require("channel")
local hooks = require("hooks")
local M = {}
M.TIMEOUT_MS = 35000
type Channel = channel.Channel
type Start = (hooks.Intent) -> (funcs.Future?, string?)
type Pending = {identity: string, future: funcs.Future, response: Channel<unknown>, intent: hooks.Intent, deadline: integer}
type Driver = {state: hooks.State, start: Start, key: () -> string, pending: Pending?}
function M.new(state: hooks.State, start: Start, key: () -> string): Driver
    return {state = state, start = start, key = key, pending = nil}
end
local function cancel(driver: Driver)
    local pending = driver.pending
    driver.pending = nil
    if pending then pending.future:cancel() end
end
function M.advance(driver: Driver, now: integer): Pending?
    local state = driver.state
    hooks.expire(state, now)
    if hooks.finished(state) then cancel(driver); return nil end
    local pending = driver.pending
    if pending then
        if now >= pending.deadline then
            cancel(driver)
            hooks.lost(state, pending.identity)
        else
            return pending
        end
    end
    local intent = hooks.next_intent(state, driver.key(), now)
    if not intent then return nil end
    local identity = driver.key()
    if not hooks.begin(state, identity, intent) then return nil end
    local future, err = driver.start(intent)
    if err or not future then
        hooks.lost(state, identity)
        hooks.backoff(state, now)
        return nil
    end
    local response = future:response() :: Channel<unknown>
    if not response then
        future:cancel()
        hooks.lost(state, identity)
        hooks.backoff(state, now)
        return nil
    end
    local deadline = now + M.TIMEOUT_MS
    local drain = state.drain_deadline
    if drain and drain < deadline then deadline = drain end
    local admitted: Pending = {identity = identity, future = future, response = response, intent = intent, deadline = deadline}
    driver.pending = admitted
    return admitted
end
function M.complete(driver: Driver, pending: Pending, now: integer): boolean
    if driver.pending ~= pending then return false end
    if now >= pending.deadline then
        cancel(driver)
        driver.state.clock = now
        hooks.lost(driver.state, pending.identity)
        hooks.expire(driver.state, now)
        return false
    end
    driver.pending = nil
    driver.state.clock = now
    local result, err = pending.future:result()
    if err or not result then
        hooks.lost(driver.state, pending.identity)
        return true
    end
    local reply = hooks.decode(result:data())
    if not reply then
        hooks.lost(driver.state, pending.identity)
        return true
    end
    return hooks.apply(driver.state, pending.identity, reply)
end
function M.shutdown(driver: Driver, now: integer, closed: boolean)
    cancel(driver)
    hooks.shutdown(driver.state, now, closed)
end
function M.due(driver: Driver): integer
    local pending = driver.pending
    if pending then return pending.deadline end
    return driver.state.due
end
function M.cancel(driver: Driver)
    cancel(driver)
end
return M
