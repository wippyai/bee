local funcs = require("funcs")
local security = require("security")
local hash = require("hash")
local bounds = require("bounds")
local M = {}
local function call(operation: string, request: unknown): {[string]: unknown}
    local raw, err = funcs.call("bee.threads.binding:" .. operation, request)
    if err then error(tostring(err)) end
    return assert(bounds.object(raw))
end
local function value(reply: {[string]: unknown}): {[string]: unknown}
    if reply.ok ~= true then error(tostring(assert(bounds.object(reply.error)).message)) end
    return assert(bounds.object(reply.value))
end
function M.run(raw: unknown): {[string]: unknown}
    local request = assert(bounds.object(raw))
    local session, thread, trait = assert(bounds.id(request.session_ref)), assert(bounds.id(request.thread_id)), assert(bounds.id(request.trait_id))
    local actor = assert(security.actor())
    local workspace, definition = assert(bounds.id(actor:meta().workspace_id)), assert(bounds.id(actor:meta().definition_id))
    local index = "memory:" .. assert(hash.sha256(workspace .. ":" .. definition))
    local existing = call("get", {thread_id = index})
    if existing.ok ~= true then
        local fault = assert(bounds.object(existing.error))
        if fault.code ~= "NOT_FOUND" then return existing end
        value(call("create", {thread_id = index, title = "Remembered facts", idempotency_key = "memory-index"}))
    end
    local subscribed = call("subscribe", {thread_id = thread, idempotency_key = "memory:" .. session,
        filter = {session_ref = session, trait_id = trait}})
    if subscribed.ok ~= true then return subscribed end
    local subscription = value(subscribed).subscription_id
    local reply = call("page", {thread_id = thread, subscription_id = subscription})
    if reply.ok ~= true then return reply end
    local page = value(reply)
    local indexed = 0
    for _, raw_event in ipairs(assert(bounds.array(page.events, 64))) do
        local event = assert(bounds.object(raw_event))
        local payload = bounds.object(event.payload)
        local result = payload and bounds.object(payload.result)
        local output = result and bounds.object(result.value)
        local text = output and bounds.text(output.text)
        local fact = text and text:match("^fact:%s*(.+)")
        if fact then
            local recorded = call("record", {thread_id = index, idempotency_key = event.id, kind = "observation", source = "mcp",
                body = {type = "text", event_key = event.id, raw_ref = event.id,
                    data = {type = "text", segment_id = event.id, operation = "complete", channel = "answer", text = fact}}})
            value(recorded)
            if recorded.replayed ~= true then indexed = indexed + 1 end
        end
    end
    if page.page_id then
        local acknowledged = call("ack_page", {thread_id = thread, subscription_id = subscription, page_id = page.page_id,
            scanned_through = page.scanned_through, idempotency_key = page.page_id})
        if acknowledged.ok ~= true then return acknowledged end
    end
    return {ok = true, value = {index_thread = index, subscription_id = subscription, indexed = indexed}}
end
function M.main(request: unknown): {[string]: unknown}
    return M.run(request)
end
return M
