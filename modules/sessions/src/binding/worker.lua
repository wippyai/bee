-- MIT. Executor-only worker operations write through the Threads journal
-- contract; this binding owns no session records or execution queue.
local journal = require("journal")
local M = {}
type Reply =
    {ok: true, value: unknown}
    | {ok: false, error: {code: string, message: string, retry: string}}
type Object = {[string]: unknown}

local function object(value: unknown): Object?
    if type(value) ~= "table" then return nil end
    return value :: Object
end

local function fault_code(message: string): string
    local code = message:match("^([A-Z_]+):")
    if code then return code end
    return "UNAVAILABLE"
end

local function invoke(method: string, request: unknown): Reply
    local value, err = journal.invoke(method, request)
    if err then return {ok = false, error = {code = fault_code(err), message = err, retry = "reconcile"}} end
    return {ok = true, value = value}
end

function M.pull_turn(request: unknown): Reply return invoke("pull_turn", request) end
function M.accept_turn(request: unknown): Reply return invoke("accept_turn", request) end
function M.renew(request: unknown): Reply return invoke("renew_owner", request) end
function M.append_event(request: unknown): Reply return invoke("append_event", request) end
function M.checkpoint(request: unknown): Reply return invoke("checkpoint", request) end
function M.effect_intent(request: unknown): Reply return invoke("record_effect_intent", request) end
function M.effect_receipt(request: unknown): Reply return invoke("record_effect_receipt", request) end
function M.effect_status(request: unknown): Reply return invoke("snapshot", request) end
function M.link_execution(request: unknown): Reply return invoke("link_execution", request) end
function M.link_child(request: unknown): Reply return invoke("link_child", request) end
function M.settle(request: unknown): Reply return invoke("settle_turn", request) end

function M.heartbeat(request: unknown): Reply
    local object_request = object(request)
    if not object_request then return {ok = false, error = {code = "INVALID", message = "heartbeat must be an object", retry = "never"}} end
    return invoke("append_event", {claim = object_request.claim,
        event = {kind = "heartbeat", progress = object_request.progress, activity = object_request.activity}})
end

function M.fail(request: unknown): Reply
    local object_request = object(request)
    if not object_request then return {ok = false, error = {code = "INVALID", message = "failure must be an object", retry = "never"}} end
    return invoke("settle_turn", {claim = object_request.claim,
        result = {outcome = "failed", error = object_request.error, artifacts = object_request.artifacts or {}}})
end

return M
