-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local canonical = require("canonical")
local hooks = require("hooks")
local exchange = require("exchange")
local M = {}
type Object = {[string]: unknown}
function M.request(ctx: exchange.Context, event_id: string, payload: Object, evidence: Object): (boolean, string?)
    local selected = ctx.state.exchange
    if not selected or selected.adapter.response.correlation_field ~= nil then return false, "attempt has no accepted hook response channel" end
    local normalized, normalize_error = hooks.normalize("PermissionRequest", payload)
    if not normalized then return false, normalize_error end
    if evidence.event_id ~= event_id or evidence.event ~= "PermissionRequest" or evidence.digest ~= normalized.digest
        or (evidence.status ~= "queued" and evidence.status ~= "committed") then return false, "permission differs from the authenticated hook" end
    local decoded, decode_error = hooks.payload(payload)
    if not decoded then return false, decode_error end
    local content, content_error = canonical.encode({event_id = event_id, tool_name = decoded.tool_name, tool_input = decoded.tool_input}, 8192)
    if not content then return false, content_error end
    local records: {Object} = {{body = {type = "extension", event_key = "permission-hook:" .. event_id,
        data = {type = "extension", event_name = selected.adapter.event_name, event_revision = selected.adapter.event_revision, payload_json = content}}}}
    local detected, detect_error = exchange.detect(ctx, records)
    if detect_error then return false, detect_error end
    if detected > 0 then return ctx.commit(records) end
    return true, nil
end
function M.response(ctx: exchange.Context, event_id: string): (string?, string?)
    for _, item in ipairs(ctx.state.permissions) do
        if item.correlation_id == event_id then
            if item.phase == "closed" then return nil, "permission exchange closed" end
            if item.phase ~= "written" and item.phase ~= "acknowledged" then return nil, nil end
            local refusal = ctx.revalidate()
            if refusal then return nil, refusal end
            if item.lease_ref then
                local raw, err = ctx.call(ctx.approvals .. ":runtime_lease", {operation = "use", lease_ref = item.lease_ref,
                    workspace_id = ctx.state.request.workspace_id, tool = item.tool_name, input_digest = item.input_digest, effect_key = item.effect_key})
                local reply = bounds.object(raw)
                if err or not reply or reply.ok ~= true then return nil, "permission lease no longer authorizes this response" end
            end
            return item.response, nil
        end
    end
    return nil, "hook has no permission intent"
end
return M
