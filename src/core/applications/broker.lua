-- Instance lifecycle and terminal capability owner. No bundled-app identities.
local process = require("process")
local security = require("security")
local channel = require("channel")
local tty = require("tty")
local uuid = require("uuid")
local time = require("time")
local registry = require("registry")
local ctx = require("ctx")
local contract = require("contract")
local bounds = require("bounds")
local catalog = require("catalog")
local lifecycle = require("lifecycle")
local attachment = require("attachment")
local execution = require("execution")
local principal = require("principal")
local appearance = require("appearance")
local interaction = require("interaction")
local interactions = require("interactions")
local shutdown = require("shutdown")
local funcs = require("funcs")
local open_protocol = require("open_protocol")
local binding_protocol = require("binding_protocol")
local thread_binding_reducer = require("thread_binding_reducer")
local thread_binding = require("thread_binding")
local thread_protocol = require("thread_protocol")
type Admission = {revision: string, evidence: string, bindings: {contract.Binding}, items: {contract.Descriptor},
    descriptors: {[string]: contract.Descriptor}, scopes: {[string]: security.Scope}}
type Waiter = {request_id: string, recipient: string, control: boolean}
type AppearanceOp = "state" | "set" | "inherit"
type PreferenceWaiter = {request_id: string, recipient: string, action: AppearanceOp, renderer: string, mount: string}
type Checkpoint = {request_id: string, pid: string, deadline: number, resume_state: string}
type Replacement = {revision: string, exited: boolean}
type Instance = {view_id: string, instance_id: string, thread_id: string?, execution_pid: string, view: tty.Viewport,
    descriptor: contract.Descriptor, binding: contract.Binding, attachment: attachment.Record?, observers: {[string]: string}, launch_token: string,
    producer_generation: integer, arguments: {string}, replacement: Replacement?, client_appearance_revision: number?, negotiate_close: boolean?, close_request_id: string?, announced_title: string?, title_dirty: boolean?, state: lifecycle.State, open_request: string, opened: boolean, resume_state: string, waiters: {Waiter}, attempts: integer}
type BindingOpen = {request: contract.Request, provenance: open_protocol.Provenance,
    descriptor: contract.Descriptor, binding: contract.Binding, scope: security.Scope,
    view_id: string, instance_id: string, existing: boolean}
type BindingCoordinator = {instance_id: string, state: thread_binding_reducer.State, open: BindingOpen?, retry_at: number,
    failure_code: string?, failure_message: string?, stop_event: lifecycle.Event?, settle_after_revoke: boolean?,
    effect: thread_binding_reducer.Effect?}
local function now(): number return time.now():unix_nano() / 1000000000 end
local function application_actor(workspace_id: string, instance_id: string, definition_id: string,
    definition_revision: string, execution_generation: integer): security.Actor
    local value = assert(principal.value(workspace_id, instance_id, definition_id,
        definition_revision, execution_generation))
    local actor, err = security.new_actor(value.id, value.metadata)
    if not actor then error("Create application principal: " .. tostring(err)) end
    return actor
end
local function main(owner: string, initial_preferences: unknown)
    local bootstrap: unknown = ctx.get("bee.workspace_owner")
    if bootstrap ~= owner or owner == "" then error("Untrusted broker bootstrap") end
    local workspace_id = contract.workspace_id(ctx.get("bee.workspace_id"))
    if not workspace_id then
        error("Invalid workspace identity bootstrap")
    end
    local requests = assert(process.listen("bee.app.request", {message = true}))
    local shutdown_requests = assert(process.listen("bee.application.shutdown", {message = true}))
    local close_replies = assert(process.listen("bee.application.close.reply", {message = true}))
    local queries = assert(process.listen("bee.application.query", {message = true}))
    local answers = assert(process.listen("bee.interaction.response", {message = true}))
    local titles = assert(process.listen("bee.application.title", {message = true}))
    local app_ready = assert(process.listen("bee.application.ready", {message = true}))
    local appearance_requests = assert(process.listen("bee.appearance.request", {message = true}))
    local appearance_states = assert(process.listen("bee.appearance.state", {message = true}))
    local controls = assert(process.listen("bee.application.control", {message = true}))
    local checkpoints = assert(process.listen("bee.application.checkpoint", {message = true}))
    local persisted = assert(process.listen("bee.application.persisted", {message = true}))
    local binding_results = assert(process.listen("bee.application.binding.result", {message = true}))
    local binding_recovery = assert(process.listen("bee.application.binding.recovery", {message = true}))
    local thread_requests = assert(process.listen("bee.application.thread.request", {message = true}))
    local checkpoint_waiters: {[string]: Checkpoint} = {}
    local events = assert(process.events())
    assert(process.monitor(owner))
    local ticker = assert(time.ticker("100ms"))
    local ticks = ticker:channel()
    local admission: {current: Admission?, error: string} = {error = ""}
    local instances: {[string]: Instance} = {}
    local coordinators: {[string]: BindingCoordinator} = {}
    local recovery_received = false
    local binding_requests: {[string]: string} = {}
    local membership_policy = assert(security.policy("bee:application_thread_membership_policy"))
    local membership_scope = security.new_scope({membership_policy})
    local facade_policy = assert(security.policy("bee:application_thread_facade_policy"))
    local facade_scope = security.new_scope({facade_policy})
    local function thread_call(actor_id: string, target: string, request: unknown)
        local actor, actor_error = security.new_actor(actor_id)
        if not actor then return nil, tostring(actor_error or "create thread caller") end
        local acted, actor_failure = funcs.new():with_actor(actor)
        if not acted then return nil, tostring(actor_failure or "set thread caller") end
        local scoped, scope_error = acted:with_scope(membership_scope)
        if not scoped then return nil, tostring(scope_error or "set thread scope") end
        local reply, call_error = scoped:call(target, request)
        if call_error or not reply then return nil, tostring(call_error or "thread call returned no reply") end
        return reply, nil
    end
    -- A broker-launched application runs under its own host-issued principal,
    -- so it is not a member of the thread its open names. The broker holds the
    -- owner authority for owner-launched threads and admits the exact
    -- principal it is about to start, before the app reads or writes the
    -- thread. A caller cannot select the member: the ID is derived from the
    -- workspace and the instance the broker itself chose. A named thread that
    -- does not exist yet admits nothing: the application creates it on first
    -- use and owns it from birth.
    local function active_principal(reply: unknown, actor_id: string): boolean?
        if type(reply) ~= "table" then return nil end
        local visible = reply :: {[string]: unknown}
        if visible.ok ~= true then
            local fault = bounds.object(visible.error)
            local code = fault and bounds.id(fault.code) or nil
            if code == "DENIED" or code == "NOT_FOUND" then return false end
            return nil
        end
        local value = bounds.object(visible.value)
        local membership = value and bounds.object(value.membership)
        if not membership or membership.member_id ~= actor_id then return nil end
        return membership.active == true
    end
    local function admit_principal(thread_id: string, instance_id: string): (boolean, string?, string?)
        local actor_id = thread_binding.actor(workspace_id, instance_id)
        if not actor_id then return false, "permission_denied", "Application identity is invalid" end
        -- Prove the app's own membership through the app's own authority, so
        -- a reopened or already-bound instance is never joined twice.
        local member_reply = thread_call(actor_id, "bee.threads.service:get", {thread_id = thread_id})
        if active_principal(member_reply, actor_id) == true then return true, nil, nil end
        if member_reply == nil then
            return false, "permission_denied", "Application thread membership could not be read"
        end
        local read, read_error = funcs.new():with_scope(membership_scope):call("bee.threads.service:get", {thread_id = thread_id})
        if read_error or type(read) ~= "table" then
            return false, "permission_denied", "Application thread membership could not be read"
        end
        local visible = read :: {[string]: unknown}
        if visible.ok ~= true then
            local fault = bounds.object(visible.error)
            local code = fault and bounds.id(fault.code) or "DENIED"
            if code == "NOT_FOUND" then return true, nil, nil end
            local message = fault and fault.message or "the thread is unavailable"
            return false, "permission_denied", tostring(message)
        end
        local value = bounds.object(visible.value) or {}
        local head = bounds.object(value.summary)
        local revision = head and bounds.integer(head.revision) or nil
        if not revision or revision < 1 then return false, "permission_denied", "the thread head is unavailable" end
        local joined, join_error = funcs.new():with_scope(membership_scope):call("bee.threads.service:join", {thread_id = thread_id,
            idempotency_key = "open:" .. instance_id .. ":join", member_id = actor_id, role = "participant", expected_revision = revision})
        if join_error or type(joined) ~= "table" then
            return false, "permission_denied", "Application thread membership could not be admitted"
        end
        local reply = joined :: {[string]: unknown}
        if reply.ok == true then return true, nil, nil end
        local fault = bounds.object(reply.error)
        local code = fault and bounds.id(fault.code) or nil
        if code == "NOT_FOUND" then
            -- The thread vanished after the read above; the application did
            -- not create it, so starting it now would strand the launch.
            return false, "thread_conflict", "Application thread disappeared while opening"
        end
        if code == "CONFLICT" then
            -- The row may already exist from a reopened or bound instance, or
            -- the head moved under a concurrent join. Re-prove through the
            -- app's own authority instead of assuming either outcome.
            if active_principal(thread_call(actor_id, "bee.threads.service:get", {thread_id = thread_id}), actor_id) == true then
                return true, nil, nil
            end
            return false, "thread_conflict", "Application thread changed while opening"
        end
        return false, "permission_denied", tostring(fault and fault.message or "the thread refused the application principal")
    end
    local function facade_call(actor_id: string, target: string, request: unknown)
        local actor, actor_error = security.new_actor(actor_id)
        if not actor then return nil, tostring(actor_error or "create application thread caller") end
        local acted, actor_failure = funcs.new():with_actor(actor)
        if not acted then return nil, tostring(actor_failure or "set application thread caller") end
        local scoped, scope_error = acted:with_scope(facade_scope)
        if not scoped then return nil, tostring(scope_error or "set application thread scope") end
        return scoped:call(target, request)
    end
    -- The host receives a complete snapshot after every change. A PID is only
    -- an execution-local reader reference; it is not a durable principal.
    local function publish_catalog_readers()
        local readers: {string} = {}
        for _, item in pairs(instances) do
            if item.binding.catalog_read then readers[#readers + 1] = item.execution_pid end
        end
        table.sort(readers)
        assert(process.send(owner, "bee.host.catalog_readers", {version = 1, workspace_id = workspace_id, readers = readers}))
    end
    local dialogs = interactions.new()
    local shutdown_plan: shutdown.State? = nil
    local shutdown_dialog: interaction.Spec? = nil
    local quit_sent = false
    local cleanup_request = ""
    local cleanup_deadline = 0
    local cleanup_complete = false
    local function publish_dialogs()
        local items: {interaction.Wire} = {}
        for _, spec in ipairs(interactions.snapshot(dialogs)) do items[#items + 1] = interaction.wire(spec) end
        process.send(owner, "bee.interaction.state", {version = 1, items = items, shutdown = shutdown_dialog and interaction.wire(shutdown_dialog) or nil})
    end
    local pending: {[string]: boolean} = {}
    local fingerprints: {[string]: string} = {}
    local completed: {[string]: contract.Reply} = {}
    local completed_order: {string} = {}
    local recipient = ""
    local preferences = appearance.decode(initial_preferences) or appearance.defaults()
    local preference_waiters: {[string]: PreferenceWaiter} = {}
    local function current_application(definition_id: string): (contract.Descriptor?, contract.Binding?, security.Scope?)
        local current = admission.current
        if not current then return nil, nil, nil end
        local selected: contract.Binding? = nil
        for _, candidate in ipairs(current.bindings) do
            if candidate.definition_id == definition_id then selected = candidate; break end
        end
        return current.descriptors[definition_id], selected, current.scopes[definition_id]
    end
    -- Admission refresh enters the same termination path as explicit close.
    -- The function is assigned below before the first refresh call.
    local transition: (Instance, lifecycle.Event) -> ()
    local find_instance: (string) -> Instance?
    local find_pid: (string) -> Instance?
    local settle_exited_replacement: (Instance, boolean) -> boolean
    -- Reconcile one protected registry snapshot. Compatible automatic
    -- producers may follow a later revision through the replacement path below.
    local function refresh_admission(initial: boolean?)
        local previous = admission.current
        local ok, loaded = pcall(function(): Admission
            local selected = catalog.read(workspace_id)
            if previous and catalog.same(selected, previous) then return previous end
            local revision = selected.revision
            local next_bindings = selected.bindings
            local next_items = selected.items
            local next_scopes: {[string]: security.Scope} = {}
            local base, base_error = security.policy("bee:base_app_policy")
            if base_error then error(tostring(base_error)) end
            local boundary, boundary_error = security.policy("bee:app_boundary_policy")
            if boundary_error then error(tostring(boundary_error)) end
            local scope_boundary, scope_boundary_error = security.policy("bee:scope_managing_app_boundary")
            if scope_boundary_error then error(tostring(scope_boundary_error)) end
            local private_core, private_error = security.policy("bee:core_spawn_boundary")
            if private_error then error(tostring(private_error)) end
            local storage_boundary, storage_error = security.policy("bee:workspace_storage_boundary")
            if storage_error then error(tostring(storage_error)) end
            for _, binding in ipairs(next_bindings) do
                local selected_boundary: security.Policy = binding.scope_management and scope_boundary or boundary
                local policies: {security.Policy} = {base, selected_boundary, private_core, storage_boundary}
                for _, name in ipairs(binding.policies) do
                    local policy, err = security.policy(name)
                    if err then error(tostring(err)) end
                    policies[#policies + 1] = policy
                end
                next_scopes[binding.definition_id] = security.new_scope(policies)
            end
            if not catalog.same(catalog.read(workspace_id), selected) then error("Application admission changed during refresh") end
            local next_descriptors: {[string]: contract.Descriptor} = {}
            for _, item in ipairs(next_items) do next_descriptors[item.definition_id] = item end
            return {revision = revision, evidence = selected.evidence, bindings = next_bindings,
                descriptors = next_descriptors, scopes = next_scopes, items = next_items}
        end)
        if ok then
            local selected: Admission = loaded :: Admission
            if previous == selected then return end
            admission.current, admission.error = selected, ""
            assert(process.send(owner, "bee.application.catalog", {version = 1, items = selected.items}))
            -- A compatible automatic application follows its applied
            -- definition behind the same viewport. Once an exit has been
            -- observed, its exact requested revision is a fence: a later
            -- catalog refresh fails closed rather than changing that target.
            for _, value in pairs(instances) do
                local item: Instance = value :: Instance
                local replacement = selected.descriptors[item.descriptor.definition_id]
                local replacement_binding: contract.Binding? = nil
                for _, candidate in ipairs(selected.bindings) do
                    if candidate.definition_id == item.descriptor.definition_id then replacement_binding = candidate; break end
                end
                if cleanup_request == "" and not item.replacement and item.state.phase == "ready" and replacement and replacement_binding
                    and catalog.replaces(item.descriptor, replacement) then
                    item.replacement = {revision = replacement.definition_revision, exited = false}
                    transition(item, "force_stop")
                end
            end
        else
            if initial then error(tostring(loaded)) end
            -- An invalid or unreadable replacement must not leave stale grants
            -- available for another launch. Existing instances retain their scope.
            admission.current, admission.error = nil, tostring(loaded):sub(1, 2000)
            if previous then assert(process.send(owner, "bee.application.catalog", {version = 1, items = {}})) end
        end
    end
    local function emit(reply: contract.Reply, remember: boolean?)
        reply.workspace_id = workspace_id
        if remember and reply.request_id ~= "" then
            pending[reply.request_id] = nil
            if not completed[reply.request_id] then completed_order[#completed_order + 1] = reply.request_id end
            completed[reply.request_id] = reply
            if #completed_order > 128 then
                local oldest = table.remove(completed_order, 1)
                completed[oldest] = nil; fingerprints[oldest] = nil
            end
        end
        assert(process.send(owner, "bee.app.reply", reply))
    end
    local function identified(item: Instance, op: contract.ReplyOp, request_id: string, code: string?, message: string?): contract.Reply
        local reply = contract.reply(request_id, op, code, message)
        reply.workspace_id = workspace_id
        reply.id, reply.instance_id, reply.title, reply.mount = item.view_id, item.instance_id, item.announced_title or item.descriptor.title, attachment.reference(item.attachment)
        reply.thread_id = item.thread_id
        reply.icon = item.descriptor.icon
        reply.definition_id, reply.resume_schema = item.descriptor.definition_id, item.descriptor.resume_schema
        reply.restart_policy, reply.resume_state = item.descriptor.restart_policy, item.resume_state
        return reply
    end
    local launch_binding: (BindingCoordinator) -> ()
    local drive_binding: (BindingCoordinator, thread_binding_reducer.Event) -> ()
    local function fail_binding(coordinator: BindingCoordinator, code: string, message: string)
        coordinator.failure_code, coordinator.failure_message = code, message
        drive_binding(coordinator, {kind = "revoke"})
    end
    local function complete_binding(coordinator: BindingCoordinator, terminal: string)
        if terminal == "active" then
            if coordinator.open then launch_binding(coordinator) end
        elseif terminal == "retry" then
            coordinator.retry_at = now() + 0.2
        elseif terminal == "cleanup_pending" then
            coordinator.retry_at = now() + 1
        else
            local binding = coordinator.state.binding
            if terminal == "failed" and binding then
                -- A failed host reply does not prove the durable row vanished.
                -- Re-enter recovery on the next bounded tick rather than
                -- losing the only delegation record.
                coordinator.retry_at = now() + 0.2
                return
            end
            if coordinator.open then
                local open = coordinator.open
                emit(contract.reply(open.request.request_id, "open", coordinator.failure_code or "permission_denied",
                    coordinator.failure_message or "Application thread access was revoked"), true)
            end
            for request_id, instance_id in pairs(binding_requests) do
                if instance_id == coordinator.instance_id then binding_requests[request_id] = nil end
            end
            coordinators[coordinator.instance_id] = nil
        end
    end
    local function run_binding_effect(coordinator: BindingCoordinator, effect: thread_binding_reducer.Effect?)
        if not effect then return end
        coordinator.effect = effect
        if type(effect) == "string" then complete_binding(coordinator, effect); return end
        local binding = coordinator.state.binding
        if effect.kind == "host" then
            local request_id = uuid.v7()
            local request = binding_protocol.request({version = 1, workspace_id = workspace_id,
                request_id = request_id, op = effect.op, value = effect.value}, workspace_id)
            if not request then error("Reducer produced an invalid application binding request") end
            binding_requests[request_id] = binding and binding.instance_id or coordinator.open and coordinator.open.instance_id or ""
            local sent = process.send(owner, "bee.application.binding.request", request)
            if not sent then
                binding_requests[request_id] = nil
                -- Nothing reached the host. Keep the reducer's outstanding
                -- host effect and replay that exact request on a bounded tick.
                coordinator.retry_at = now() + 0.2
            else
                coordinator.effect = nil
            end
        elseif not binding then
            complete_binding(coordinator, "failed")
        elseif effect.kind == "membership" then
            local get = thread_binding.get_request(binding, workspace_id)
            if effect.principal == "application" then
                local reply = get and thread_call(binding.actor_id, "bee.threads.service:get", get) or nil
                local status = thread_binding.application_status(reply, binding, workspace_id)
                drive_binding(coordinator, {kind = "membership", principal = "application", purpose = effect.purpose,
                    state = status.state, head_revision = status.head_revision, membership_revision = status.membership_revision})
            else
                local reply = get and thread_call(binding.initiating_owner_id, "bee.threads.service:get", get) or nil
                local purpose = effect.purpose
                if not purpose then error("Reducer membership effect has no purpose") end
                local revision = purpose == "cleanup_refresh" and thread_binding.owner_head(reply, binding, workspace_id)
                    or thread_binding.owner_get(reply, binding, workspace_id)
                local state: "active" | "unknown" = "unknown"
                if revision then state = "active" end
                local event: thread_binding_reducer.Event = {kind = "membership", principal = "owner", purpose = purpose,
                    state = state, head_revision = revision, membership_revision = nil}
                drive_binding(coordinator, event)
            end
        elseif effect.kind == "join" then
            local request = thread_binding.join_request(binding, workspace_id, binding.idempotency_key, effect.expected_revision)
            local reply, err = nil, nil
            if request then reply, err = thread_call(binding.initiating_owner_id, "bee.threads.service:join", request) end
            local decoded = thread_binding.reply(reply)
            local outcome = decoded and decoded.ok and "success" or decoded and decoded.error and decoded.error.code == "CONFLICT" and "conflict" or "unknown"
            if err then outcome = "unknown" end
            drive_binding(coordinator, {kind = "join", outcome = outcome})
        else
            local request = thread_binding.leave_request(binding, workspace_id, binding.idempotency_key .. "-leave", effect.expected_revision)
            local reply = request and thread_call(binding.initiating_owner_id, "bee.threads.service:leave", request) or nil
            local decoded = thread_binding.reply(reply)
            local outcome = decoded and decoded.ok and "success" or decoded and decoded.error and decoded.error.code == "CONFLICT" and "conflict" or "unknown"
            drive_binding(coordinator, {kind = "leave", outcome = outcome})
        end
    end
    drive_binding = function(coordinator: BindingCoordinator, event: thread_binding_reducer.Event)
        local was_revoke = event.kind == "host" and event.op == "begin_revoke" and event.outcome == "success"
        local state, effect = thread_binding_reducer.reduce(coordinator.state, event)
        coordinator.state = state
        if was_revoke and coordinator.open and coordinator.failure_code then
            local open = coordinator.open
            emit(contract.reply(open.request.request_id, "open", coordinator.failure_code,
                coordinator.failure_message or "Application thread access was revoked"), true)
            coordinator.open = nil
        end
        if was_revoke and coordinator.stop_event then
            local item = coordinator.state.binding and find_instance(coordinator.state.binding.instance_id)
            if item and coordinator.settle_after_revoke then settle_exited_replacement(item, true)
            elseif item then transition(item, coordinator.stop_event) end
            coordinator.stop_event = nil
            coordinator.settle_after_revoke = nil
        end
        run_binding_effect(coordinator, effect)
    end
    local function begin_runtime(req: contract.Request, provenance: open_protocol.Provenance,
        descriptor: contract.Descriptor, binding: contract.Binding, scope: security.Scope, existing: Instance?)
        if binding.thread_access ~= "observe_post" or provenance.thread_id ~= req.thread_id
            or provenance.subject ~= provenance.initiating_owner then
            emit(contract.reply(req.request_id, "open", "permission_denied", "Application runtime provenance is not admitted"), true)
            return
        end
        local instance_id, view_id = existing and existing.instance_id or uuid.v7(), existing and existing.view_id or uuid.v7()
        local active = coordinators[instance_id]
        if active then
            local stored = active.state.binding
            if not stored or stored.state ~= "active" or stored.thread_id ~= provenance.thread_id
                or stored.definition_id ~= descriptor.definition_id or stored.initiating_owner_id ~= provenance.initiating_owner then
                emit(contract.reply(req.request_id, "open", "thread_conflict", "Application instance has another thread delegation"), true)
            elseif existing and existing.state.phase == "ready" then
                local get = thread_binding.get_request(stored, workspace_id)
                local owner_reply = get and thread_call(stored.initiating_owner_id, "bee.threads.service:get", get) or nil
                if not thread_binding.owner_get(owner_reply, stored, workspace_id) then
                    emit(contract.reply(req.request_id, "open", "permission_denied", "Only the current thread owner may open the bound application"), true)
                else
                    local member_reply = get and thread_call(stored.actor_id, "bee.threads.service:get", get) or nil
                    local membership = thread_binding.application_status(member_reply, stored, workspace_id)
                    if membership.state == "unknown" then
                        emit(contract.reply(req.request_id, "open", "uncertain", "Application thread membership could not be verified"), true)
                    elseif membership.state ~= "active" or membership.membership_revision ~= stored.membership_revision then
                        drive_binding(active, {kind = "revoke"})
                        emit(contract.reply(req.request_id, "open", "permission_denied", "Application thread membership changed"), true)
                    else
                        existing.thread_id = stored.thread_id
                        emit(identified(existing, "focus", req.request_id), true)
                    end
                end
            else emit(contract.reply(req.request_id, "open", "busy", "Application binding recovery is incomplete"), true) end
            return
        end
        local actor_id = thread_binding.actor(workspace_id, instance_id)
        if not actor_id then emit(contract.reply(req.request_id, "open", "permission_denied", "Application identity is invalid"), true); return end
        local provisional = {instance_id = instance_id, thread_id = provenance.thread_id, actor_id = actor_id,
            role = "participant", initiating_owner_id = provenance.initiating_owner}
        local get = thread_binding.get_request(provisional, workspace_id)
        local owner_reply
        if get then
            owner_reply = thread_call(provenance.initiating_owner, "bee.threads.service:get", get)
        end
        local head_revision = thread_binding.owner_get(owner_reply, provisional, workspace_id)
        if not head_revision then
            emit(contract.reply(req.request_id, "open", "permission_denied", "Only the current thread owner may delegate application access"), true)
            return
        end
        local coordinator: BindingCoordinator = {instance_id = instance_id, state = thread_binding_reducer.new(), retry_at = 0,
            open = {request = req, provenance = provenance, descriptor = descriptor, binding = binding, scope = scope,
                view_id = view_id, instance_id = instance_id, existing = existing ~= nil}}
        coordinators[instance_id] = coordinator
        drive_binding(coordinator, {kind = "open", value = {instance_id = instance_id, thread_id = provenance.thread_id,
            definition_id = descriptor.definition_id, actor_id = actor_id, role = "participant", idempotency_key = req.request_id,
            definition_revision = descriptor.definition_revision, initiating_owner_id = provenance.initiating_owner,
            gateway_binding_id = provenance.binding_id, gateway_approval_id = provenance.access_approval_id,
            gateway_proposal_digest = provenance.access_proposal_digest, access = "observe_post", join_expected_revision = head_revision}})
    end
    launch_binding = function(coordinator: BindingCoordinator)
        local open, stored = coordinator.open, coordinator.state.binding
        if not open or not stored or stored.state ~= "active" then return end
        local descriptor, binding, scope = current_application(open.descriptor.definition_id)
        if not descriptor or descriptor.definition_revision ~= open.descriptor.definition_revision
            or not binding or binding.thread_access ~= "observe_post" or not scope then
            fail_binding(coordinator, "not_admitted", "Application admission changed while thread access was being admitted")
            return
        end
        if open.existing then
            local item = instances[open.view_id]
            if not item or item.instance_id ~= open.instance_id or item.state.phase ~= "ready" then
                fail_binding(coordinator, "request_expired", "Application changed while thread access was being admitted")
            else
                item.thread_id = stored.thread_id
                emit(identified(item, "focus", open.request.request_id), true)
                coordinator.open = nil
            end
            return
        end
        local theme = appearance.theme(preferences.theme)
        local view, view_error = tty.viewport({width = 60, height = 16, page = appearance.page(theme, descriptor.role == "terminal")})
        if not view then fail_binding(coordinator, "viewport_failed", tostring(view_error)); return end
        local grant, grant_error = view:grant()
        if not grant then view:close(); fail_binding(coordinator, "grant_failed", tostring(grant_error)); return end
        local version, token = assert(registry.current_version()), uuid.v7()
        local started = execution.start(grant, {definition_id = descriptor.definition_id, scope = scope, workspace_pid = owner,
            workspace_id = workspace_id, actor = application_actor(workspace_id, open.instance_id, descriptor.definition_id,
                descriptor.definition_revision, 1), instance_id = open.instance_id, view_id = open.view_id, thread_id = stored.thread_id,
            execution_generation = 1, definition_revision = descriptor.definition_revision, registry_revision = version:string(),
            launch_token = token, resume_schema = descriptor.resume_schema, resume_state = open.request.resume_state, arguments = open.request.arguments})
        if not started.pid then view:close(); fail_binding(coordinator, started.error_code, started.error); return end
        instances[open.view_id] = {view_id = open.view_id, instance_id = open.instance_id, thread_id = stored.thread_id,
            execution_pid = started.pid, view = view, descriptor = descriptor, binding = binding, launch_token = token, observers = {},
            state = lifecycle.start(now()), open_request = open.request.request_id, opened = false, resume_state = open.request.resume_state,
            arguments = open.request.arguments, replacement = nil, waiters = {}, attempts = 0, producer_generation = 1}
        coordinator.open = nil
        if binding.catalog_read then publish_catalog_readers() end
    end
    local function send_thread_result(pid: string, request: thread_protocol.Request,
        value: unknown, code: string?, message: string?)
        local raw = {version = 1, request_id = request.request_id, instance_id = request.instance_id,
            execution_generation = request.execution_generation, ok = code == nil,
            value = code == nil and value or nil,
            error = code and {code = code, message = message or "Application thread request failed"} or nil}
        local reply = thread_protocol.reply(raw)
        if not reply then error("Constructed an invalid application thread reply") end
        process.send(pid, "bee.application.thread.result", reply)
    end
    local function handle_thread_request(sender: string, raw: unknown)
        local request = thread_protocol.request(raw)
        if not request then return end
        local item = find_pid(sender)
        if not item or item.instance_id ~= request.instance_id or item.launch_token ~= request.launch_token
            or item.producer_generation ~= request.execution_generation then return end
        refresh_admission()
        local coordinator = coordinators[item.instance_id]
        local stored = coordinator and coordinator.state.binding or nil
        local current_descriptor, current_binding = current_application(item.descriptor.definition_id)
        if item.replacement then
            -- Refresh can observe the compatible definition before the old
            -- producer exits. Its descriptor is necessarily stale, but the
            -- durable delegation has not changed. Do not execute through that
            -- producer or mistake its expected revision skew for membership
            -- loss. A removed current admission still fences it immediately.
            if current_descriptor and current_binding and current_binding.thread_access == "observe_post"
                and stored and stored.state == "active"
                and stored.actor_id == thread_binding.actor(workspace_id, item.instance_id)
                and stored.thread_id == item.thread_id
                and stored.definition_id == item.descriptor.definition_id
                and stored.definition_revision == item.descriptor.definition_revision
                and stored.access == "observe_post"
                and current_descriptor.definition_revision == item.replacement.revision
                and catalog.replaces(item.descriptor, current_descriptor) then
                send_thread_result(sender, request, nil, "UNCERTAIN", "Application replacement is in progress")
                return
            end
            if coordinator then drive_binding(coordinator, {kind = "revoke"}) end
            send_thread_result(sender, request, nil, "DENIED", "Application thread access is not active")
            return
        end
        if not current_descriptor or current_descriptor.definition_revision ~= item.descriptor.definition_revision
            or not current_binding or current_binding.thread_access ~= "observe_post"
            or not stored or stored.state ~= "active"
            or stored.actor_id ~= thread_binding.actor(workspace_id, item.instance_id)
            or stored.thread_id ~= item.thread_id then
            if coordinator then drive_binding(coordinator, {kind = "revoke"}) end
            send_thread_result(sender, request, nil, "DENIED", "Application thread access is not active")
            return
        end
        local get = thread_binding.get_request(stored, workspace_id)
        local membership_reply = get and thread_call(stored.actor_id, "bee.threads.service:get", get) or nil
        local membership = thread_binding.application_status(membership_reply, stored, workspace_id)
        if membership.state == "unknown" then
            send_thread_result(sender, request, nil, "UNCERTAIN", "Application thread membership could not be verified")
            return
        end
        if membership.state ~= "active" or membership.membership_revision ~= stored.membership_revision then
            drive_binding(coordinator, {kind = "revoke"})
            send_thread_result(sender, request, nil, "DENIED", "Application thread membership changed")
            return
        end
        local args = request.arguments
        local call: {[string]: unknown} = {thread_id = stored.thread_id}
        local target = ""
        if request.operation == "read" then
            target = "bee.threads.service:read_after"
            call.cursor, call.limit, call.filter = args.cursor or 0, args.limit, {kinds = {"message"}}
        elseif request.operation == "post" then
            target = "bee.threads.service:record"
            local body: {[string]: unknown} = {sender_id = stored.actor_id, message_id = args.message_id,
                message_kind = args.message_kind, recipient_ids = args.recipient_ids, content = args.content,
                outcome = args.outcome}
            if args.in_reply_to_record_id then
                body.in_reply_to = {thread_id = stored.thread_id, record_id = args.in_reply_to_record_id}
            end
            call.idempotency_key, call.kind, call.body, call.context = args.idempotency_key, "message", body, {}
        elseif request.operation == "subscribe" then
            target = "bee.threads.delivery:subscribe"
            call.idempotency_key, call.consumer_id = args.idempotency_key, stored.actor_id
            call.after_sequence, call.filter, call.durability = args.after_sequence, {kinds = {"message"}}, "durable"
        elseif request.operation == "page" then
            target = "bee.threads.delivery:page"
            call.subscription_id, call.limit = args.subscription_id, args.limit
        else
            target = request.operation == "ack_page" and "bee.threads.delivery:ack_page"
                or request.operation == "resume" and "bee.threads.delivery:resume"
                or "bee.threads.delivery:unsubscribe"
            call.idempotency_key, call.subscription_id = args.idempotency_key, args.subscription_id
            if request.operation == "ack_page" then
                call.page_id, call.scanned_through = args.page_id, args.scanned_through
            end
        end
        local raw_reply, call_error = facade_call(stored.actor_id, target, call)
        local reply = thread_binding.reply(raw_reply)
        if call_error or not reply then
            send_thread_result(sender, request, nil, "UNCERTAIN", tostring(call_error or "Thread operation returned no valid reply"))
        elseif not reply.ok then
            send_thread_result(sender, request, nil, reply.error and reply.error.code or "UNAVAILABLE",
                reply.error and reply.error.message or "Thread operation failed")
        else send_thread_result(sender, request, reply.value, nil, nil) end
    end
    local function appearance_state(item: Instance, request_id: string?, code: string?, message: string?, value: appearance.Preferences?, revision: number?, scope: string?)
        local current = value or preferences
        process.send(item.execution_pid, "bee.appearance.state", {version = 1, request_id = request_id or "",
            revision = revision or 0, theme = current.theme, background = current.background, taskbar = current.taskbar,
            error_code = code or "", error = message or "", scope = scope})
    end
    local function route_client_appearance(item: Instance, action: AppearanceOp, request_id: string, value: appearance.Preferences): boolean
        local mounted = item.attachment
        if not mounted or mounted.recipient == "" then return false end
        -- Keep one write in flight for an app, while allowing a bind-triggered
        -- state refresh to coexist with a user click already being delivered.
        for id, waiter in pairs(preference_waiters) do
            if waiter.recipient == item.execution_pid and (action ~= "state" or waiter.action == "state") then
                appearance_state(item, waiter.request_id, "superseded", "A newer appearance request replaced this one")
                preference_waiters[id] = nil
            end
        end
        local routed_id = uuid.v7()
        preference_waiters[routed_id] = {request_id = request_id, recipient = item.execution_pid, action = action,
            renderer = mounted.recipient, mount = mounted.mount}
        local sent, err = process.send(owner, "bee.appearance.request", {version = 1, op = "appearance", action = action,
            request_id = routed_id, recipient = mounted.recipient, theme = value.theme, background = value.background, taskbar = value.taskbar})
        if not sent then
            preference_waiters[routed_id] = nil
            appearance_state(item, request_id, "unavailable", tostring(err))
        end
        return true
    end
    find_instance = function(instance_id: string): Instance?
        for _, item in pairs(instances) do if item.instance_id == instance_id then return item end end
        return nil
    end
    find_pid = function(pid: string): Instance?
        for _, item in pairs(instances) do if item.execution_pid == pid then return item end end
        return nil
    end
    local function mount(item: Instance): string?
        if recipient == "" then return "Desktop is not attached" end
        local result = attachment.replace(item.view, item.attachment, recipient)
        item.attachment = result.attachment
        if result.error ~= "" then return result.error end
        return nil
    end
    local function control_result(waiter: Waiter, code: string, message: string)
        process.send(waiter.recipient, "bee.application.result", {version = 1, request_id = waiter.request_id,
            error_code = code, error = message})
    end
    local function refresh_shutdown()
        local plan = shutdown_plan
        if not plan then return end
        if not shutdown.ready(plan) or quit_sent then return end
        if not shutdown.needs_confirmation(plan) then
            quit_sent = true
            emit(contract.reply(plan.request_id, "quit"))
            return
        end
        local decisions = shutdown.decisions(plan)
        local names, unresponsive = "", 0
        for _, decision in ipairs(decisions) do
            if #names + #decision.title < 240 then names = names .. (names == "" and "" or ", ") .. decision.title end
            if decision.force then unresponsive = unresponsive + 1 end
        end
        local message = "Stop all applications and running work? Unsaved changes may be lost. " .. names
        if unresponsive > 0 then message = message .. ". " .. tostring(unresponsive) .. " application(s) did not respond." end
        if not shutdown_dialog or shutdown_dialog.message ~= message then
            shutdown_dialog = {request_id = uuid.v7(), id = "bee.workspace:shutdown", instance_id = "workspace",
                kind = "confirm", title = "Quit Bee?", message = message, accept = "Quit Bee", initial = ""}
            publish_dialogs()
        end
    end
    local function finish(item: Instance, failed: boolean)
        item.replacement = nil
        if shutdown_plan then shutdown.remove(shutdown_plan, item.view_id) end
        if interactions.remove(dialogs, item.view_id) then publish_dialogs() end
        item.view:close()
        instances[item.view_id] = nil
        if item.binding.catalog_read then publish_catalog_readers() end
        for id, waiter in pairs(preference_waiters) do
            if waiter.recipient == item.execution_pid then preference_waiters[id] = nil end
        end
        if cleanup_request ~= "" then
            -- Keep recovery records when the workspace itself is shutting down.
            return
        end
        if not item.opened then
            emit(identified(item, "open", item.open_request, item.state.failure ~= "" and item.state.failure or "startup_failed", "Application did not become ready"), true)
        else
            emit(identified(item, "closed", "", failed and "application_failed" or "", failed and "Application failed" or ""))
        end
        for _, waiter in ipairs(item.waiters) do
            if waiter.control then control_result(waiter, "", "")
            else emit(identified(item, "close", waiter.request_id), true) end
        end
    end
    local function has_checkpoint(pid: string): boolean
        for _, waiter in pairs(checkpoint_waiters) do
            if waiter.pid == pid then return true end
        end
        return false
    end
    -- A compatible revision replaces only the execution behind the existing
    -- viewport. Controller and observer mounts, geometry, page, logical IDs
    -- and the last acknowledged checkpoint therefore remain continuous.
    local function start_replacement(item: Instance)
        local pending = item.replacement
        if cleanup_request ~= "" or not pending or not pending.exited or has_checkpoint(item.execution_pid) then return end
        local current = admission.current
        local replacement = current and current.descriptors[item.descriptor.definition_id]
        local replacement_binding: contract.Binding? = nil
        if current then
            for _, candidate in ipairs(current.bindings) do
                if candidate.definition_id == item.descriptor.definition_id then replacement_binding = candidate; break end
            end
        end
        local scope = current and current.scopes[item.descriptor.definition_id]
        if not replacement or replacement.definition_revision ~= pending.revision
            or not replacement_binding or not scope or not catalog.replaces(item.descriptor, replacement) then
            item.replacement = nil
            item.state = {phase = "stopped", deadline = 0, failure = "replacement_definition_changed"}
            finish(item, true)
            return
        end
        if interactions.remove(dialogs, item.view_id) then publish_dialogs() end
        for id, waiter in pairs(preference_waiters) do
            if waiter.recipient == item.execution_pid then preference_waiters[id] = nil end
        end
        local previous_catalog_reader = item.binding.catalog_read
        item.descriptor, item.binding = replacement, replacement_binding
        item.announced_title, item.title_dirty, item.negotiate_close = nil, nil, nil
        item.close_request_id, item.attempts = nil, 0
        item.state = lifecycle.start(now())
        local grant, generation = item.view:renew(item.producer_generation)
        if not grant then
            item.replacement = nil
            item.state = {phase = "stopped", deadline = 0, failure = "replacement_grant_failed"}
            finish(item, true)
            return
        end
        local version = assert(registry.current_version())
        local token = uuid.v7()
        local execution_generation = item.producer_generation + 1
        local started = execution.start(grant, {definition_id = item.descriptor.definition_id,
            scope = scope, workspace_pid = owner, workspace_id = workspace_id,
            actor = application_actor(workspace_id, item.instance_id, item.descriptor.definition_id,
                item.descriptor.definition_revision, execution_generation),
            instance_id = item.instance_id, view_id = item.view_id,
            thread_id = item.thread_id,
            execution_generation = execution_generation,
            definition_revision = item.descriptor.definition_revision,
            registry_revision = version:string(), launch_token = token,
            resume_schema = item.descriptor.resume_schema, resume_state = item.resume_state,
            arguments = item.arguments})
        if not started.pid then
            local _, cancel_error = item.view:cancel_grant(grant)
            item.replacement = nil
            item.state = {phase = "stopped", deadline = 0,
                failure = cancel_error and "replacement_grant_cancel_failed" or "replacement_" .. started.error_code}
            finish(item, true)
            return
        end
        item.execution_pid, item.launch_token, item.producer_generation = started.pid, token, assert(generation)
        item.replacement = nil
        if previous_catalog_reader or item.binding.catalog_read then publish_catalog_readers() end
    end
    local function discard_dialog(item: Instance)
        local pending_dialog = interactions.remove(dialogs, item.view_id)
        if pending_dialog then
            if not pending_dialog.closing then
                process.send(item.execution_pid, "bee.application.query.result", {version = 1,
                    request_id = pending_dialog.client_request_id, id = item.view_id, instance_id = item.instance_id,
                    action = "cancel", value = "", error = ""})
            end
            publish_dialogs()
        end
    end
    local function close_prompt(item: Instance, title: string, message: string, accept: string)
        local spec: interaction.Spec = {request_id = uuid.v7(), id = item.view_id, instance_id = item.instance_id,
            kind = "confirm", title = title, message = message, accept = accept, initial = ""}
        if interactions.add(dialogs, spec, item.close_request_id or "", item.execution_pid, true) then publish_dialogs() end
    end
    transition = function(item: Instance, event: lifecycle.Event)
        local was_opened = item.opened
        local next_state, effect = lifecycle.reduce(item.state, event, now(), item.binding.close_grace_ms)
        item.state = next_state
        if effect == "opened" then
            -- Readiness belongs to the producer. A missing or failed consumer
            -- attachment must not turn a ready application into a startup failure.
            item.opened = true
            local attachment_error: string? = nil
            if not was_opened and recipient ~= "" then attachment_error = mount(item) end
            if was_opened then emit(identified(item, "title", ""))
            else emit(identified(item, "open", item.open_request), true) end
            appearance_state(item)
            if attachment_error then
                emit(identified(item, "attached", item.open_request, "attachment_failed", attachment_error))
            end
        elseif effect == "query_close" then
            discard_dialog(item)
            process.send(item.execution_pid, "bee.application.close", {version = 1, request_id = item.close_request_id,
                id = item.view_id, instance_id = item.instance_id})
        elseif effect == "close_timeout" then
            if shutdown_plan and shutdown_plan.pending[item.view_id] then
                shutdown.record(shutdown_plan, item.view_id, item.announced_title or item.descriptor.title, "Application did not respond", true)
                refresh_shutdown()
            else close_prompt(item, "Application did not respond", "Force stopping may lose unsaved work.", "Force stop") end
        elseif effect == "close_cancelled" then
            discard_dialog(item)
            process.send(item.execution_pid, "bee.application.close.result", {version = 1, request_id = item.close_request_id,
                id = item.view_id, instance_id = item.instance_id, action = "cancel"})
            item.close_request_id = nil
            for _, waiter in ipairs(item.waiters) do
                if waiter.control then control_result(waiter, "cancelled", "Close cancelled")
                else emit(identified(item, "close", waiter.request_id, "cancelled", "Close cancelled"), true) end
            end
            item.waiters = {}
        elseif effect == "close" then
            discard_dialog(item)
            item.close_request_id = nil
            local _, err = item.view:send({type = "close"})
            if err then item.state = {phase = "stopping", deadline = now(), failure = item.state.failure} end
        elseif effect == "terminate" then
            discard_dialog(item)
            item.close_request_id = nil
            item.attempts = item.attempts + 1
            local _, err = process.terminate(item.execution_pid)
            if err or item.attempts >= 3 then
                -- Do not claim EXIT or lose ownership when termination fails.
                for _, waiter in ipairs(item.waiters) do
                    if waiter.control then control_result(waiter, "termination_pending", tostring(err or "Waiting for process exit"))
                    else emit(identified(item, "close", waiter.request_id, "termination_pending", tostring(err or "Waiting for process exit")), true) end
                end
                item.waiters = {}
                if item.attempts >= 3 then item.state.deadline = 0 end
            end
        elseif effect == "closed" or effect == "failed" then finish(item, effect == "failed") end
    end
    local function binding_is_revoked(coordinator: BindingCoordinator?): boolean
        return coordinator ~= nil and coordinator.state.binding ~= nil
            and coordinator.state.binding.state == "revoked"
    end
    local function commit_explicit_close(item: Instance, event: lifecycle.Event)
        local coordinator = coordinators[item.instance_id]
        -- A prior membership failure may already have committed the revoke.
        -- Its reducer now owns independent cleanup; a second revoke resumes
        -- that cleanup and cannot emit another begin_revoke success to wake a
        -- close waiter. Stop this execution immediately instead.
        if binding_is_revoked(coordinator) then
            transition(item, event)
        elseif coordinator then
            coordinator.stop_event = event
            drive_binding(coordinator, {kind = "revoke"})
        else transition(item, event) end
    end
    -- An EXIT consumed for a catalog replacement leaves no producer to stop.
    -- Explicit close cancels a now-unreachable checkpoint reply; workspace
    -- cleanup keeps it so the owner can drain its durable write before quit.
    settle_exited_replacement = function(item: Instance, discard_checkpoint: boolean): boolean
        local replacement = item.replacement
        if not replacement or not replacement.exited then return false end
        item.replacement = nil
        if discard_checkpoint then
            for id, checkpoint in pairs(checkpoint_waiters) do
                if checkpoint.pid == item.execution_pid then checkpoint_waiters[id] = nil end
            end
        end
        item.state = {phase = "stopped", deadline = 0, failure = ""}
        finish(item, false)
        return true
    end
    local function stop(item: Instance, waiter: Waiter, force: boolean)
        if shutdown_plan and not force then
            if waiter.control then control_result(waiter, "busy", "Quit confirmation pending")
            else emit(identified(item, "close", waiter.request_id, "busy", "Quit confirmation pending"), true) end
            return
        end
        if #item.waiters >= 16 then
            if waiter.control then control_result(waiter, "busy", "Too many pending stop requests")
            else emit(identified(item, "close", waiter.request_id, "busy", "Too many pending stop requests"), true) end
            return
        end
        -- An explicit close wins over a catalog-triggered execution swap.
        -- Once the old producer has exited, there is no process left to
        -- negotiate with or terminate. Settle the logical window directly.
        item.waiters[#item.waiters + 1] = waiter
        local coordinator = coordinators[item.instance_id]
        if item.replacement and item.replacement.exited and coordinator then
            if binding_is_revoked(coordinator) then
                settle_exited_replacement(item, true)
            else
                coordinator.stop_event, coordinator.settle_after_revoke = force and "force_stop" or "stop", true
                drive_binding(coordinator, {kind = "revoke"})
            end
            return
        elseif settle_exited_replacement(item, true) then return end
        item.replacement = nil
        if force then item.attempts = 0 end
        if not force and item.negotiate_close and (item.state.phase == "ready" or item.state.phase == "close_requested"
            or item.state.phase == "close_confirming" or item.state.phase == "close_unresponsive") then
            if item.state.phase == "ready" then
                item.close_request_id = uuid.v7()
                transition(item, "request_close")
            end
            emit(identified(item, "closing", waiter.control and "" or waiter.request_id))
        else commit_explicit_close(item, force and "force_stop" or "stop") end
    end
    refresh_admission(true)
    publish_catalog_readers()
    assert(process.send(owner, "bee.app.ready", {version = 1}))
    local function abort_shutdown()
        local plan = shutdown_plan
        shutdown_plan, shutdown_dialog, quit_sent = nil, nil, false
        if plan then
            for id, item in pairs(instances) do
                if plan.pending[id] or plan.decisions[id] then transition(item, "cancel_close") end
            end
            emit(contract.reply(plan.request_id, "quit", "cancelled", "Quit cancelled"))
        end
        publish_dialogs()
    end
    local function prepare_shutdown()
        if cleanup_request ~= "" then return end
        if shutdown_plan then publish_dialogs(); return end
        local ids: {string} = {}
        for id, item in pairs(instances) do
            if item.negotiate_close and (item.state.phase == "ready" or item.state.phase == "close_requested"
                or item.state.phase == "close_confirming" or item.state.phase == "close_unresponsive") then ids[#ids + 1] = id end
        end
        shutdown_plan = shutdown.start(uuid.v7(), ids)
        local function ask(item: Instance)
            if item.state.phase ~= "ready" then transition(item, "cancel_close") end
            item.close_request_id = uuid.v7()
            transition(item, "request_close")
        end
        for _, id in ipairs(ids) do local item = instances[id]; if item then ask(item) end end
        refresh_shutdown()
    end
    local function accept_readiness(item: Instance, negotiate: boolean)
        if item.state.phase == "starting" then item.negotiate_close = negotiate end
        transition(item, "ready")
    end
    local function tick_instance(item: Instance)
        transition(item, "tick")
        if item.opened and lifecycle.accepts_updates(item.state) and item.title_dirty then
            emit(identified(item, "title", ""))
            item.title_dirty = false
        end
    end
    local running = true
    while running do
        local selected = channel.select({requests:case_receive(), app_ready:case_receive(), titles:case_receive(), queries:case_receive(), answers:case_receive(), close_replies:case_receive(), shutdown_requests:case_receive(), appearance_requests:case_receive(),
            appearance_states:case_receive(), controls:case_receive(), checkpoints:case_receive(), persisted:case_receive(), binding_results:case_receive(), binding_recovery:case_receive(), thread_requests:case_receive(), events:case_receive(), ticks:case_receive()})
        if not selected.ok then break end
        if selected.channel == thread_requests then
            local message = selected.value
            handle_thread_request(tostring(message:from()), message:payload():data())
        elseif selected.channel == binding_results then
            local message = selected.value
            if message:from() == owner then
                local reply = binding_protocol.reply(message:payload():data(), workspace_id)
                if reply then
                    local instance_id: string? = binding_requests[reply.request_id]
                    if instance_id then
                    binding_requests[reply.request_id] = nil
                    local coordinator = coordinators[instance_id]
                    if coordinator then
                        if reply.ok and reply.binding then
                            local event: thread_binding_reducer.Event = {kind = "host", op = reply.op,
                                outcome = "success", binding = reply.binding}
                            drive_binding(coordinator, event)
                        else
                            local event: thread_binding_reducer.Event = {kind = "host", op = reply.op,
                                outcome = "failure", binding = nil}
                            drive_binding(coordinator, event)
                        end
                    end
                    end
                end
            end
        elseif selected.channel == binding_recovery then
            local message = selected.value
            if message:from() == owner and not recovery_received then
                local recovered = binding_protocol.recovery(message:payload():data(), workspace_id)
                if not recovered then error("Invalid application thread binding recovery snapshot") end
                for _, raw_binding in ipairs(recovered.items) do
                    local binding: binding_protocol.Binding = raw_binding
                    local coordinator: BindingCoordinator = {instance_id = binding.instance_id,
                        state = thread_binding_reducer.new(), open = nil, retry_at = 0}
                    coordinators[binding.instance_id] = coordinator
                    drive_binding(coordinator, {kind = "recover", binding = binding})
                end
                -- An uncertain active recovery remains unacknowledged. Revoked
                -- cleanup rows may be retried after the host owns this snapshot.
                local settled = true
                for _, raw_coordinator in pairs(coordinators) do
                    local coordinator: BindingCoordinator = raw_coordinator
                    local terminal = coordinator.state.terminal
                    if terminal ~= "active" and terminal ~= "fenced" and terminal ~= "cleanup_pending" then settled = false; break end
                end
                if settled then
                    recovery_received = true
                    assert(process.send(owner, "bee.application.binding.recovered", {version = 1, workspace_id = workspace_id}))
                end
            end
        elseif selected.channel == events then
            local event = selected.value
            if event.kind == process.event.CANCEL or (event.kind == process.event.EXIT and tostring(event.from) == owner) then break end
            if event.kind == process.event.EXIT then
                local item = find_pid(tostring(event.from))
                local replacement: Replacement? = nil
                if item then replacement = item.replacement end
                if item and replacement then
                    replacement.exited = true
                    start_replacement(item)
                elseif item then transition(item, item.state.phase == "ready" and "unexpected_exit" or "exit") end
            end
        elseif selected.channel == ticks then
            refresh_admission()
            for _, raw_coordinator in pairs(coordinators) do
                local coordinator: BindingCoordinator = raw_coordinator
                if coordinator.effect and type(coordinator.effect) ~= "string" and now() >= coordinator.retry_at then
                    run_binding_effect(coordinator, coordinator.effect)
                end
                if (coordinator.state.terminal == "retry" or coordinator.state.terminal == "failed" or coordinator.state.terminal == "cleanup_pending")
                    and now() >= coordinator.retry_at then
                    local binding = coordinator.state.binding
                    if binding then
                        coordinator.state = thread_binding_reducer.new()
                        drive_binding(coordinator, {kind = "recover", binding = binding})
                    end
                end
            end
            if not recovery_received then
                local settled = true
                for _, raw_coordinator in pairs(coordinators) do
                    local coordinator: BindingCoordinator = raw_coordinator
                    local terminal = coordinator.state.terminal
                    if terminal ~= "active" and terminal ~= "fenced" and terminal ~= "cleanup_pending" then settled = false; break end
                end
                if settled then
                    recovery_received = true
                    assert(process.send(owner, "bee.application.binding.recovered", {version = 1, workspace_id = workspace_id}))
                end
            end
            for id, waiter in pairs(checkpoint_waiters) do
                if now() >= waiter.deadline then
                    process.send(waiter.pid, "bee.application.checkpoint_result", {version = 1, request_id = waiter.request_id,
                        error_code = "timeout", error = "Checkpoint persistence timed out"})
                    checkpoint_waiters[id] = nil
                end
            end
            for _, item in pairs(instances) do
                local replacement = item.replacement
                if replacement and replacement.exited then start_replacement(item)
                else tick_instance(item) end
            end
            refresh_shutdown()
        elseif selected.channel == shutdown_requests and selected.value:from() == owner then
            local data: unknown = selected.value:payload():data()
            if type(data) == "table" and data.version == 1 and data.op == "prepare" then prepare_shutdown() end
        elseif selected.channel == close_replies then
            local message = selected.value
            local item = find_pid(tostring(message:from()))
            local data: unknown = message:payload():data()
            if item and item.state.phase == "close_requested" and type(data) == "table" and data.version == 1
                and data.id == item.view_id and data.instance_id == item.instance_id and data.launch_token == item.launch_token
                and data.request_id == item.close_request_id then
                if data.action == "accept" then
                    if shutdown_plan and shutdown_plan.pending[item.view_id] then
                        transition(item, "confirm_close")
                        shutdown.record(shutdown_plan, item.view_id, item.announced_title or item.descriptor.title, "", false)
                        refresh_shutdown()
                    else
                        commit_explicit_close(item, "accept_close")
                    end
                elseif data.action == "cancel" then
                    if shutdown_plan and shutdown_plan.pending[item.view_id] then abort_shutdown()
                    else transition(item, "cancel_close") end
                elseif data.action == "confirm" then
                    local spec = interaction.spec({version = 1, request_id = data.request_id, id = data.id,
                        instance_id = data.instance_id, kind = "confirm", title = data.title, message = data.message,
                        accept = data.accept, initial = ""})
                    if spec then
                        transition(item, "confirm_close")
                        if shutdown_plan and shutdown_plan.pending[item.view_id] then
                            shutdown.record(shutdown_plan, item.view_id, item.announced_title or item.descriptor.title,
                                spec.message ~= "" and spec.message or spec.title, false)
                            refresh_shutdown()
                        else close_prompt(item, spec.title, spec.message, spec.accept) end
                    end
                end
            end
        elseif selected.channel == queries then
            local message = selected.value
            local item = find_pid(tostring(message:from()))
            local data: unknown = message:payload():data()
            if item and type(data) == "table"
                and data.launch_token == item.launch_token then
                local spec = interaction.spec(data)
                if spec and spec.id == item.view_id and spec.instance_id == item.instance_id then
                    local client_request_id = spec.request_id
                    spec.request_id = uuid.v7()
                    if (item.state.phase == "starting" or item.state.phase == "ready") and not shutdown_plan
                        and interactions.add(dialogs, spec, client_request_id, item.execution_pid, false) then publish_dialogs()
                    else
                        process.send(item.execution_pid, "bee.application.query.result", {version = 1,
                            request_id = client_request_id, id = item.view_id, instance_id = item.instance_id,
                            action = "cancel", value = "", error = "busy"})
                    end
                end
            end
        elseif selected.channel == answers and selected.value:from() == owner and cleanup_request == "" then
            local response = interaction.response(selected.value:payload():data())
            if response and shutdown_dialog and response.id == shutdown_dialog.id and response.instance_id == shutdown_dialog.instance_id
                and response.request_id == shutdown_dialog.request_id and response.value == "" then
                if response.action == "cancel" then abort_shutdown()
                elseif not quit_sent then quit_sent = true; emit(contract.reply(response.request_id, "quit")) end
            elseif response then
                local pending_dialog = interactions.resolve(dialogs, response)
                if pending_dialog then
                    local item = instances[response.id]
                    if pending_dialog.closing and item then
                        if response.action == "cancel" then transition(item, "cancel_close")
                        else
                            local event = item.state.phase == "close_unresponsive" and "force_stop" or "accept_close"
                            commit_explicit_close(item, event)
                        end
                    else
                        process.send(pending_dialog.execution_pid, "bee.application.query.result", {version = 1,
                            request_id = pending_dialog.client_request_id, id = response.id, instance_id = response.instance_id,
                            action = response.action, value = response.value, error = ""})
                    end
                    publish_dialogs()
                end
            end
        elseif selected.channel == titles then
            local message = selected.value
            local item = find_pid(tostring(message:from()))
            local data: unknown = message:payload():data()
            if item and lifecycle.accepts_updates(item.state)
                and type(data) == "table" and data.version == 1 and data.instance_id == item.instance_id
                and data.id == item.view_id and data.launch_token == item.launch_token then
                local title = contract.text(data.title, 80)
                if title then
                    if title == "" then title = item.descriptor.title end
                    if title ~= (item.announced_title or item.descriptor.title) then
                        item.announced_title = title; item.title_dirty = true
                    end
                end
            end
        elseif selected.channel == checkpoints then
            local msg = selected.value
            local item = find_pid(tostring(msg:from()))
            local data: unknown = msg:payload():data()
            if item and type(data) == "table" and data.version == 1 and data.instance_id == item.instance_id
                and data.id == item.view_id and data.launch_token == item.launch_token then
                local request_id = contract.text(data.request_id, 80)
                if request_id and request_id ~= "" then
                    if item.descriptor.restart_policy == "never" or data.resume_schema ~= item.descriptor.resume_schema
                        or type(data.resume_state) ~= "string" or #data.resume_state > 65536 then
                        process.send(item.execution_pid, "bee.application.checkpoint_result", {version = 1, request_id = request_id,
                            error_code = "invalid_checkpoint", error = "Checkpoint does not match the application contract"})
                    else
                        for id, waiter in pairs(checkpoint_waiters) do
                            if waiter.pid == item.execution_pid then
                                process.send(waiter.pid, "bee.application.checkpoint_result", {version = 1, request_id = waiter.request_id,
                                    error_code = "superseded", error = "A newer checkpoint replaced this request"})
                                checkpoint_waiters[id] = nil
                            end
                        end
                        local routed_id = uuid.v7()
                        checkpoint_waiters[routed_id] = {request_id = request_id, pid = item.execution_pid, deadline = now() + 5,
                            resume_state = data.resume_state}
                        local record = identified(item, "open", routed_id)
                        record.resume_state = data.resume_state
                        process.send(owner, "bee.application.checkpoint", record)
                    end
                end
            end
        elseif selected.channel == persisted and selected.value:from() == owner then
            local data: unknown = selected.value:payload():data()
            if type(data) == "table" and data.version == 1 and type(data.request_id) == "string" then
                local waiter = checkpoint_waiters[data.request_id]
                if waiter then
                    -- Live descriptions retain the last acknowledged state.
                    -- A queued write, refusal or timeout cannot replace it.
                    if data.error_code == "" and data.error == "" then
                        local item = find_pid(waiter.pid)
                        if item then item.resume_state = waiter.resume_state end
                    end
                    process.send(waiter.pid, "bee.application.checkpoint_result", {version = 1, request_id = waiter.request_id,
                        error_code = type(data.error_code) == "string" and data.error_code or "invalid_result",
                        error = type(data.error) == "string" and data.error or "Invalid persistence result"})
                    checkpoint_waiters[data.request_id] = nil
                end
            end
        elseif selected.channel == app_ready then
            local msg = selected.value
            local item = find_pid(tostring(msg:from()))
            local data: unknown = msg:payload():data()
            if item and type(data) == "table" and data.version == 1 and data.instance_id == item.instance_id
                and data.view_id == item.view_id and data.launch_token == item.launch_token
                and (data.negotiate_close == nil or type(data.negotiate_close) == "boolean") then
                accept_readiness(item, data.negotiate_close == true)
            end
        elseif selected.channel == appearance_states then
            local msg = selected.value
            local data: unknown = msg:payload():data()
            if msg:from() == owner and type(data) == "table" and data.version == 1
                and (data.scope == "client" or data.scope == "display") then
                local prefs = appearance.decode(data)
                local scoped = data.scope == "client" or data.scope == "display"
                if data.scope == "display" and prefs and type(data.renderer) == "string"
                    and type(data.revision) == "number" and data.revision >= 0
                    and data.revision <= 9007199254740990 and data.revision == math.floor(data.revision) then
                    for _, candidate in pairs(instances) do
                        local target: Instance = candidate
                        local control = target.attachment
                        if control and control.recipient == data.renderer
                            and (not target.client_appearance_revision or data.revision >= target.client_appearance_revision) then
                            local _, page_error = target.view:set_page(appearance.page(appearance.theme(prefs.theme), target.descriptor.role == "terminal"))
                            if page_error then appearance_state(target, "", "page_failed", tostring(page_error))
                            else
                                target.client_appearance_revision = data.revision
                                appearance_state(target, "", "", "", prefs, data.revision, "client")
                            end
                        end
                    end
                end
                if type(data.request_id) == "string" then
                    local waiter = preference_waiters[data.request_id]
                    local item = waiter and find_pid(waiter.recipient)
                    if item and waiter then
                        local revision: number? = nil
                        if type(data.revision) == "number" and data.revision >= 0 and data.revision == math.floor(data.revision) then revision = data.revision end
                        local mounted = item.attachment
                        if scoped and (not mounted or mounted.recipient ~= waiter.renderer or mounted.mount ~= waiter.mount) then
                            -- The host fences renderer admission; the broker also fences
                            -- this application's mount, which can change independently.
                            appearance_state(item, waiter.request_id, "stale_attachment", "Application display changed")
                        elseif scoped and data.error_code == "" and revision and item.client_appearance_revision and revision < item.client_appearance_revision then
                            appearance_state(item, waiter.request_id, "superseded", "A newer display appearance is already applied")
                        else
                            if scoped and prefs and revision and data.error_code == "" then
                                for _, candidate in pairs(instances) do
                                    local target: Instance = candidate
                                    local control = target.attachment
                                    if control and control.recipient == waiter.renderer
                                        and (waiter.action ~= "state" or target == item)
                                        and (not target.client_appearance_revision or revision >= target.client_appearance_revision) then
                                        local _, page_error = target.view:set_page(appearance.page(appearance.theme(prefs.theme), target.descriptor.role == "terminal"))
                                        if page_error then
                                            appearance_state(target, target == item and waiter.request_id or "", "page_failed", tostring(page_error))
                                        else
                                            target.client_appearance_revision = revision
                                            appearance_state(target, target == item and waiter.request_id or "", "", "", prefs, revision, "client")
                                        end
                                    end
                                end
                            else
                                appearance_state(item, waiter.request_id, type(data.error_code) == "string" and data.error_code or "",
                                    type(data.error) == "string" and data.error or "", scoped and prefs or nil, revision, scoped and "client" or nil)
                            end
                        end
                    end
                    preference_waiters[data.request_id] = nil
                end
            end
        elseif selected.channel == appearance_requests then
            local msg = selected.value
            local item = find_pid(tostring(msg:from()))
            local data: unknown = msg:payload():data()
            if item and type(data) == "table" and data.version == 1 then
                local request_id = contract.text(data.request_id, 80)
                if request_id and request_id ~= "" then
                    if data.op == "state" then
                        local current = appearance.decode({theme = preferences.theme, background = preferences.background, taskbar = preferences.taskbar}) or preferences
                        if not route_client_appearance(item, "state", request_id, current) then appearance_state(item, request_id) end
                    elseif data.op == "set" or data.op == "inherit" then
                        local requested: AppearanceOp = data.op == "inherit" and "inherit" or "set"
                        local prefs = appearance.decode(data)
                        if not item.binding.appearance_write then appearance_state(item, request_id, "permission_denied", "Appearance changes are not granted")
                        elseif not prefs then appearance_state(item, request_id, "invalid_argument", "Invalid appearance")
                        else
                            -- One outstanding appearance write per app bounds waiter storage.
                            for id, waiter in pairs(preference_waiters) do
                                if waiter.recipient == item.execution_pid then
                                    appearance_state(item, waiter.request_id, "superseded", "A newer appearance request replaced this one")
                                    preference_waiters[id] = nil
                                end
                            end
                            if not route_client_appearance(item, requested, request_id, prefs) then
                                appearance_state(item, request_id, "unavailable", "A controlling display is required")
                            end
                        end
                    end
                end
            end
        elseif selected.channel == controls then
            local msg = selected.value
            local actor = find_pid(tostring(msg:from()))
            local data: unknown = msg:payload():data()
            if actor and type(data) == "table" and data.version == 1 then
                local request_id, pid = contract.text(data.request_id, 80), contract.text(data.execution_pid, 160)
                if request_id and request_id ~= "" and pid and (data.op == "stop" or data.op == "force_stop") then
                    local waiter: Waiter = {request_id = request_id, recipient = actor.execution_pid, control = true}
                    local item = find_pid(pid)
                    if not actor.binding.application_stop then control_result(waiter, "permission_denied", "Application control is not granted")
                    elseif not item then control_result(waiter, "protected_process", "Core processes are protected")
                    else stop(item, waiter, data.op == "force_stop") end
                end
            end
        elseif selected.channel == requests and selected.value:from() == owner then
            local raw_request: unknown = selected.value:payload():data()
            local req = contract.request(raw_request)
            local raw_object = type(raw_request) == "table" and raw_request :: {[string]: unknown} or nil
            local runtime_provenance = raw_object and raw_object.runtime_provenance ~= nil
                and open_protocol.provenance(raw_object.runtime_provenance) or nil
            if req and req.workspace_id ~= workspace_id then
                local reply = contract.reply(req.request_id, req.op, "workspace_mismatch", "Request targets another workspace")
                reply.id = req.id
                emit(reply)
            elseif req and raw_object and raw_object.runtime_provenance ~= nil and not runtime_provenance then
                emit(contract.reply(req.request_id, req.op, "permission_denied", "Application runtime provenance is invalid"), true)
            elseif req then
                local fingerprint = req.op .. "\0" .. req.id .. "\0" .. req.definition_id .. "\0" .. (req.thread_id or "") .. "\0" .. req.recipient .. "\0" .. req.restore_instance_id .. "\0" .. req.restore_view_id .. "\0" .. req.resume_schema .. "\0" .. tostring(#req.resume_state) .. ":" .. req.resume_state .. contract.argument_fingerprint(req.arguments)
                fingerprint = fingerprint .. "\0" .. req.instance_id
                if runtime_provenance then
                    fingerprint = fingerprint .. "\0runtime\0" .. runtime_provenance.thread_id .. "\0"
                        .. runtime_provenance.subject .. "\0" .. runtime_provenance.binding_id .. "\0"
                        .. runtime_provenance.access_approval_id .. "\0" .. runtime_provenance.access_proposal_digest
                end
                local cached = completed[req.request_id]
                if fingerprints[req.request_id] and fingerprints[req.request_id] ~= fingerprint then
                    emit(contract.reply(req.request_id, "open", "request_conflict", "Request ID was reused for another operation"))
                elseif cached then
                    if cached.op == "open" and cached.error_code == "" then
                        local item = instances[cached.id]
                        if item and item.state.phase == "ready" then emit(identified(item, "focus", req.request_id))
                        else emit(contract.reply(req.request_id, "open", "request_expired", "Original application has stopped")) end
                    else emit(cached) end
                elseif not pending[req.request_id] then
                    pending[req.request_id] = true
                    fingerprints[req.request_id] = fingerprint
                    if req.op == "shutdown" then
                        if cleanup_request == "" then
                            cleanup_request, cleanup_deadline = req.request_id, now() + 3.5
                            shutdown_dialog = nil
                            publish_dialogs()
                            for _, item in pairs(instances) do
                                -- Shutdown owns the logical window. Cancel a
                                -- pending catalog swap before asking its old
                                -- producer to stop, so an EXIT cannot launch
                                -- a replacement while cleanup is in progress.
                                local current: Instance = item :: Instance
                                if settle_exited_replacement(current, false) then
                                    -- Keep a pending checkpoint write: cleanup
                                    -- must drain it, but the dead producer is
                                    -- no longer a live logical instance.
                                else
                                    current.replacement = nil
                                    if current.state.phase == "close_unresponsive" then transition(current, "force_stop")
                                    elseif current.state.phase == "close_requested" or current.state.phase == "close_confirming" then transition(current, "accept_close")
                                    else transition(current, "stop") end
                                end
                            end
                        end
                    elseif req.op == "bind" then
                        if req.id == "" then recipient = req.recipient end
                        local reply = contract.reply(req.request_id, "bind")
                        local function rebind(item: Instance)
                            if req.observer then
                                local result = attachment.observe(item.view, item.observers, req.recipient)
                                local response = identified(item, "attached", req.request_id, result.error_code, result.error)
                                response.mount, response.observer = result.mount, true
                                emit(response)
                                if result.error_code ~= "" then reply.error_code, reply.error = result.error_code, result.error end
                                return
                            end
                            local result = attachment.replace(item.view, item.attachment, item.opened and req.recipient or "")
                            item.attachment = result.attachment
                            if result.error_code == "" then item.client_appearance_revision = nil end
                            if result.error ~= "" then reply.error_code, reply.error = result.error_code, result.error end
                            if result.error_code == "revoke_failed" or (req.recipient ~= "" and item.opened) then
                                local response = identified(item, "attached", req.request_id, result.error_code, result.error)
                                if result.error ~= "" then response.mount = "" end
                                emit(response)
                            end
                            if result.error_code == "" and req.recipient ~= "" and item.opened then
                                local current = appearance.decode({theme = preferences.theme, background = preferences.background, taskbar = preferences.taskbar}) or preferences
                                route_client_appearance(item, "state", "", current)
                            end
                        end
                        if req.id == "" then
                            for _, item in pairs(instances) do rebind(item) end
                        else
                            local item = instances[req.id]
                            reply.id, reply.instance_id = req.id, req.instance_id
                            if not item or item.instance_id ~= req.instance_id then
                                reply.error_code, reply.error = "not_found", "Application view is no longer open"
                            elseif not item.opened then
                                reply.error_code, reply.error = "not_ready", "Application view is not ready"
                            else rebind(item) end
                        end
                        emit(reply, true)
                    elseif req.op == "unbind" then
                        -- Fence future default mounts before revoking the current grants.
                        if recipient == req.recipient then recipient = "" end
                        local reply = contract.reply(req.request_id, "unbind")
                        local function detach(item: Instance)
                            local previous = item.attachment
                            local result = attachment.remove_recipient(item.view, previous, req.recipient)
                            item.attachment = result.attachment
                            if previous ~= result.attachment then item.client_appearance_revision = nil end
                            local removed, observer_error = attachment.remove_observer(item.view, item.observers, req.recipient)
                            if not removed then reply.error_code, reply.error = "revoke_failed", observer_error or "Observer revocation failed" end
                            if result.error ~= "" then
                                reply.error_code, reply.error = result.error_code, result.error
                            end
                        end
                        for _, item in pairs(instances) do detach(item) end
                        emit(reply, true)
                    elseif req.op == "close" then
                        local item = instances[req.id]
                        if item and req.instance_id ~= "" and item.instance_id ~= req.instance_id then
                            emit(contract.reply(req.request_id, "close", "stale_instance", "View belongs to another application instance"), true)
                        elseif item then stop(item, {request_id = req.request_id, recipient = owner, control = false}, false)
                        else emit(contract.reply(req.request_id, "close", "not_found", "View is no longer open"), true) end
                    elseif req.op == "open" and shutdown_plan then
                        emit(contract.reply(req.request_id, "open", "busy", "Quit confirmation pending"), true)
                    elseif req.op == "open" then
                        refresh_admission()
                        local selected_admission = admission.current
                        local binding: contract.Binding? = nil
                        if selected_admission then
                            for _, candidate in ipairs(selected_admission.bindings) do if candidate.definition_id == req.definition_id then binding = candidate; break end end
                        end
                        local descriptor: contract.Descriptor? = selected_admission and binding and selected_admission.descriptors[req.definition_id]
                        local existing: Instance? = nil
                        local count = 0
                        for _, item in pairs(instances) do
                            count = count + 1
                            if descriptor and descriptor.singleton and item.descriptor.definition_id == req.definition_id then existing = item end
                        end
                        if not selected_admission or not binding or not descriptor then
                            emit(contract.reply(req.request_id, "open", "not_admitted", admission.error ~= "" and ("Application admission unavailable: " .. admission.error) or "Application is not admitted"), true)
                        elseif runtime_provenance then
                            local admitted: Admission = selected_admission :: Admission
                            local selected_binding: contract.Binding = binding :: contract.Binding
                            local selected_descriptor: contract.Descriptor = descriptor :: contract.Descriptor
                            local scope = admitted.scopes[req.definition_id]
                            if req.restore_instance_id ~= "" then
                                emit(contract.reply(req.request_id, "open", "permission_denied", "Agent application opens cannot select restored identities"), true)
                            elseif not scope then error("Admitted application scope is unavailable")
                            elseif existing and existing.state.phase ~= "ready" then
                                emit(contract.reply(req.request_id, "open", "busy", "Application is changing state"), true)
                            elseif existing and existing.thread_id ~= nil and existing.thread_id ~= runtime_provenance.thread_id then
                                emit(contract.reply(req.request_id, "open", "thread_conflict", "Singleton application is associated with another thread"), true)
                            elseif not existing and count >= 16 then
                                emit(contract.reply(req.request_id, "open", "instance_limit", "Desktop instance limit reached"), true)
                            else
                                begin_runtime(req, runtime_provenance, selected_descriptor, selected_binding, scope, existing)
                            end
                        elseif existing then
                            if req.thread_id ~= nil and req.thread_id ~= existing.thread_id then
                                emit(contract.reply(req.request_id, "open", "thread_conflict", "Singleton application is associated with another thread"), true)
                            elseif existing.state.phase == "ready" then emit(identified(existing, "focus", req.request_id), true)
                            else emit(contract.reply(req.request_id, "open", "busy", "Application is changing state"), true) end
                        elseif req.restore_instance_id ~= "" and (req.resume_schema ~= descriptor.resume_schema or descriptor.restart_policy == "never") then
                            emit(contract.reply(req.request_id, "open", "incompatible_checkpoint", "Application checkpoint schema is incompatible"), true)
                        elseif req.restore_view_id ~= "" and instances[req.restore_view_id] then
                            emit(contract.reply(req.request_id, "open", "identity_conflict", "View identity is already active"), true)
                        elseif count >= 16 then emit(contract.reply(req.request_id, "open", "instance_limit", "Desktop instance limit reached"), true)
                        else
                            local admitted: Admission = selected_admission :: Admission
                            local selected_binding: contract.Binding = binding :: contract.Binding
                            local selected_descriptor: contract.Descriptor = descriptor :: contract.Descriptor
                            local view_id = req.restore_view_id ~= "" and req.restore_view_id or uuid.v7()
                            local instance_id = req.restore_instance_id ~= "" and req.restore_instance_id or uuid.v7()
                            -- The app reads the thread it was launched for as
                            -- its own principal; admit it before it starts, or
                            -- refuse the open instead of starting an app that
                            -- can never reach its thread.
                            local admitted_member, member_code, member_message = true, nil, nil
                            if req.thread_id then
                                admitted_member, member_code, member_message = admit_principal(req.thread_id, instance_id)
                            end
                            if not admitted_member then
                                emit(contract.reply(req.request_id, "open", member_code or "permission_denied",
                                    member_message or "Application thread membership was not admitted"), true)
                            else
                                local token = uuid.v7()
                                local theme = appearance.theme(preferences.theme)
                                local view, err = tty.viewport({width = 60, height = 16, page = appearance.page(theme, selected_descriptor.role == "terminal")})
                                if not view then emit(contract.reply(req.request_id, "open", "viewport_failed", tostring(err)), true)
                                else
                                    local grant, grant_err = view:grant()
                                    if not grant then view:close(); emit(contract.reply(req.request_id, "open", "grant_failed", tostring(grant_err)), true)
                                    else
                                        local version = assert(registry.current_version())
                                        local scope = admitted.scopes[req.definition_id]
                                        if not scope then error("Admitted application scope is unavailable") end
                                        local launch: execution.Launch = {definition_id = req.definition_id,
                                            scope = scope, workspace_pid = owner, workspace_id = workspace_id,
                                            actor = application_actor(workspace_id, instance_id, req.definition_id,
                                                selected_descriptor.definition_revision, 1),
                                            instance_id = instance_id, view_id = view_id, thread_id = req.thread_id,
                                            execution_generation = 1,
                                            definition_revision = selected_descriptor.definition_revision,
                                            registry_revision = version:string(), launch_token = token, resume_schema = selected_descriptor.resume_schema,
                                            resume_state = req.resume_state, arguments = req.arguments}
                                        local started = execution.start(grant, launch)
                                        if not started.pid then view:close(); emit(contract.reply(req.request_id, "open", started.error_code, started.error), true)
                                        else
                                            local instance: Instance = {view_id = view_id, instance_id = instance_id, thread_id = req.thread_id, execution_pid = started.pid, view = view,
                                                descriptor = selected_descriptor, binding = selected_binding, launch_token = token, observers = {},
                                                state = lifecycle.start(now()), open_request = req.request_id, opened = false,
                                                resume_state = req.resume_state, arguments = req.arguments, replacement = nil,
                                                waiters = {}, attempts = 0, producer_generation = 1}
                                            instances[view_id] = instance
                                            if selected_binding.catalog_read then publish_catalog_readers() end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        if cleanup_request ~= "" and not cleanup_complete then
            local live, writes = false, false
            for _ in pairs(instances) do live = true; break end
            for _ in pairs(checkpoint_waiters) do writes = true; break end
            if not live and not writes then
                cleanup_complete = true
                emit(contract.reply(cleanup_request, "shutdown"), true)
            elseif now() >= cleanup_deadline then
                cleanup_complete = true
                emit(contract.reply(cleanup_request, "shutdown", "cleanup_incomplete",
                    "Workspace cleanup timed out; some process exits or writes remain unacknowledged"), true)
            end
        end
    end
    ticker:stop()
    -- Owner loss is the emergency path; normal shutdown has already cooperated.
    for _, item in pairs(instances) do process.terminate(item.execution_pid); item.view:close() end
    process.unlisten(shutdown_requests)
    process.unlisten(close_replies)
    process.unlisten(queries); process.unlisten(answers)
    process.unlisten(titles)
    process.unlisten(requests); process.unlisten(app_ready); process.unlisten(appearance_requests)
    process.unlisten(appearance_states); process.unlisten(controls)
    process.unlisten(checkpoints); process.unlisten(persisted)
    process.unlisten(binding_results); process.unlisten(binding_recovery)
    process.unlisten(thread_requests)
end
return {main = main}
