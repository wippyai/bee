-- MIT. The outbox pump's host-selected forwarding sender: it shapes one
-- claimed outbox delivery into the destination supervisor's forwarded inbox
-- send and returns the destination's own reply. It is the thread component's
-- injected transport, so Threads stays independent of Hive. The destination
-- admission authenticates the forwarded principal, re-checks the workspace,
-- send grant, target action and epoch, and commits only there; this sender
-- invents no authority, and an uncertain outcome is reported as such so the
-- pump repeats rather than settling.
local hive = require("hive")
local M = {}
M.OWNER_SERVICE = "bee.threads"
M.OPERATION = "bee.threads.service:inbox_send"
M.MAX_IDEMPOTENCY_BYTES = 160
type Object = {[string]: unknown}
type Options = {timeout: string?}
type Outcome = {ok: boolean, value: unknown, error: unknown}
-- deliver: forward one claimed delivery. The outbox identity is the pump's
-- lease token and never leaves this node; the sender's stable idempotency key
-- is what the destination deduplicates on.
local function deliver(delivery: Object, options: Options?): (Outcome?, string?)
    local thread_id = delivery.thread_id
    local target_action = delivery.target_action_id
    local destination_node = delivery.node_id
    if type(thread_id) ~= "string" or type(target_action) ~= "string" then return nil, "delivery names no destination" end
    if type(destination_node) ~= "string" then return nil, "delivery names no destination node" end
    local client, open_error = hive.open()
    if not client then return nil, open_error or "Hive client unavailable" end
    local input: Object = {}
    for name, item in pairs(delivery) do
        if name ~= "outbox_id" then input[name] = item end
    end
    local reply = client:call({node_id = destination_node, service_id = M.OWNER_SERVICE}, {operation_ref = M.OPERATION}, input,
        {idempotency_key = type(delivery.idempotency_key) == "string" and (delivery.idempotency_key :: string) or nil,
            timeout = options and options.timeout or nil})
    client:close()
    if reply.ok then return {ok = true, value = reply.value, error = nil}, nil end
    return {ok = false, value = nil, error = reply.error}, nil
end
M.deliver = deliver
return M
