-- MIT. Native contract consumer; transport and untrusted result decoding stay here.
local contract = require("contract")
local protocol = require("protocol")
type Journal = {
    read_after: (Journal, integer) -> (protocol.Reply?, string?),
    claim: (Journal, string) -> (protocol.Reply?, string?),
    append: (Journal, string, string, string, string) -> (protocol.Reply?, string?),
}
local M = {}
function M.open(thread: string): (Journal?, string?)
    if not protocol.id(thread) then return nil, "Invalid thread" end
    local binding, err = contract.open("bee.threads:local")
    if not binding then return nil, tostring(err) end
    local function decoded(raw: unknown, call_error: unknown): (protocol.Reply?, string?)
        if call_error then return nil, tostring(call_error) end
        local reply = protocol.decode(raw)
        if not reply then return nil, "Invalid journal response" end
        if not reply.ok then return nil, reply.error end
        return reply, nil
    end
    local function read_after(self: Journal, after: integer): (protocol.Reply?, string?)
        local raw, err = binding:read_after({thread = thread, after = after})
        local reply, read_error = decoded(raw, err)
        if reply then
            for _, event in ipairs(reply.events) do if event.seq <= after then return nil, "Invalid replay sequence" end end
        end
        return reply, read_error
    end
    local function claim(self: Journal, run: string): (protocol.Reply?, string?)
        local raw, err = binding:claim({thread = thread, run = run})
        return decoded(raw, err)
    end
    local function append(self: Journal, run: string, key: string, kind: string, body: string): (protocol.Reply?, string?)
        local raw, err = binding:append({thread = thread, run = run, key = key, kind = kind, body = body})
        return decoded(raw, err)
    end
    return {read_after = read_after, claim = claim, append = append}, nil
end
return M
