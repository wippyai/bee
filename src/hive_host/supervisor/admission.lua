-- MIT. Request identity and lifetime checks. No grants or role assertions.
-- The process owner supplies native sender identity and its established peer.
local types = require("types")
local peers = require("peers")
local catalog = require("catalog")
local time = require("time")
local M = {}
local FORMAT = "2006-01-02T15:04:05.000Z07:00"
local MAX_LIFETIME_MS = 30000
local function timestamp(value: string): time.Time?
    local parsed, err = time.parse(FORMAT, value)
    if err or not parsed or parsed:utc():format(FORMAT) ~= value then return nil end
    return parsed
end
local function fail(code: string, message: string): types.Fault
    return types.fault(code, message)
end
-- Initial identity is an originating-node-qualified actor PID. It cannot
-- express a human identity, foreign issuer, delegated role or attribute.
function M.accept(local_node: string, peer: peers.Peer?, sender: string, value: unknown, now: time.Time): (types.Request?, types.Fault?)
    if not peer or peer.pid ~= sender then
        return nil, fail("DENIED", "sender has no established supervisor session")
    end
    local sender_node, sender_host = types.pid_parts(sender)
    if sender_node ~= peer.node_id or sender_host ~= types.SUPERVISOR_HOST or sender_node == local_node then
        return nil, fail("DENIED", "sender is not the expected remote supervisor")
    end
    local request, err = types.decode_request(value)
    if not request then return nil, fail("INVALID_ARGUMENT", err or "invalid request") end
    if request.caller_node_id ~= peer.node_id or request.caller_incarnation ~= peer.supervisor_incarnation then
        return nil, fail("DENIED", "request does not match the established peer incarnation")
    end
    if request.owner_ref.node_id ~= local_node then
        return nil, fail("DENIED", "request owner is not on this node")
    end
    local subject_node = types.pid_parts(request.principal_ref.subject_id)
    if request.principal_ref.issuer ~= peer.node_id or subject_node ~= peer.node_id then
        return nil, fail("DENIED", "principal is outside the peer's actor namespace")
    end
    local issued = timestamp(request.principal_assertion.issued_at)
    local expires = timestamp(request.principal_assertion.expires_at)
    local deadline = timestamp(request.deadline)
    if not issued or not expires or not deadline then
        return nil, fail("INVALID_ARGUMENT", "request contains an invalid calendar timestamp")
    end
    if issued:after(now) then return nil, fail("DENIED", "principal assertion is not yet valid") end
    if not expires:after(now) or not deadline:after(now) then
        return nil, fail("DEADLINE_EXCEEDED", "request or assertion has expired")
    end
    if expires:sub(issued):milliseconds() > MAX_LIFETIME_MS or deadline:sub(now):milliseconds() > MAX_LIFETIME_MS then
        return nil, fail("INVALID_ARGUMENT", "request exceeds the 30 second lifetime")
    end
    return request, nil
end
-- Called only after the local Call and selected operation have been decoded.
-- The supplied exchange id is supervisor-owned; the route retains the client's
-- original id, so two local actors cannot collide at a remote supervisor.
function M.forward(local_node: string, incarnation: string, sender: string, exchange_id: string,
    call: types.Call, resolved: catalog.ResolvedCall, now: time.Time): (types.Request?, types.Fault?)
    local sender_node = types.pid_parts(sender)
    if sender_node ~= local_node and not (sender_node == "" and local_node == "local" and call.owner_ref.node_id == "local") then
        return nil, fail("DENIED", "caller is not a local actor")
    end
    local deadline = now:add("30s")
    if call.deadline then
        local requested = timestamp(call.deadline)
        if not requested then return nil, fail("INVALID_ARGUMENT", "invalid call deadline") end
        if requested:before(deadline) then deadline = requested end
    end
    if not deadline:after(now) then return nil, fail("DEADLINE_EXCEEDED", "call deadline has passed") end
    local value: types.Request = {
        protocol_revision = types.REVISION, request_id = exchange_id, idempotency_key = call.idempotency_key,
        caller_node_id = local_node, caller_incarnation = incarnation, owner_ref = call.owner_ref,
        operation_ref = resolved.operation.operation_ref, operation_revision = resolved.operation.revision,
        input = resolved.input, input_digest = resolved.input_digest,
        principal_ref = {issuer = local_node, subject_id = sender},
        principal_assertion = {method = types.ASSERTION_METHOD, audience = call.owner_ref.node_id,
            issued_at = now:utc():format(FORMAT), expires_at = deadline:utc():format(FORMAT)},
        delegation_refs = {}, deadline = deadline:utc():format(FORMAT),
    }
    local checked, err = types.decode_request(value)
    if not checked then return nil, fail("INVALID_ARGUMENT", err or "cannot construct forwarded request") end
    return checked, nil
end
return M
