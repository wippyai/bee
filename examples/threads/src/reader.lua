-- MIT. Small typed consumer over the native contract; no storage authority.
local contract = require("contract")
local client = require("client")
type Reader = {read_after: (Reader, integer) -> (client.Reply?, string?)}
local M = {}
function M.open(owner: string, thread: string, capability: string): (Reader?, string?)
    local binding, err = contract.open("bee.thread_demo:reader_binding")
    if not binding then return nil, tostring(err) end
    local function read_after(self: Reader, after: integer): (client.Reply?, string?)
        local raw, call_error = binding:read_after(owner, thread, capability, after)
        if call_error then return nil, tostring(call_error) end
        local reply = client.decode(raw)
        if not reply then return nil, "Invalid thread read response" end
        for _, event in ipairs(reply.rows) do
            if event.seq <= after then return nil, "Thread read moved behind its cursor" end
        end
        if reply.error ~= "" then return nil, reply.error end
        return reply, nil
    end
    return {read_after = read_after}, nil
end
return M
