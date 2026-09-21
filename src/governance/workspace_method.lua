-- MIT. Public authoring facade. It authenticates the caller's exact operation
-- before entering the fixed private storage scope; actor context is inherited.
local funcs = require("funcs")
local security = require("security")
local protocol = require("protocol")
local guide = require("guide")
local transaction = require("transaction")
local bounds = require("bounds")

local BACKEND = "bee.governance:workspace_backend_call"
local EXECUTION_SCOPE = "bee.governance:workspace_execution_scope"
type Result = transaction.Result

local function decode_reply(value: unknown): Result?
    local reply = bounds.object(value)
    if not reply then return nil end
    if type(reply.ok) ~= "boolean" or type(reply.replayed) ~= "boolean" then return nil end
    if reply.code ~= nil and type(reply.code) ~= "string" then return nil end
    if reply.message ~= nil and type(reply.message) ~= "string" then return nil end
    if reply.commit ~= nil and type(reply.commit) ~= "boolean" then return nil end
    local projected: unknown = reply.value
    local stored = bounds.object(projected)
    if stored and stored.workspace_id ~= nil then
        local public: {[string]: unknown} = {}
        for key, item in pairs(stored) do if key ~= "workspace_id" then public[key] = item end end
        public.overlay_id = stored.workspace_id
        projected = public
    end
    local code: string? = nil
    if type(reply.code) == "string" then code = reply.code end
    local message: string? = nil
    if type(reply.message) == "string" then message = reply.message:gsub("workspace", "overlay") end
    local commit: boolean? = nil
    if type(reply.commit) == "boolean" then commit = reply.commit end
    local result: Result = {ok = reply.ok, code = code, message = message,
        value = projected, replayed = reply.replayed, commit = commit}
    return result
end

local function handle(raw: unknown): Result
    local request, invalid = protocol.decode_overlay(raw)
    if not request then return transaction.failure("INVALID", invalid or "invalid overlay request") end
    -- The guide is this destination's fixed authoring contract. It names no
    -- overlay, reads no store and grants nothing, so it returns before the
    -- caller's overlay ownership is consulted.
    if request.operation == "guide" then
        return transaction.success(guide.value(), false)
    end
    local actor = security.actor()
    local action = (request.operation == "read" or request.operation == "list")
        and "bee.governance.overlay.read" or "bee.governance.overlay.write"
    if not actor or not security.can(action, request.workspace_id) then
        return transaction.failure("DENIED", "overlay operation is not authorized")
    end
    local scope, scope_error = security.named_scope(EXECUTION_SCOPE)
    if not scope then return transaction.failure("UNAVAILABLE", tostring(scope_error or "workspace execution scope unavailable")) end
    local executor, executor_error = funcs.new():with_scope(scope)
    if not executor then return transaction.failure("DENIED", tostring(executor_error or "workspace execution scope denied")) end
    local result, call_error = executor:call(BACKEND, request)
    if call_error then return transaction.failure("UNAVAILABLE", tostring(call_error)) end
    local reply = decode_reply(result)
    if not reply then return transaction.failure("INTERNAL", "workspace backend returned a malformed reply") end
    return reply
end
return {handle = handle}
