-- MIT. The carrier's gateway bridge: admits, readies and revokes the
-- attempt's gateway binding, drains the hooks the gateway queued under the
-- carrier's epoch, and answers the permission and extension hooks that
-- reach the carrier over HTTP.
local json = require("json")
local bounds = require("bounds")
local gateway_protocol = require("gateway_protocol")
local hook_records = require("hook_records")
local hook_exchange = require("hook_exchange")
local permission_exchange = require("permission_exchange")
local gateway_hooks_catalog = require("gateway_hooks_catalog")
local part_output = require("part_output")
local part_planning = require("part_planning")
type Object = part_output.Object
type IO = part_output.IO
type Plan = part_output.Plan
type Session = part_output.Session
local must = part_output.must
local step = part_output.step
local permission_context = part_output.permission_context
local reply_of = part_planning.reply_of
local M = {}
M.GATEWAY = "bee.gateway.binding"
-- The gateway binding of an attempt under a carrier epoch: admitted after
-- the durable action and attempt preparation, superseding whatever an
-- earlier or retried carrier admitted, and identified in the checkpoint.
function M.admit(io: IO, plan: Plan, epoch: integer): (string?, string?)
    local gateway = plan.gateway
    if not gateway then return nil, nil end
    local request = plan.request
    -- The admitted attempt's workspace is host-selected and travels as the
    -- binding's workspace: every call the bound subject makes carries it.
    local surface_value = plan.policy.gateway_surface
    if request.preferences then
        local composed: Object = {}
        for key, value in pairs(surface_value or {tools = {}, traits = {}, base_tools = gateway.tools, active_traits = {}, fixed_context = {}, dynamic_keys = {}}) do composed[key] = value end
        composed.profile = request.preferences.bee
        composed.authority_grant_id = request.preferences.authority_grant_id
        local grants: {Object} = {}
        for _, file in ipairs(request.preferences.bee and request.preferences.bee.files or {}) do
            local found = false
            for _, resource in ipairs(request.profile_grants or {}) do
                if resource.workspace_id == file.workspace_id and resource.name == file.resource and resource.subpath == file.subpath and resource.access == file.access then
                    grants[#grants + 1] = {workspace_id = file.workspace_id, name = file.resource, subpath = file.subpath,
                        access = file.access, grant_ref = resource.grant_ref, subject = request.owner_id}; found = true
                end
            end
            if not found then return nil, "gateway profile file has no admitted resource grant" end
        end
        composed.resource_grants = grants
        surface_value = composed
    end
    local admitted, admit_error = must(io, M.GATEWAY .. ":admit", {subject = request.session_ref and request.session_ref:match("^bs:") and request.session_ref or request.owner_id, action_id = request.action_id, attempt_id = request.attempt_id, thread_id = request.thread_id,
        owner_incarnation = request.owner_incarnation, carrier_epoch = epoch, tools = gateway.tools, hooks = gateway.hooks, ttl_ms = plan.policy.gateway_ttl_ms, surface = surface_value,
        policy_ref = plan.policy.ref, workspace_id = request.workspace_id, origin_view = request.origin_view})
    if admit_error then return nil, "gateway admit: " .. admit_error end
    local binding, binding_error = gateway_protocol.admitted_binding(admitted)
    if not binding then return nil, "gateway admit returned an invalid binding: " .. tostring(binding_error) end
    local binding_id = binding.binding_id
    step(io, "gateway_admitted")
    return binding_id, nil
end
-- Readiness under the current listener generation with a valid binding,
-- taken immediately before placement starts the child.
function M.ready(io: IO, binding_id: string): string?
    local ready, ready_error = must(io, M.GATEWAY .. ":ready", {binding_id = binding_id})
    if ready_error then return "gateway readiness: " .. ready_error end
    local report, report_error = gateway_protocol.readiness(ready, binding_id)
    if not report then return "gateway readiness returned malformed data: " .. tostring(report_error) end
    if not report.listening then return "gateway readiness: the listener is not ready" end
    if report.binding_valid ~= true then return "gateway readiness: " .. tostring(report.binding_reason) end
    step(io, "gateway_ready")
    return nil
end
function M.revoke(io: IO, binding_id: string?)
    if not binding_id then return end
    io.call(M.GATEWAY .. ":revoke", {binding_id = binding_id})
end
-- drain_hooks: claim what the gateway queued for this binding under this
-- carrier's epoch, commit it through the carrier's own commit path, then
-- acknowledge; a crash between the commit and the acknowledgment is
-- recovered by the next claim, whose commit replays. Nothing here settles
-- anything or extends an attempt.
function M.drain_hooks(io: IO, session: Session): (integer, string?)
    local binding_id = session.checkpoint.gateway_binding
    local gateway = session.plan.gateway
    if not binding_id then return 0, nil end
    if not gateway then return 0, nil end
    if #gateway.hooks == 0 or session.settled then return 0, nil end
    local drained = 0
    for _ = 1, 8 do
        local raw, call_error = io.call(M.GATEWAY .. ":hook_claim", {binding_id = binding_id, carrier_epoch = session.epoch, limit = 16})
        local reply, reply_error = reply_of(raw, call_error)
        if not reply then return drained, "hook claim: " .. tostring(reply_error) end
        if not reply.ok then
            local fault = reply.error or {code = "UNAVAILABLE", message = "hook claim failed"}
            -- An invalid binding may have rejected only unclaimed rows. A
            -- successful empty claim means no retained claim is recoverable
            -- by this carrier; a conflict leaves takeover to its successor.
            if fault.code == "DENIED" or fault.code == "CONFLICT" then return drained, nil end
            return drained, "hook claim: " .. fault.code .. ": " .. fault.message
        end
        local claim, claim_error = gateway_protocol.hook_claim(reply.value, binding_id, session.epoch)
        if not claim then return drained, "hook claim returned malformed data: " .. tostring(claim_error) end
        local turn_id = session.turn_open and session.turn_id or nil
        local batch, batch_error = hook_records.batch(binding_id, turn_id, claim.hooks)
        if not batch then return drained, "hook batch: " .. tostring(batch_error) end
        if #batch.event_ids == 0 then return drained, nil end
        step(io, "hooks_claimed")
        local records = batch.records
        local event_ids = batch.event_ids
        local committed, commit_error = part_output.commit(io, session, records)
        if not committed then return drained, commit_error end
        step(io, "hooks_committed")
        local _, ack_error = must(io, M.GATEWAY .. ":hook_ack", {binding_id = binding_id, carrier_epoch = session.epoch, event_ids = event_ids})
        if ack_error then return drained, "hook ack: " .. ack_error end
        step(io, "hooks_acknowledged")
        drained = drained + #event_ids
    end
    return drained, nil
end
function M.permission_hook(io: IO, session: Session, raw: unknown): (Object?, string?)
    local input = bounds.object(raw)
    local event_id = input and bounds.id(input.event_id)
    local payload = input and bounds.object(input.payload)
    local request = session.plan.request
    if not input or not event_id or not payload or input.binding_id ~= session.checkpoint.gateway_binding
        or input.attempt_id ~= request.attempt_id or input.subject ~= (request.session_ref and request.session_ref:match("^bs:") and request.session_ref or request.owner_id)
        or input.epoch ~= session.epoch then return nil, "hook differs from this carrier attachment" end
    local selected = session.plan.exchange
    if not selected then return {}, nil end
    if selected.transport ~= "hook_http" then return nil, "carrier does not answer HTTP permission hooks" end
    local checked, check_error = must(io, M.GATEWAY .. ":check", {binding_id = input.binding_id})
    local binding = bounds.object(checked)
    if not binding or binding.valid ~= true or binding.carrier_epoch ~= session.epoch then return nil, check_error or "hook binding changed" end
    local queue, queue_error = must(io, M.GATEWAY .. ":hook_queue", {binding_id = input.binding_id, event_id = event_id})
    local queued = bounds.object(queue)
    local rows = queued and bounds.array(queued.hooks, 1)
    if not rows then return nil, queue_error or "hook evidence unavailable" end
    local evidence: Object? = nil
    for _, row in ipairs(rows) do
        local item = bounds.object(row)
        if item and item.event_id == event_id then evidence = item end
    end
    if not evidence then return nil, "permission hook is not admitted" end
    local ctx = permission_context(io, session)
    local prepared, prepare_error = hook_exchange.request(ctx, event_id, payload, evidence)
    if not prepared then return nil, prepare_error end
    local advanced, advance_error = permission_exchange.advance(ctx, true)
    if not advanced then return nil, advance_error end
    local line, response_error = hook_exchange.response(ctx, event_id)
    if response_error then return nil, response_error end
    return {pending = line == nil, permission_response = line}, nil
end
-- permission_hook_response: the response a held permission hook is waiting
-- for, once the exchange has written it; nil while the decision is pending.
function M.permission_hook_response(io: IO, session: Session, event_id: string): (string?, string?)
    return hook_exchange.response(permission_context(io, session), event_id)
end
function M.extension_hook(io: IO, session: Session, raw: unknown): (Object?, string?)
    local input = bounds.object(raw)
    local payload = input and bounds.object(input.payload)
    local event_id = input and bounds.id(input.event_id)
    local request = session.plan.request
    if not input or not payload or not event_id or input.binding_id ~= session.checkpoint.gateway_binding
        or input.attempt_id ~= request.attempt_id or input.epoch ~= session.epoch
        or input.subject ~= (request.session_ref and request.session_ref:match("^bs:") and request.session_ref or request.owner_id) then return nil, "hook differs from this carrier attachment" end
    local checked, check_error = must(io, M.GATEWAY .. ":check", {binding_id = input.binding_id})
    local binding = bounds.object(checked)
    if not binding or binding.valid ~= true or binding.carrier_epoch ~= session.epoch then return nil, check_error or "hook binding changed" end
    local queue, queue_error = must(io, M.GATEWAY .. ":hook_queue", {binding_id = input.binding_id, event_id = event_id})
    local queued = bounds.object(queue)
    local rows = queued and bounds.array(queued.hooks, 1)
    if not rows then return nil, queue_error or "hook evidence unavailable" end
    local event = tostring(payload.hook_event_name or payload.event)
    local normalized, normalize_error = gateway_hooks_catalog.normalize(event, payload)
    if not normalized then return nil, normalize_error end
    local admitted = false
    for _, raw_hook in ipairs(rows) do
        local item = bounds.object(raw_hook)
        if item and item.event_id == event_id and item.event == event and item.digest == normalized.digest
            and (item.status == "queued" or item.status == "committed") then admitted = true end
    end
    if not admitted then return nil, "hook occurrence is not admitted" end
    local points = {SessionStart = "session.start", UserPromptSubmit = "prompt.submit", PreToolUse = "tool.before", PostToolUse = "tool.after"}
    local point = points[event]
    if not point then return nil, "unknown extension hook point" end
    local tool_input: unknown = payload.tool_input
    if type(tool_input) == "string" then tool_input = json.decode(tool_input) end
    local response, err = must(io, "bee.threads.hooks:dispatch", {session_ref = request.session_ref and request.session_ref:match("^bs:") and request.session_ref or nil,
        action_id = request.action_id, thread_id = request.thread_id, workspace_id = request.workspace_id,
        point = point, occurrence_id = event_id, turn_ref = session.turn_id, tool_name = payload.tool_name, tool_call_id = payload.tool_use_id,
        input = tool_input, output = payload.tool_response, text = payload.prompt})
    if not response then return nil, err end
    return {extension_response = response, hook_driver = session.plan.binding.driver_id}, nil
end
return M
