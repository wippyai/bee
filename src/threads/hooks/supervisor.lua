local funcs = require("funcs")
local channel = require("channel")
local time = require("time")
local process = require("process")
local registry = require("registry")
local bounds = require("bounds")
local hook_limits = require("hook_limits")
local M = {}
M.MAX_INVOCATIONS = 16
M.MAX_REPLY_BYTES = 16384
M.MAX_CONTEXT_BYTES = 24576
M.MAX_TURN_BYTES = 131072
type Budget = {invocation_ms: integer, chain_ms: integer}
type Pending = {id: string, future: funcs.Future, started: time.Time, limit_ms: integer, active: boolean}
type Request = {id: string, target: string, point: string, turn: {[string]: unknown}, application_ref: string,
    application_revision: string, driver: string, remaining_ms: integer}
function M.now(): time.Time return time.now() end
function M.remaining(started: time.Time, limit_ms: integer): integer
    return math.floor(math.max(0, limit_ms - time.now():sub(started):milliseconds()))
end
function M.budget(driver: string, point: string): Budget
    local entry = assert(registry.get("bee.threads.hooks:budget"))
    local declared = assert(bounds.object(entry.data))
    local invocation = assert(bounds.integer(declared.invocation_ms))
    local chain = assert(bounds.integer(declared.chain_ms))
    assert(invocation > 0 and invocation <= 60000 and chain > 0 and chain <= 60000, "invalid host hook budget")
    local seconds = hook_limits.seconds(driver, point)
    if seconds then chain = math.min(chain, seconds * 1000) end
    return {invocation_ms = math.min(invocation, chain), chain_ms = chain}
end
function M.accept(pending: Pending, id: string): boolean
    if not pending.active or pending.id ~= id or M.remaining(pending.started, pending.limit_ms) == 0 then return false end
    pending.active = false
    return true
end
function M.cancel(pending: Pending)
    pending.active = false
    pending.future:cancel()
end
function M.run(executor: funcs.Executor, target: string, id: string, point: string, turn: unknown, limit_ms: integer): (unknown, string?)
    if limit_ms <= 0 then return nil, "chain budget exceeded" end
    local started = M.now()
    local future, err = executor:async(target, point, turn)
    if not future or err then return nil, "hook crashed: " .. tostring(err) end
    local pending: Pending = {id = id, future = future, started = started, limit_ms = limit_ms, active = true}
    local response = future:response()
    if not response then M.cancel(pending); return nil, "hook response channel is unavailable" end
    local lifecycle = assert(process.events())
    local budget = time.after(tostring(M.remaining(started, limit_ms)) .. "ms")
    while true do
        local selected = channel.select({response:case_receive(), budget:case_receive(), lifecycle:case_receive()})
        if not selected.ok or selected.channel == budget then M.cancel(pending); return nil, "invocation budget exceeded" end
        if selected.channel == lifecycle then
            if selected.value.kind == process.event.CANCEL then M.cancel(pending); return nil, "hook supervisor cancelled" end
        else
            if not M.accept(pending, id) then M.cancel(pending); return nil, "invocation budget exceeded" end
            local result, failure = future:result()
            if not result or failure then return nil, "hook crashed: " .. tostring(failure) end
            return result:data(), nil
        end
    end
end
function M.invoke(request: Request): (unknown, string?)
    local raw, err = funcs.call("bee.threads.hooks:invocation", request)
    local reply = bounds.object(raw)
    if err or not reply or reply.invocation_id ~= request.id then return nil, "hook supervision failed: " .. tostring(err) end
    return reply.reply, bounds.text(reply.diagnostic, 4096)
end
return M
