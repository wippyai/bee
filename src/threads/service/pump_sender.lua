-- MIT. The outbox pump's forwarding sender: it shapes one claimed outbox
-- delivery into an inbox send on the destination node's threads route and
-- returns the destination's own reply. The destination's Threads service
-- authenticates the caller node, re-checks the workspace, send grant, target
-- action and epoch, and commits only there; this sender invents no
-- authority, and an uncertain outcome is reported as such so the pump
-- repeats rather than settling.
local protocol = require("protocol")
local M = {}
M.OPERATION = "threads.inbox_send"
type Object = {[string]: unknown}
type Options = {timeout: string?}
type Outcome = {ok: boolean, value: unknown, error: unknown}
-- deliver forwards one claimed delivery. The outbox identity is the pump's
-- lease token and never leaves this node; the sender's stable idempotency key
-- is what the destination deduplicates on.
local function deliver(delivery: Object, options: Options?): (Outcome?, string?)
    local thread_id = delivery.thread_id
    local target_action = delivery.target_action_id
    local destination_node = delivery.node_id
    if type(thread_id) ~= "string" or type(target_action) ~= "string" then return nil, "delivery names no destination" end
    if type(destination_node) ~= "string" then return nil, "delivery names no destination node" end
    local input: Object = {}
    for name, item in pairs(delivery) do
        if name ~= "outbox_id" then input[name] = item end
    end
    local reply, call_error = protocol.call(destination_node, M.OPERATION, input, options and options.timeout or "25s")
    if not reply then return nil, call_error end
    if reply.ok then return {ok = true, value = reply.value, error = nil}, nil end
    return {ok = false, value = nil, error = reply.error}, nil
end
M.deliver = deliver
return M
