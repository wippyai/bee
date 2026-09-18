-- MIT. An application's caller toward an owner service: a typed reply or,
-- when the transport gives no usable answer, nothing at all, which the
-- caller's model treats as an unknown outcome to recover by reading. The
-- caller runs under the process's own actor; it selects no identity and
-- holds no authority of its own.
local M = {}
type Fault = {code: string, message: string}
type Reply = {ok: boolean, error: Fault?, value: unknown, replayed: boolean?}
type Call = (string, unknown) -> (unknown, string?)
type Client = {invoke: (Client, string, unknown) -> Reply?}
function M.decode(raw: unknown): Reply?
    if type(raw) ~= "table" then return nil end
    local reply = raw :: {[string]: unknown}
    if type(reply.ok) ~= "boolean" then return nil end
    local fault: Fault? = nil
    if type(reply.error) == "table" then
        local declared = reply.error :: {[string]: unknown}
        fault = {code = tostring(declared.code or "INTERNAL"), message = tostring(declared.message or "")}
    elseif reply.ok == false then
        fault = {code = "INTERNAL", message = "the owner answered without a fault"}
    end
    return {ok = reply.ok :: boolean, error = fault, value = reply.value, replayed = reply.replayed == true}
end
function M.new(call: Call): Client
    local function invoke(_: Client, target: string, request: unknown): Reply?
        local raw, err = call(target, request)
        if err then return nil end
        return M.decode(raw)
    end
    return {invoke = invoke}
end
-- An answer the transport never delivered: unknown, never a refusal of
-- the owner's own.
function M.unknown(): Reply
    return {ok = false, error = {code = "UNAVAILABLE", message = "no answer from the owner"}, value = nil, replayed = false}
end
return M
