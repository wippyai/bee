-- MIT. Cancellation stops the admitted placement attempt and reports only
-- evidence placement can prove.
local bounds = require("bounds")
local funcs = require("funcs")
local security = require("security")
local M = {}

type Object = {[string]: unknown}
type Evidence = {summary: string, artifacts: {string}}
type Result = {state: "stopped" | "pending" | "uncertain", evidence: Evidence}

local function object(value: unknown): Object?
    return bounds.object(value)
end

local function failure(value: unknown): (string, string)
    local reply = object(value)
    local error_value = reply and object(reply.error)
    return tostring(error_value and error_value.code or "UNAVAILABLE"),
        tostring(error_value and (error_value.message or error_value.code) or "placement refused cancellation")
end

local function call(target: unknown, request: Object, actor: security.Actor): (Object?, string?, string?)
    if type(target) ~= "string" or target == "" then return nil, "INVALID", "placement binding omits the required operation" end
    local raw, call_error = funcs.new():with_actor(actor):call(target, request)
    if call_error then return nil, "UNAVAILABLE", tostring(call_error) end
    local reply = object(raw)
    if not reply then return nil, "INTERNAL", target .. " returned a malformed reply" end
    if reply.ok ~= true then
        local code, message = failure(raw)
        return nil, code, message
    end
    local value = object(reply.value)
    if not value then return nil, "INTERNAL", target .. " returned no value" end
    return value, nil, nil
end

local function attempt_value(value: Object): Object?
    return object(value.attempt) or value
end

local function evidence(summary: string, attempt_id: string, state: string?, exit_source: string?): Evidence
    local artifacts = {"placement attempt " .. attempt_id}
    if state then artifacts[#artifacts + 1] = "execution state " .. state end
    if exit_source then artifacts[#artifacts + 1] = "exit observed by " .. exit_source end
    return {summary = summary, artifacts = artifacts}
end

function M.stop(methods: unknown, attempt_id: string, stored_route: unknown, allow_exited: boolean?): Result
    local placement = object(methods)
    if not placement then return {state = "uncertain", evidence = evidence("session route has no placement operations", attempt_id, nil, nil)} end
    local route = object(stored_route)
    local owner = route and bounds.id(route.owner_id)
    local workspace = route and bounds.id(route.workspace_id)
    if not owner or not workspace or #workspace ~= 32 or workspace:find("[^0-9a-f]") then
        return {state = "uncertain", evidence = evidence("session route has no workspace-bound placement owner", attempt_id, nil, nil)}
    end
    local actor, actor_error = security.new_actor(owner, {workspace_id = workspace})
    if not actor then return {state = "uncertain", evidence = evidence("placement owner cannot be restored: " .. tostring(actor_error), attempt_id, nil, nil)} end
    local before, before_code, before_error = call(placement.reconcile, {attempt_id = attempt_id}, actor)
    if not before then
        if before_code == "NOT_FOUND" then
            return {state = "pending", evidence = evidence("placement attempt has not been persisted yet", attempt_id, nil, nil)}
        end
        return {state = "uncertain", evidence = evidence("placement state cannot be read before stop: " .. tostring(before_error), attempt_id, nil, nil)}
    end
    local before_attempt = attempt_value(before)
    local before_state = before_attempt and bounds.text(before_attempt.execution_state, 32) or nil
    if before_state == "exited" then
        local source = before_attempt and bounds.text(before_attempt.exit_source, 128)
        if allow_exited and source then
            return {state = "stopped", evidence = evidence("placement proved the process exited", attempt_id, before_state, source)}
        end
        return {state = "uncertain", evidence = evidence("placement had already exited before cancellation", attempt_id, before_state,
            before_attempt and bounds.text(before_attempt.exit_source, 128) or nil)}
    end
    if before_state ~= "starting" and before_state ~= "running" and before_state ~= "stopping" then
        return {state = "uncertain", evidence = evidence("placement did not report a live process before stop", attempt_id, before_state, nil)}
    end
    local stopped, stop_code, stop_error = call(placement.stop, {attempt_id = attempt_id, mode = "cooperative"}, actor)
    if not stopped then
        return {state = "uncertain", evidence = evidence("placement stop failed: " .. tostring(stop_error or stop_code), attempt_id, before_state, nil)}
    end
    local current, reconcile_code, reconcile_error = call(placement.reconcile, {attempt_id = attempt_id}, actor)
    if not current then
        if reconcile_code == "NOT_FOUND" or stop_code == "NOT_FOUND" then
            return {state = "pending", evidence = evidence("placement attempt has not been persisted yet", attempt_id, nil, nil)}
        end
        return {state = "uncertain", evidence = evidence("placement outcome cannot be reconciled: " .. tostring(reconcile_error), attempt_id, nil, nil)}
    end
    local attempt = attempt_value(current)
    local state = attempt and bounds.text(attempt.execution_state, 32) or nil
    local exit_source = attempt and bounds.text(attempt.exit_source, 128) or nil
    if state == "exited" and exit_source then
        return {state = "stopped", evidence = evidence("placement proved the process exited after cancellation", attempt_id, state, exit_source)}
    end
    if state == "starting" or state == "running" or state == "stopping" then
        return {state = "pending", evidence = evidence("placement has not proved process exit", attempt_id, state, exit_source)}
    end
    return {state = "uncertain", evidence = evidence("placement returned no proof that the process exited", attempt_id, state, exit_source)}
end

return M
