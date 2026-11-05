-- MIT. The Library session: the state one open Library window shares across
-- its input handling, Hub reads and actions, and the worker that runs governed
-- calls one at a time so a delayed owner never blocks the presentation loop.
local channel = require("channel")
local funcs = require("funcs")
local confirmation = require("confirmation")
local client = require("client")
local model = require("model")
local governed = require("governed")
local hub = require("hub")
local view = require("view")
local M = {}
type Reply = {ok: boolean, code: string?, message: string?, full_message: string?, value: unknown, replayed: boolean}
type Pending = {future: funcs.Future, response: channel.Channel, operation: string, generation: integer, apply: boolean}
type ReadPending = {future: funcs.Future, response: channel.Channel, operation: string, generation: integer, retired: boolean}
type Gesture = "enter" | "space" | "click" | "shortcut"
-- Session is the mutable state of one window: the model, the screen's view
-- state, the Hub read queue under its generation, and the busy and gesture
-- flags the worker and the presentation loop agree on.
type Session = {
    state: model.State,
    hubs: hub.State,
    gov: governed.State,
    ui: view.Ui,
    review: confirmation.State,
    launch: client.Launch?,
    updates: channel.Channel<boolean>,
    pending: {Pending},
    reads: {hub.Intent},
    reading: ReadPending?,
    generation: integer,
    running: boolean,
    dirty: boolean,
    busy: boolean,
    apply_pending: boolean,
    gesture: Gesture,
    effect_gesture: Gesture,
    visible_rows: integer,
}
-- Base is what the window's other code calls to repaint, report a failure,
-- retire stale reads and run work on the worker.
type Work = () -> ()
type Base = {changed: () -> (), failure: (string) -> (), wake: () -> (), invalidate: () -> (), perform: (Work) -> boolean, background: (Work) -> ()}

local function reply(value: unknown): Reply
    if type(value) == "table" and type(value.ok) == "boolean" and type(value.replayed) == "boolean" then
        local raw = value
        local receipt = type(raw.value) == "table" and raw.value or nil
        local state = receipt and type(receipt.state) == "string" and receipt.state or ""
        local failed = state == "failed" or state == "recovery_required"
        return {ok = raw.ok == true and not failed, replayed = raw.replayed == true,
            code = failed and (type(raw.code) == "string" and raw.code ~= "OK" and raw.code or state:upper()) or (type(raw.code) == "string" and raw.code or nil),
            message = type(raw.message) == "string" and raw.message or nil,
            full_message = type(raw.full_message) == "string" and raw.full_message or nil, value = raw.value}
    end
    return {ok = false, replayed = false, code = "UNCERTAIN", message = "Hub reply was unavailable", value = nil}
end

function M.completed(pending: Pending): Reply
    local result, err = pending.future:result()
    if err or not result then return {ok = false, replayed = false, code = "UNCERTAIN", message = tostring(err or "Hub call ended without a reply"), value = nil} end
    return reply(result:data())
end

function M.new(ctx: Session): Base
    local state, hubs, gov, ui = ctx.state, ctx.hubs, ctx.gov, ctx.ui
    local function changed()
        ctx.dirty = true
    end
    local function failure(reason: string)
        ui.status = reason
        state.notice, hubs.notice, gov.fault = reason, reason, reason
    end
    local function wake()
        ctx.dirty = true
        if ctx.running then ctx.updates:send(true) end
    end
    local function invalidate()
        ctx.generation = ctx.generation + 1
        ctx.reads = {}
    end
    local function perform(operation: () -> ()): boolean
        if ctx.busy then
            ui.status = "Request in progress"
            -- This branch runs on the presentation loop. The worker may
            -- already have filled the one-slot wakeup channel, so sending
            -- here could block the only receiver. Painting needs no wakeup.
            ctx.dirty = true
            return false
        end
        ctx.busy = true
        ctx.effect_gesture = ctx.gesture
        ui.status = "Working…"
        ctx.dirty = true
        coroutine.spawn(function()
            local ok, problem = pcall(operation)
            ctx.busy = false
            if not ctx.running then return end
            if not ok then
                failure(tostring(problem))
            elseif ui.status == "Working…" then ui.status = "" end
            wake()
        end)
        return true
    end
    -- background runs a read without announcing work, so the footer stays still
    -- while the list follows an install.
    local function background(operation: () -> ())
        if ctx.busy then return end
        ctx.busy = true
        coroutine.spawn(function()
            local ok, problem = pcall(operation)
            ctx.busy = false
            if not ctx.running then return end
            if not ok then failure(tostring(problem)) end
            wake()
        end)
    end
    return {changed = changed, failure = failure, wake = wake, invalidate = invalidate, perform = perform, background = background}
end
return M
