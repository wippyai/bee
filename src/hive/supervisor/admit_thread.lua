-- MIT. The supervisor's worker for a verified thread operation: the host
-- mapping is read, the request admitted and executed as the mapped actor.
local registry = require("registry")
local time = require("time")
local types = require("types")
local thread_admission = require("thread_admission")
local principals = require("principals")
local function handle(value: unknown): types.Reply
    local request, err = types.decode_request(value)
    if not request then return types.reply_error("", types.fault("INVALID_ARGUMENT", err or "invalid request")) end
    local entry = registry.get(principals.ENTRY)
    local mappings, mappings_error = thread_admission.mappings(entry)
    if not mappings then return types.reply_error(request.request_id, types.fault("UNAVAILABLE", mappings_error or "principal mappings unavailable")) end
    local admission, fault = thread_admission.admit(request.owner_ref.node_id, request, mappings, time.now())
    if not admission then return types.reply_error(request.request_id, fault or types.fault("DENIED", "not admitted")) end
    return thread_admission.execute(request.request_id, admission)
end
return {handle = handle}
