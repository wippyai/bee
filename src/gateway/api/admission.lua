-- MIT. Shared HTTP admission for Gateway endpoints.
local http = require("http")
local gateway = require("gateway")
local M = {}
type Kind = "tool" | "hook"
type Rejection = {ok: false, status: number, message: string}
type Admission = {ok: true, action_id: string, binding: gateway.Binding, drain: gateway.Drain}
type Result = Rejection | Admission

local function rejection(status: number, message: string): Rejection
    return {ok = false, status = status, message = message}
end

local function auth_status(code: string): number
    if code == "DENIED" then return http.STATUS.FORBIDDEN end
    if code == "STORAGE" then return http.STATUS.INTERNAL_ERROR end
    return http.STATUS.UNAUTHORIZED
end

function M.check(request: http.Request, kind: Kind): Result
    local action_id = request:param("action")
    if not action_id or action_id == "" then return rejection(http.STATUS.NOT_FOUND, "no action") end
    if request:header("Origin") then return rejection(http.STATUS.FORBIDDEN, "browser origins are not admitted") end
    local authorization = request:header("Authorization") or ""
    local token = authorization:match("^Bearer%s+(%S+)$")
    if not token then return rejection(http.STATUS.UNAUTHORIZED, "bearer token required") end
    if not gateway.accepts_host(request:host() or "") then
        return rejection(http.STATUS.FORBIDDEN, "host is not the selected listener")
    end
    local binding, refusal = gateway.authenticate(token, action_id, kind)
    if not binding then
        local fault = refusal and refusal.error or {code = "UNAUTHENTICATED", message = "refused"}
        return rejection(auth_status(fault.code), fault.message)
    end
    local drain, drain_error = gateway.draining()
    if not drain then
        local fault = drain_error and drain_error.error
        local status = fault and auth_status(fault.code) or http.STATUS.SERVICE_UNAVAILABLE
        return rejection(status, fault and fault.message or "gateway drain state is unavailable")
    end
    if drain.past_deadline then return rejection(http.STATUS.SERVICE_UNAVAILABLE, "the gateway is shutting down") end
    return {ok = true, action_id = action_id, binding = binding, drain = drain}
end

return M
