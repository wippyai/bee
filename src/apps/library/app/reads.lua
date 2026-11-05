-- MIT. The Library Hub reads: one read at a time under a generation, so
-- navigation retires what was asked before it and a stale answer never changes
-- the model, and the Hub apply that runs beside the reads.
local funcs = require("funcs")
local model = require("model")
local hub = require("hub")
local contents = require("contents")
local delivery_actions = require("delivery_actions")
local session = require("session")
local new_key = delivery_actions.new_key
type Reply = session.Reply
type Reads = {fold_read: (string, Reply) -> (), start_next: () -> (), begin: ({hub.Intent}) -> boolean, begin_apply: (hub.Intent) -> boolean}
local M = {}

function M.new(ctx: session.Session, base: session.Base, actions: delivery_actions.Actions): Reads
    local state, hubs, gov, ui = ctx.state, ctx.hubs, ctx.gov, ctx.ui
    local changed, failure, invalidate, perform = base.changed, base.failure, base.invalidate, base.perform
    local review_hub_now = actions.review_hub_now
    -- Hub reads run one at a time under a generation: navigation retires what
    -- was asked before it, and a stale answer never changes the model.
    local function read_operation(intent: hub.Intent): string
        return intent.operation == "status" and intent.expected_digest == nil and "history" or intent.operation
    end
    local function fold_read(operation: string, value: Reply)
        if operation == "state" or operation == "files" or operation == "read_file" then contents.apply(ui.content, operation, value)
        elseif operation == "catalog" then hub.apply_catalog(hubs, value)
        elseif operation == "installed" then
            ui.status = ""
            hub.apply_installed(hubs, value)
            if hubs.action == "update" and hubs.installed_read == "ready" then hubs.notice = "Installed settings loaded" end
            if state.tab == "installed" and hubs.installed_read == "ready" and hubs.phase == "installed" then
                hub.begin_updates(hubs)
                table.insert(ctx.reads, 1, hub.updates_intent(hubs))
            end
        elseif operation == "updates" then hub.apply_updates(hubs, value)
        elseif operation == "details" then hub.apply_details(hubs, value)
        elseif operation == "inspect" then hub.apply_inspect(hubs, value)
        elseif operation == "plan" then
            ui.status = ""
            local request, problem = hub.governed_request(hubs, value, state.workspace_id, new_key())
            if request then perform(function() review_hub_now(request) end)
            elseif problem then hubs.notice, gov.fault = problem, problem
            else
                hub.apply_plan(hubs, value)
                if hubs.requirements_open and hubs.phase == "details" then
                    ui.content.open, ui.reading, ui.offset = false, false, 0
                    if not hubs.detail then
                        local detail = hub.details_intent(hubs)
                        if detail then table.insert(ctx.reads, 1, detail) end
                    end
                end
                gov.fault = hubs.notice
            end
        elseif operation == "status" then hub.apply_result(hubs, value)
        elseif operation == "history" then hub.apply_history(hubs, value) end
        if not value.ok then
            failure((value.code or "UNAVAILABLE") .. ": " .. (value.full_message or value.message or "Hub read failed"))
        elseif operation == "state" or operation == "files" or operation == "read_file" then
            if ui.content.fault ~= "" then failure(ui.content.fault) end
        elseif operation ~= "status" and hubs.notice ~= "" and hubs.notice ~= "Installed settings loaded" then
            failure(hubs.notice)
        end
    end
    local function start_next()
        if ctx.reading then return end
        while #ctx.reads > 0 do
            local next_intent = table.remove(ctx.reads, 1)
            local stamped = ctx.generation
            local future, err = funcs.new():async(hub.HUB, next_intent)
            if not future or err then
                fold_read(read_operation(next_intent), {ok = false, replayed = false, code = "UNCERTAIN", message = tostring(err or "Hub dispatch unavailable"), value = nil})
            else
                local response = future:response()
                if not response then
                    future:cancel()
                    fold_read(read_operation(next_intent), {ok = false, replayed = false, code = "UNAVAILABLE", message = "Hub response channel unavailable", value = nil})
                else
                    ctx.reading = {future = future, response = response, operation = read_operation(next_intent), generation = stamped, retired = false}
                    return
                end
            end
        end
    end
    -- begin asks the Hub. A read replaces what was asked before it; an apply
    -- runs beside the reads and is never retried by this client.
    local function begin(intents: {hub.Intent}): boolean
        invalidate()
        ctx.reads = intents
        if ctx.reading then
            -- Keep the stale read alive until its response is consumed. A
            -- future cancellation is delivered as this app's lifecycle
            -- cancellation, which would terminate the UI before a queued
            -- retry can start. The generation fence below still prevents
            -- the stale response from changing model state.
            ctx.reading.retired = true
        else start_next() end
        return true
    end
    local function begin_apply(intent: hub.Intent): boolean
        local future, err = funcs.new():async(hub.HUB, intent)
        if not future or err then
            hub.apply_result(hubs, {ok = false, replayed = false, code = "UNCERTAIN", message = tostring(err or "Hub dispatch unavailable"), value = nil})
            failure(hubs.result and hubs.result.message or "Hub apply unavailable")
            ctx.apply_pending = false
            changed()
            return false
        end
        local response = future:response()
        if not response then
            future:cancel()
            hub.apply_result(hubs, {ok = false, replayed = false, code = "UNCERTAIN", message = "Hub response channel unavailable", value = nil})
            failure(hubs.result and hubs.result.message or "Hub apply unavailable")
            ctx.apply_pending = false
            changed()
            return false
        end
        ctx.pending[#ctx.pending + 1] = {future = future, response = response, operation = intent.operation, generation = 0, apply = true}
        return true
    end

    return {fold_read = fold_read, start_next = start_next, begin = begin, begin_apply = begin_apply}
end
return M
