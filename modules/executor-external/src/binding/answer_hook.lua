-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local funcs = require("funcs")
local security = require("security")
local time = require("time")
local hash = require("hash")
local canonical = require("canonical")
local exchange = require("exchange")
local checkpoint = require("checkpoint")
local admission = require("admission")
local catalog = require("catalog")
local policy = require("policy")
local machine = require("machine")
local descriptor = require("descriptor")
local classify = require("classify")
local profiles = require("profiles")
type Object = {[string]: unknown}
type Reply = {ok: boolean, value?: unknown, error?: {code: string, message: string}}
local function fail(message: string): Reply return {ok = false, error = {code = "PERMISSION_REFUSED", message = message}} end
local function call(target: string, fields: unknown): (unknown, string?)
    local raw, err = funcs.call(target, fields)
    if err then return nil, tostring(err) end
    return raw, nil
end
local function value(target: string, fields: unknown): (Object?, string?)
    local raw, err = call(target, fields)
    if err then return nil, err end
    local reply = bounds.object(raw)
    if not reply or reply.ok ~= true then
        local fault = reply and bounds.object(reply.error)
        return nil, fault and bounds.text(fault.message, 4096) or "owner refused " .. target
    end
    local result = bounds.object(reply.value)
    if not result then return nil, "owner returned malformed " .. target end
    return result, nil
end
local function digest(value: unknown): (string?, string?)
    local encoded, err = canonical.encode(value)
    if not encoded then return nil, err end
    return hash.sha256(encoded)
end
local function handle(raw: unknown): Reply
    local request = bounds.object(raw)
    if not request or bounds.fields(request, {"session", "definition", "plan_digest", "attempt_id", "thread_id", "action_id", "binding_id",
        "turn", "claim", "event_id", "payload", "saved_profile_id", "saved_profile_revision", "transport"}) then return fail("invalid hook boundary") end
    local caller = security.actor()
    local caller_id = caller and bounds.id(caller:id())
    local meta = caller and bounds.object(caller:meta())
    local workspace = meta and bounds.id(meta.workspace_id)
    local session, definition = bounds.id(request.session), bounds.id(request.definition)
    local attempt_id, action_id = bounds.id(request.attempt_id), bounds.id(request.action_id)
    local thread_id, binding_id = bounds.id(request.thread_id), bounds.id(request.binding_id)
    local turn, claim, event_id = bounds.id(request.turn), bounds.id(request.claim), bounds.id(request.event_id)
    local plan_digest = bounds.text(request.plan_digest, 64)
    local payload = bounds.object(request.payload)
    local transport = bounds.member(request.transport, {"hook_http", "hook_mcp"})
    if not session or not caller_id or caller_id ~= session or not workspace or not definition or not attempt_id or not action_id or not thread_id
        or not binding_id or not turn or not claim or not event_id or not plan_digest or not payload or not transport
        or not security.can("bee.harness.permission.answer", caller_id) then return fail("hook is not an authenticated session boundary") end
    local saved_profile_id: string? = nil
    local saved_profile_revision: integer? = nil
    if request.saved_profile_id ~= nil then
        saved_profile_id = bounds.id(request.saved_profile_id)
        saved_profile_revision = bounds.count(request.saved_profile_revision)
        if not saved_profile_id or not saved_profile_revision or saved_profile_revision < 1 then return fail("saved hook profile is malformed") end
    elseif request.saved_profile_revision ~= nil then return fail("saved profile revision has no profile") end
    local pinned, resolution_error = admission.resolve(definition, "window", workspace, saved_profile_id, saved_profile_revision, nil, nil, nil, false)
    if not pinned then return fail(tostring(resolution_error and resolution_error.error and resolution_error.error.message or "hook admission unavailable")) end
    if pinned.plan_digest ~= plan_digest then return fail("window admission changed") end
    local snapshot, snapshot_error = catalog.pin()
    if not snapshot then return fail(tostring(snapshot_error)) end
    local candidates, candidate_error = catalog.read(snapshot, nil)
    if not candidates then return fail(tostring(candidate_error)) end
    local bindings, binding_error = catalog.usable(candidates)
    if not bindings then return fail(tostring(binding_error)) end
    local selected: classify.Binding? = nil
    for _, binding in ipairs(bindings) do if binding.binding_id == pinned.binding_ref then selected = binding end end
    if not selected then return fail("window driver is unavailable") end
    local profile: classify.Profile? = nil
    for _, candidate in ipairs(selected.profiles) do if candidate.id == pinned.profile_id then profile = candidate end end
    if not profile then return fail("window profile is unavailable") end
    local policy_entry = catalog.entry(snapshot, pinned.policy_ref)
    if not policy_entry then return fail("host permission policy is unavailable") end
    local selected_policy, policy_error = policy.decode(pinned.policy_ref, policy_entry)
    if not selected_policy then return fail(tostring(policy_error)) end
    if pinned.permission_answers == "provider" then return {ok = true, value = {}} end
    local declaration = selected_policy.permission_exchange
    if not declaration then return {ok = true, value = {}} end
    local capabilities, capability_error = descriptor.find_provider(snapshot, selected.driver_id)
    if not capabilities then return fail(tostring(capability_error)) end
    local answer = descriptor.permission_answer(capabilities, "window")
    if answer.transport ~= transport or answer.adapter_ref ~= declaration.adapter_ref then return fail("hook differs from the declared answer transport") end
    local accepted, acceptance_error = machine.verify_acceptance(snapshot, declaration, selected, profile, selected_policy.fixture, "hook exchange")
    if not accepted then return fail(tostring(acceptance_error)) end
    local executable = pinned.executables[capabilities.executable]
    if not executable then return fail("accepted hook executable is unavailable") end
    local function revalidate(): string?
        local current, current_error = admission.resolve(definition, "window", workspace, saved_profile_id, saved_profile_revision, nil, nil, nil, false)
        if not current then return "hook admission is unavailable" end
        if current.plan_digest ~= plan_digest then return "hook admission changed" end
        local bound, bound_error = value("bee.gateway.binding:check", {binding_id = binding_id})
        if not bound then return bound_error end
        if bound.subject ~= session or bound.attempt_id ~= attempt_id or bound.action_id ~= action_id or bound.thread_id ~= thread_id then return "hook binding changed" end
        local measured, measurement_error = value("bee.placement.native.binding:measure_executable", {path = executable})
        if not measured then return measurement_error end
        if measured.revision ~= accepted.executable_revision or measured.kind ~= accepted.executable_kind or measured.digest ~= accepted.executable_digest then return "accepted executable changed" end
        if not selected_policy.fixture and measured.kind ~= "elf" then return "production permission proof requires a native executable" end
        return nil
    end
    local refusal = revalidate()
    if refusal then return fail(refusal) end
    local pulled, pull_error = value("bee.threads.service:turn_pull", {turn = turn, claim = claim})
    if not pulled then return fail(tostring(pull_error)) end
    if pulled.phase ~= "accepted" or pulled.session ~= session then return fail("hook turn is no longer accepted by this session") end
    local saved = bounds.object(pulled.checkpoint)
    if not saved or saved.attempt_id ~= attempt_id then return fail("hook turn belongs to a different native attempt") end
    local point = checkpoint.new({binding_ref = selected.binding_id, binding_digest = selected.binding_digest.entry,
        profile_id = profile.id, profile_digest = selected.profile_digest.entry, plan_digest = plan_digest}, 1)
    if saved.permission_checkpoint ~= nil then
        local recovered, recovery_error = checkpoint.decode(saved.permission_checkpoint)
        if not recovered then return fail(tostring(recovery_error)) end
        if recovered.plan_digest ~= plan_digest then return fail("permission checkpoint admission changed") end
        point = recovered
    end
    local state: exchange.State = {request = {owner_id = session, session_ref = session, workspace_id = workspace, thread_id = thread_id,
            preferences = pinned.effective_profile and profiles.preferences(pinned.effective_profile), action_id = action_id, attempt_id = attempt_id}, plan_digest = plan_digest, epoch = 1, permissions = point.permissions, proposal_kind = "operation",
        exchange = {adapter = accepted.adapter, approver_policy = declaration.approver_policy, poll_ms = declaration.poll_ms,
            ttl_ms = declaration.ttl_ms, answer_mode = pinned.permission_answers}}
    local response: string? = nil
    local function commit(records: {Object}): (boolean, string?)
        for _, record in ipairs(records) do
            local body = bounds.object(record.body)
            if not body then return false, "permission record has no body" end
            local key, key_error = digest({turn = turn, event = body.event_key})
            if not key then return false, key_error end
            local next_checkpoint: Object = {}
            for name, field in pairs(saved) do next_checkpoint[name] = field end
            next_checkpoint.permission_checkpoint = point
            local _, err = value("bee.threads.service:turn_observation", {turn = turn, claim = claim, operation_key = "hook-perm:" .. key,
                observation = body, checkpoint = next_checkpoint})
            if err then return false, err end
        end
        return true, nil
    end
    local ctx: exchange.Context = {state = state, approvals = "bee.approvals.binding", max_consume_attempts = exchange.MAX_CONSUME_ATTEMPTS,
        now_ms = function(): integer return math.floor(time.now():unix_nano() / 1000000) end,
        recovered = true, digest_of = digest, step = function(_: string) end, call = call, commit = commit, revalidate = revalidate,
        waiting = function(): boolean
            local checked = value("bee.gateway.binding:check", {binding_id = binding_id})
            return checked ~= nil and checked.attempt_id == attempt_id
        end,
        settled = function(): boolean return false end,
        write = function(write_id: string, line: string): (boolean, string?)
            response = line
            return commit({{body = {type = "extension", event_key = "write:" .. write_id .. ":prepared",
                data = {type = "extension", event_name = "bee.carrier.write", event_revision = "1",
                    payload_json = canonical.encode({write_id = write_id, phase = "prepared", delivery = "hook", acknowledgment = "unproven"})}}}})
        end}
    local fields: Object = {event_id = event_id, tool_name = payload.tool_name, tool_input = payload.tool_input}
    local records: {Object} = {{body = {type = "extension", event_key = "permission-hook:" .. event_id,
        data = {type = "extension", event_name = accepted.adapter.event_name, event_revision = accepted.adapter.event_revision,
            payload_json = canonical.encode(fields)}}}}
    local detected, detect_error = exchange.detect(ctx, records)
    if detect_error then return fail(detect_error) end
    if detected == 0 then
        for _, item in ipairs(point.permissions) do
            if item.correlation_id == event_id and item.phase == "written" and item.response then
                local refusal = revalidate()
                if refusal then return fail(refusal) end
                if item.lease_ref then
                    local _, err = value("bee.approvals.binding:runtime_lease", {operation = "use", lease_ref = item.lease_ref,
                        workspace_id = workspace, tool = item.tool_name, input_digest = item.input_digest, effect_key = item.effect_key})
                    if err then return fail(err) end
                end
                return {ok = true, value = {permission_response = item.response}}
            end
        end
        -- A pending replay continues from the durable intent.
        local pending = false
        for _, item in ipairs(point.permissions) do if item.correlation_id == event_id and item.phase ~= "closed" then pending = true end end
        if not pending then return fail("hook has no current permission request") end
        records = {}
    elseif detected ~= 1 then return fail("hook did not carry one permission request") end
    local committed, commit_error = commit(records)
    if not committed then return fail(tostring(commit_error)) end
    while not response do
        local advanced, advance_error = exchange.advance(ctx, true)
        if not advanced then return fail(tostring(advance_error)) end
        if not ctx.waiting() then return fail("hook binding no longer waits") end
        if not response then time.sleep(tostring(declaration.poll_ms) .. "ms") end
    end
    return {ok = true, value = {permission_response = response}}
end
return {handle = handle}
