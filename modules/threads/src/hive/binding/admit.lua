-- MIT. The supervisor's worker for a verified thread operation: the host
-- mapping is read, the request admitted and executed as the mapped actor.
local registry = require("registry")
local time = require("time")
local types = require("types")
local admission = require("admission")
local function handle(value: unknown): types.Reply
    local request, err = types.decode_request(value)
    if not request then return types.reply_error("", types.fault("INVALID_ARGUMENT", err or "invalid request")) end
    local entry = registry.get(types.PRINCIPAL_MAPPINGS_ENTRY)
    local mappings, mappings_error = admission.mappings(entry)
    if not mappings then return types.reply_error(request.request_id, types.fault("UNAVAILABLE", mappings_error or "principal mappings unavailable")) end
    local admitted, fault = admission.admit(request.owner_ref.node_id, request, mappings, time.now())
    if not admitted then return types.reply_error(request.request_id, fault or types.fault("DENIED", "not admitted")) end
    return admission.execute(request.request_id, admitted)
end
return {handle = handle}
