-- MIT. Hook-boundary inbox context: at a supported UserPromptSubmit or
-- Stop hook boundary the hook response may carry the bound action's
-- outstanding inbox items, bounded and identified, so the agent learns
-- its mail without polling and without anything typed into its PTY. The
-- read runs as the binding's subject: the same principal session_inbox
-- serves through the same bearer, and only where the binding admitted
-- session_inbox, so the response confers no new capability. No decision,
-- permission or control field ever travels here.
local bounds = require("bounds")
local canonical = require("canonical")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local subject_call = require("subject_call")
local gateway = require("gateway")
local M = {}
M.SUPPORTED_EVENTS = {UserPromptSubmit = true, Stop = true}
M.MAX_ITEMS = 3
M.EXCERPT_BYTES = 512
type Object = {[string]: unknown}
function M.supported(event: string?): boolean
    if type(event) ~= "string" then return false end
    return M.SUPPORTED_EVENTS[event] == true
end
local function excerpt(content: unknown): string
    local object = bounds.object(content)
    if object then
        local text = bounds.text(object.text)
        if text then
            if #text > M.EXCERPT_BYTES then return text:sub(1, M.EXCERPT_BYTES - 32) .. "...[truncated]" end
            return text
        end
    end
    local encoded = canonical.encode(content)
    if encoded then
        if #encoded > M.EXCERPT_BYTES then return encoded:sub(1, M.EXCERPT_BYTES - 32) .. "...[truncated]" end
        return encoded
    end
    return "undecodable inbox content"
end
-- format: the bounded identified context for outstanding items. Every
-- item names its record, message, sequence and sender; content travels
-- as a bounded excerpt. The more flag names waiting items without
-- inventing a total the page did not report.
function M.format(items: {Object}, more: boolean): string
    local shown: {string} = {}
    for index, item in ipairs(items) do
        if index > M.MAX_ITEMS then break end
        local record_id, message_id = bounds.id(item.record_id), bounds.id(item.message_id)
        local sequence = bounds.integer(item.inbox_sequence)
        local sender = bounds.id(item.sender_action_id)
        if record_id and message_id and sequence and sequence >= 1 and sender then
            shown[#shown + 1] = "record " .. record_id .. " message " .. message_id .. " sequence " .. tostring(sequence) .. " from " .. sender .. ": " .. excerpt(item.content)
        end
    end
    if #shown == 0 then return "" end
    local head = "Bee action inbox, showing " .. tostring(#shown) .. ": "
    if more then head = head .. "more waiting; " end
    return head .. table.concat(shown, "; ")
end
local function reader(binding: gateway.Binding): (funcs.Executor?, string?)
    local admitted = false
    for _, name in ipairs(binding.tools) do if name == "session_inbox" then admitted = true end end
    if not admitted then return nil, "the binding did not admit session_inbox" end
    local entry, entry_error = registry.get("bee.gateway:tool_inbox_policy_ref")
    if entry_error or not entry then return nil, "built-in tool policy reference is unavailable" end
    local data = bounds.object(entry.data)
    local selected = data and bounds.id(data.resource_ref)
    if not selected then return nil, "built-in tool policy is not linked by the host" end
    local policy, policy_error = security.policy(selected)
    if policy_error or not policy then return nil, "inbox policy is unavailable" end
    local executor, setup_error = subject_call.executor(binding, {policy}, {}, nil)
    if not executor then
        local fault = setup_error and setup_error.error
        return nil, fault and fault.message or "bound subject executor is unavailable"
    end
    return executor, nil
end
-- context: the formatted outstanding inbox for the bound action at a
-- supported boundary, or nil where the event is unsupported, the bearer
-- carries no inbox grant, or nothing outstanding waits. A read failure
-- degrades to nil so hook intake never breaks on its side channel; the
-- hook record itself is already committed by the caller.
function M.context(binding: gateway.Binding, event: string?): (string?, string?)
    if not M.supported(event) then return nil, nil end
    local executor, reader_error = reader(binding)
    if not executor then return nil, reader_error end
    local reply, call_error = executor:call("bee.threads.service:inbox_list",
        {thread_id = binding.thread_id, action_id = binding.action_id, after_sequence = 0, limit = M.MAX_ITEMS + 1})
    if call_error then return nil, tostring(call_error) end
    local page = bounds.object(reply)
    if not page or type(page.ok) ~= "boolean" then return nil, "inbox owner returned an invalid reply" end
    if not page.ok then
        local code, message = bounds.id(page.code), bounds.text(page.message, 4096)
        if not code or not message then return nil, "inbox owner returned an invalid failure" end
        return nil, "inbox read " .. code .. ": " .. message
    end
    local value = bounds.object(page.value)
    if not value then return nil, "inbox owner returned an invalid page" end
    local items, items_error = bounds.array(value.items, M.MAX_ITEMS + 1)
    if not items then return nil, "inbox owner returned invalid items: " .. tostring(items_error) end
    local outstanding: {Object} = {}
    for _, raw in ipairs(items) do
        local item = bounds.object(raw)
        local record_id = item and bounds.id(item.record_id)
        local message_id = item and bounds.id(item.message_id)
        local sequence = item and bounds.integer(item.inbox_sequence)
        local sender = item and bounds.id(item.sender_action_id)
        local state = item and bounds.member(item.state, {"committed", "offered", "transport_accepted", "acknowledged", "replied"})
        if not item or not record_id or not message_id or not sequence or sequence < 1 or not sender or not state then
            return nil, "inbox owner returned an invalid item"
        end
        if state ~= "acknowledged" and state ~= "replied" then outstanding[#outstanding + 1] = item end
    end
    if #outstanding == 0 then return nil, nil end
    return M.format(outstanding, #outstanding > M.MAX_ITEMS), nil
end
-- carry_text: the Codex hook response text for a recorded event: the
-- context where a supported boundary turns plain text into model
-- context, else nil for the endpoint's proven shape. Stop never
-- carries: no fixture proves the JSON Codex requires there; anything
-- outside the supported set answers exactly as before.
function M.carry_text(event: string?, context_text: string?): string?
    if M.supported(event) and event ~= "Stop" and context_text and context_text ~= "" then return context_text end
    return nil
end
-- http_body: the Claude hook response body for a supported event: the
-- additionalContext field Claude's hook contract reads as model context.
function M.http_body(context_text: string?): Object?
    if not context_text or context_text == "" then return nil end
    return {additionalContext = context_text}
end
return M
