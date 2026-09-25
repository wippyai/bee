-- MIT. Stable workspace owner; no physical terminal, session or presenter.
local process = require("process")
local channel = require("channel")
local security = require("security")
local ctx = require("ctx")
local uuid = require("uuid")
local hash = require("hash")
local time = require("time")
local persistence = require("persistence")
local recovery = require("recovery")
local contract = require("contract")
local decode = require("decode")
local model = require("model")
local appearance = require("appearance")
local interaction = require("interaction")
local connections = require("connections")
local inventory = require("inventory")
local transfer = require("transfer")
local open_protocol = require("open_protocol")
local binding_protocol = require("binding_protocol")
local execution = require("execution")

-- The broker gives its applications 8 s to stop what they own before it
-- terminates them; its own stop outlasts that.
local BROKER_STOP_GRACE = "10s"

-- The owner selects which catalog workspace this host serves; the host never
-- infers it from the database it opens.
local function main(owner: string, workspace: unknown, database_resource: string?)
    if owner == "" or ctx.get("bee.host_owner") ~= owner then error("Untrusted host bootstrap") end
    local requests = assert(process.listen("bee.app.request", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local catalogs = assert(process.listen("bee.application.catalog", {message = true}))
    local checkpoints = assert(process.listen("bee.application.checkpoint", {message = true}))
    local questions = assert(process.listen("bee.interaction.state", {message = true}))
    local answers = assert(process.listen("bee.interaction.response", {message = true}))
    local preferences = assert(process.listen("bee.appearance.request", {message = true}))
    local shutdown_requests = assert(process.listen("bee.application.shutdown", {message = true}))
    local client_requests = assert(process.listen("bee.host.client", {message = true}))
    local selections = assert(process.listen("bee.host.selection", {message = true}))
    local client_answers = assert(process.listen("bee.host.answer", {message = true}))
    local appearance_changes = assert(process.listen("bee.client.appearance.changed", {message = true}))
    local client_appearance = assert(process.listen("bee.client.appearance.result", {message = true}))
    local transfer_requests = assert(process.listen("bee.host.transfer", {message = true}))
    local open_requests = assert(process.listen("bee.host.application", {message = true}))
    local broker_ready = assert(process.listen("bee.app.ready", {message = true}))
    local binding_requests = assert(process.listen("bee.application.binding.request", {message = true}))
    local binding_recovered = assert(process.listen("bee.application.binding.recovered", {message = true}))
    local events = assert(process.events())
    assert(process.monitor(owner))
    local database, database_error = persistence.open(database_resource, workspace)
    if not database then error(tostring(database_error)) end
    local host_registry_name = ""
    -- Recovery must observe every durable prepared fence before any admission
    -- can issue a controlling bind. Unresolved intents stay fenced for the
    -- supervisor/client reconciliation path; they are never silently failed.
    local recovered, recovery_error = database.assignments:reconcile()
    if not recovered then database:close(); error("Reconcile display assignments: " .. tostring(recovery_error)) end
    -- Only transfers that were already prepared when this host started can be
    -- reconciled from a later manual restore. A runtime prepare still needs its
    -- broker revoke reply before it is eligible to commit.
    local recovered_prepared: {[string]: string} = {}
    local function assignment_key(view_id: string, instance_id: string): string
        return view_id .. "\0" .. instance_id
    end
    for _, recovered_entry in ipairs(recovered) do
        if recovered_entry.intent then
            recovered_prepared[assignment_key(recovered_entry.intent.view_id, recovered_entry.intent.instance_id)] = recovered_entry.intent.request_id
        end
    end
    local fresh_workspace = database.saved == nil
    local workspace_id = database.workspace_id
    host_registry_name = "bee.workspace.host/" .. workspace_id
    local registered, register_error = process.registry.register(host_registry_name)
    if not registered then database:close(); error("Register workspace host: " .. tostring(register_error)) end
    local empty_tabs: {string} = {}
    local empty_records: {recovery.Record} = {}
    local snapshot: recovery.Snapshot = {version = 1,
        desktop = {scene = model.new(80, 24), tabs = empty_tabs, preferences = appearance.defaults()}, applications = empty_records}
    if database.saved then snapshot = database.saved end
    -- A durable revoke is the logical close fence. The host may crash after
    -- committing it and before the broker removes the older application
    -- checkpoint. Reconcile that checkpoint before starting a broker so the
    -- revoked instance cannot be restored with a fresh execution.
    local retained_records: {recovery.Record} = {}
    local fenced = false
    for _, record in ipairs(snapshot.applications) do
        local app_binding, binding_error = database.thread_bindings:get(record.instance_id)
        if binding_error then database:close(); error("Read checkpoint application binding: " .. tostring(binding_error)) end
        if app_binding and (app_binding.thread_id ~= record.thread_id
            or app_binding.definition_id ~= record.definition_id) then
            database:close(); error("Checkpoint application binding identity is corrupt")
        end
        if app_binding and app_binding.state == "revoked" then fenced = true
        else retained_records[#retained_records + 1] = record end
    end
    if fenced then
        local reconciled: recovery.Snapshot = {version = 1, desktop = snapshot.desktop, applications = retained_records}
        local committed, commit_error = database:write(reconciled)
        if not committed then database:close(); error("Fence revoked application checkpoint: " .. tostring(commit_error)) end
        snapshot = reconciled
    end
    local live_inventory = inventory.new(workspace_id)
    local broker_policy, broker_error = security.policy("bee.security.desktop:broker_policy")
    if not broker_policy then database:close(); error(tostring(broker_error)) end
    local boundary, boundary_error = security.policy("bee.security:core_spawn_boundary")
    if not boundary then database:close(); error(tostring(boundary_error)) end
    local self = tostring(process.pid())
    local broker = tostring(assert(process.with_options({}):with_context({
        ["bee.workspace_owner"] = self, ["bee.workspace_id"] = workspace_id,
    }):with_scope(security.new_scope({broker_policy, boundary})):spawn_monitored(
        "bee.applications:broker", "bee:workers", self, snapshot.desktop.preferences)))
    local broker_started = false
    local broker_recovery_requested = false
    local restoring = ""
    local restore_queue: {recovery.Record} = {}
    for _, record in ipairs(snapshot.applications) do
        if record.restart_policy == "automatic" then restore_queue[#restore_queue + 1] = record end
    end
    local ready = false
    local stopping = false
    local fatal: string? = nil
    local broker_exited = false
    local client_connections = connections.new(owner, broker, workspace_id, connections.assignment_access(
        function(value: unknown) return database.assignments:get(value) end,
        function() return database.assignments:reconcile() end,
        function(value: unknown) return database.assignments:claim(value) end
    ))
    -- Keys are internal broker request IDs, never caller receipt IDs.  This
    -- keeps transfer replies out of the ordinary client-route namespace.
    local pending_transfers: {[string]: {request: transfer.Request, source: string, caller: string, receipt: string}} = {}
    type OpenWaiters = {callers: {string}, definition_id: string, arguments_fingerprint: string, expires: number?, display_id: string?}
    local pending_opens: {[string]: OpenWaiters} = {}
    local MAX_OPEN_WAITERS = 16
    local MAX_PENDING_OPENS = 64
    local function deliver(topic: string, value: unknown)
        assert(process.send(owner, topic, value))
    end
    local function send(topic: string, value: unknown)
        local sent, err = process.send(broker, topic, value)
        if not sent then error("Core delivery failed: " .. topic .. ": " .. tostring(err)) end
    end
    local function transfer_result(caller: string, request: transfer.Request, assignment_revision: integer, code: string, error_text: string)
        process.send(caller, "bee.host.transfer_result", {version = 1, workspace_id = workspace_id,
            connection_id = request.connection_id, request_id = request.request_id, view_id = request.view_id,
            instance_id = request.instance_id, target_display_id = request.target_display_id,
            assignment_revision = assignment_revision, error_code = code, error = error_text})
    end
    local function resolve_prepared_intents()
        -- A restarted broker has no surviving mount grants.  An automatically
        -- restored exact identity can therefore settle to its persisted target
        -- before client admission.  A checkpointed manual identity remains
        -- fenced until it is restored; its absence from the current inventory
        -- does not prove it dead.  Identities absent from the checkpoint are
        -- proven lost with this host and can be retired after their receipt is
        -- settled, while the receipt itself remains durable.
        for _, recovered_entry in ipairs(recovered) do
            local intent = recovered_entry.intent
            local assignment = recovered_entry.assignment
            local live = false
            for _, item in ipairs(live_inventory.views) do
                if item.view_id == assignment.view_id and item.instance_id == assignment.instance_id then live = true; break end
            end
            if intent and live then
                local committed, commit_error = database.assignments:commit({request_id = intent.request_id,
                    view_id = intent.view_id, instance_id = intent.instance_id})
                if not committed then error("Resolve restored display transfer: " .. tostring(commit_error)) end
                recovered_prepared[assignment_key(intent.view_id, intent.instance_id)] = nil
            elseif not live then
                local checkpointed = false
                for _, record in ipairs(snapshot.applications) do
                    if record.id == assignment.view_id and record.instance_id == assignment.instance_id then checkpointed = true; break end
                end
                if not checkpointed then
                    if intent then
                        local failed, fail_error = database.assignments:fail({request_id = intent.request_id,
                            view_id = intent.view_id, instance_id = intent.instance_id, error = "Application was lost during host restart"})
                        if not failed then error("Resolve lost display transfer: " .. tostring(fail_error)) end
                        recovered_prepared[assignment_key(intent.view_id, intent.instance_id)] = nil
                    end
                    local retired, retire_error = database.assignments:retire({view_id = assignment.view_id, instance_id = assignment.instance_id})
                    if not retired then error("Retire lost display assignment: " .. tostring(retire_error)) end
                end
            end
        end
    end
    local function settle_opened_intent(reply: decode.Reply): boolean
        -- A manual checkpoint is intentionally absent during startup recovery.
        -- Once its exact restored identity becomes live, its prepared transfer
        -- can settle to the persisted target before any routed bind is allowed.
        if reply.op ~= "open" or reply.error_code ~= "" then return false end
        local key = assignment_key(reply.id, reply.instance_id)
        local recovered_receipt = recovered_prepared[key]
        if not recovered_receipt then return false end
        local present = false
        for _, item in ipairs(live_inventory.views) do
            if item.view_id == reply.id and item.instance_id == reply.instance_id then present = true; break end
        end
        if not present then return false end
        local assigned, assignment_error = database.assignments:get({view_id = reply.id, instance_id = reply.instance_id})
        if assignment_error then error("Read opened display assignment: " .. tostring(assignment_error)) end
        if not assigned or not assigned.intent then return false end
        local intent = assigned.intent
        if intent.request_id ~= recovered_receipt or intent.view_id ~= reply.id or intent.instance_id ~= reply.instance_id then
            error("Opened display transfer identity is corrupt")
        end
        local committed, commit_error = database.assignments:commit({request_id = intent.request_id,
            view_id = reply.id, instance_id = reply.instance_id})
        if not committed then error("Resolve opened display transfer: " .. tostring(commit_error)) end
        recovered_prepared[key] = nil
        return true
    end
    local function restore_next()
        if restoring ~= "" or stopping then return end
        -- Installed overlays may become available after the first catalog.
        -- Keep their saved records pending without delaying other applications.
        local selected: integer? = nil
        for index, candidate in ipairs(restore_queue) do
            for _, descriptor in ipairs(live_inventory.catalog) do
                if descriptor.definition_id == candidate.definition_id then selected = index; break end
            end
            if selected then break end
        end
        local record = selected and table.remove(restore_queue, selected) or nil
        if record then
            restoring = uuid.v7()
            send("bee.app.request", {version = 1, request_id = restoring, op = "open", workspace_id = workspace_id,
                definition_id = record.definition_id, thread_id = record.thread_id, restore_instance_id = record.instance_id,
                restore_view_id = record.id, resume_schema = record.resume_schema, resume_state = record.resume_state})
        else
            if not ready and broker_started then
                resolve_prepared_intents()
                ready = true
                deliver("bee.host.ready", {version = 1, workspace_id = workspace_id, fresh = fresh_workspace, saved = snapshot})
            end
        end
    end
    local function replace_record(record: recovery.Record?, removed: string?): (boolean, string?)
        local records: {recovery.Record} = {}
        local found = false
        for _, previous in ipairs(snapshot.applications) do
            if record and previous.instance_id == record.instance_id and previous.id ~= record.id then
                return false, "Checkpoint duplicates a saved application instance"
            end
            if record and previous.id == record.id then
                record.window = previous.window
                records[#records + 1] = record
                found = true
            elseif previous.id ~= removed then records[#records + 1] = previous end
        end
        if record and not found then records[#records + 1] = record end
        if #records > 16 then return false, "Workspace checkpoint capacity reached" end
        local next: recovery.Snapshot = {version = 1, desktop = snapshot.desktop, applications = records}
        local committed, err = database:write(next)
        if committed then snapshot = next end
        return committed, err
    end
    local open_timer: time.Timer? = nil
    local function binding_failure(request: binding_protocol.Request)
        -- Storage errors are deliberately not forwarded as an authority or
        -- database diagnostic. The coordinator receives a stable typed fault
        -- and can continue its own recovery path.
        local reply = assert(binding_protocol.failure(request, "storage_failed", "Workspace binding operation failed"))
        assert(process.send(broker, "bee.application.binding.result", reply))
    end
    local function binding_request(request: binding_protocol.Request)
        local value, operation_error
        if request.op == "prepare" then
            value, operation_error = database.thread_bindings:prepare(request.value)
        elseif request.op == "activate" then
            value, operation_error = database.thread_bindings:activate(request.value)
        elseif request.op == "refresh_join" then
            value, operation_error = database.thread_bindings:refresh_join(request.value)
        elseif request.op == "begin_revoke" then
            value, operation_error = database.thread_bindings:begin_revoke(request.value)
        elseif request.op == "refresh_cleanup" then
            value, operation_error = database.thread_bindings:refresh_cleanup(request.value)
        else
            value, operation_error = database.thread_bindings:finish_revoke(request.value)
        end
        if not value or operation_error then
            binding_failure(request)
            return
        end
        local reply = binding_protocol.success(request, value)
        if not reply then error("Workspace binding store returned an invalid binding") end
        assert(process.send(broker, "bee.application.binding.result", reply))
    end
    local function run()
        while true do
            local cases = {requests:case_receive(), open_requests:case_receive(), replies:case_receive(), catalogs:case_receive(),
                checkpoints:case_receive(), questions:case_receive(), answers:case_receive(), preferences:case_receive(), shutdown_requests:case_receive(), client_requests:case_receive(), transfer_requests:case_receive(),
                selections:case_receive(), client_answers:case_receive(), appearance_changes:case_receive(), client_appearance:case_receive(), broker_ready:case_receive(), binding_requests:case_receive(), binding_recovered:case_receive(), events:case_receive()}
            local next_expiry: number? = nil
            for _, pending in pairs(pending_opens) do
                if pending.expires and (not next_expiry or pending.expires < next_expiry) then next_expiry = pending.expires end
            end
            if next_expiry then
                local delay = math.max(1, math.ceil(next_expiry * 1000 - time.now():unix_nano() / 1000000))
                open_timer = assert(time.timer(tostring(delay) .. "ms"))
                cases[#cases + 1] = open_timer:channel():case_receive()
            end
            local selected = channel.select(cases)
            local expired = open_timer and selected.channel == open_timer:channel()
            if open_timer then open_timer:stop(); open_timer = nil end
            if not selected.ok then break end
            if expired then
                local now = time.now():unix_nano() / 1000000000
                for request_id, pending in pairs(pending_opens) do
                    if pending.expires and now >= pending.expires then
                        -- Keep the bounded in-flight record until the broker
                        -- settles, so a late success can still claim the
                        -- originating display assignment. Its slot remains
                        -- charged as backpressure; no retry is issued.
                        local reply = contract.reply(request_id, "open", "uncertain", "Application open outcome is unknown")
                        reply.workspace_id = workspace_id
                        for _, caller in ipairs(pending.callers) do
                            process.send(caller, "bee.host.application.reply", {version = 1, workspace_id = workspace_id,
                                request_id = request_id, reply = reply})
                        end
                        local released: {string} = {}
                        pending.callers = released
                        pending.expires = nil
                    end
                end
            elseif selected.channel == events then
                local event = selected.value
                if event.kind == process.event.CANCEL then break end
                if event.kind == process.event.EXIT and tostring(event.from) == broker then
                    broker_exited = true
                    fatal = "Workspace broker exited: " .. (decode.exit_error(event.result) or "without completing cleanup"); break
                end
                if event.kind == process.event.EXIT and tostring(event.from) == owner then break end
                if event.kind == process.event.EXIT then
                    connections.exited(client_connections, tostring(event.from))
                end
            else
                local message = selected.value
                local data: unknown = message:payload():data()
                if selected.channel == catalogs and message:from() == broker then
                    if type(data) == "table" and data.version == 1 then
                        local next_inventory = inventory.set_catalog(live_inventory, data.items)
                        if not next_inventory then error("Invalid broker catalog") end
                        live_inventory = next_inventory
                        deliver("bee.application.catalog", data)
                        if ready then connections.publish(client_connections, live_inventory, "catalog") end
                        restore_next()
                    end
                elseif selected.channel == broker_ready and message:from() == broker and not broker_recovery_requested
                    and type(data) == "table" and data.version == 1 then
                    local bindings, binding_error = database.thread_bindings:list()
                    if not bindings then error("List application thread bindings: " .. tostring(binding_error)) end
                    local recovered = binding_protocol.recovery({version = 1, workspace_id = workspace_id, items = bindings}, workspace_id)
                    if not recovered then error("Workspace application thread binding recovery is invalid") end
                    assert(process.send(broker, "bee.application.binding.recovery", recovered))
                    broker_recovery_requested = true
                elseif selected.channel == binding_recovered and message:from() == broker and broker_recovery_requested and not broker_started then
                    if binding_protocol.recovered(data, workspace_id) then
                        broker_started = true
                        restore_next()
                    end
                elseif selected.channel == binding_requests and message:from() == broker then
                    local request = binding_protocol.request(data, workspace_id)
                    if request then binding_request(request) end
                elseif selected.channel == client_requests then
                    local joined = connections.control(client_connections, tostring(message:from()), data, ready and not stopping)
                    if joined then
                        connections.publish(client_connections, live_inventory, "catalog", joined)
                        connections.publish(client_connections, live_inventory, "views", joined)
                    end
                elseif selected.channel == transfer_requests then
                    local caller = tostring(message:from())
                    local request, source, rejected = connections.transfer(client_connections, caller, data, ready and not stopping)
                    local code, error_text = rejected or "", ""
                    if request and source and code == "" then
                        local receipt, receipt_error = hash.sha256(source.display_id .. "\0" .. request.request_id)
                        if not receipt then code, error_text = "internal", tostring(receipt_error) end
                        local existing, existing_error = nil, nil
                        if receipt then existing, existing_error = database.assignments:receipt(receipt) end
                        if not existing and existing_error then code, error_text = "internal", tostring(existing_error) end
                        -- Admission and assignment validation is required before
                        -- creating an intent, but a historical receipt replays
                        -- without depending on a later display lifetime.
                        if code == "" and not existing then
                            local readiness = connections.transfer_ready(client_connections, request, source)
                            if readiness then code, error_text = readiness, "Transfer source or destination is unavailable" end
                        end
                        if code == "" then
                            local prepared, prepare_error = database.assignments:prepare({request_id = receipt,
                                view_id = request.view_id, instance_id = request.instance_id, source_display_id = source.display_id,
                                target_display_id = request.target_display_id, expected_revision = request.expected_revision})
                            if not prepared then code, error_text = "conflict", tostring(prepare_error)
                            elseif prepared.phase == "committed" then
                                -- A receipt reports its own settled outcome,
                                -- even if later transfers moved or retired the
                                -- live assignment.
                                transfer_result(caller, request, prepared.expected_revision + 1, "", "")
                            elseif prepared.phase == "failed" then
                                transfer_result(caller, request, prepared.expected_revision, "failed", prepared.error or "Transfer failed")
                            else
                                local broker_request = "transfer-" .. receipt:sub(1, 64)
                                if not pending_transfers[broker_request] then
                                    pending_transfers[broker_request] = {request = request, source = source.display_id, caller = caller, receipt = receipt}
                                    connections.assignments(client_connections)
                                    send("bee.app.request", {version = 1, request_id = broker_request, op = "bind", workspace_id = workspace_id,
                                        id = request.view_id, instance_id = request.instance_id, recipient = ""})
                                end
                            end
                        end
                    end
                    if request and code ~= "" then transfer_result(caller, request, 0, code, error_text) end
                elseif selected.channel == open_requests then
                    local caller = tostring(message:from())
                    local request = open_protocol.request(data, workspace_id)
                    if request then
                        local function send_open(recipient: string, reply: contract.Reply)
                            reply.workspace_id = workspace_id
                            process.send(recipient, "bee.host.application.reply", {version = 1, workspace_id = workspace_id,
                                request_id = request.request_id, reply = reply})
                        end
                        -- The workspace ID and request body are routing data,
                        -- not caller authority.  The facade registers a
                        -- request-scoped LOCAL name under its own policy and
                        -- includes that name here; native message:from() must
                        -- resolve to the same execution before any broker
                        -- request is admitted.
                        local registered_caller = process.registry.lookup(request.caller_token)
                        local display_id: string? = nil
                        local origin_error: string? = nil
                        if registered_caller and tostring(registered_caller) == caller and request.origin_view then
                            local origin = request.origin_view
                            local live = false
                            for _, view in ipairs(live_inventory.views) do
                                if view.view_id == origin.view_id and view.instance_id == origin.instance_id then live = true; break end
                            end
                            local assigned, assignment_error = database.assignments:get(origin)
                            if not live or not assigned or assigned.intent then
                                origin_error = assignment_error or "Origin view has no settled display assignment"
                            else display_id = assigned.assignment.display_id end
                        end
                        if not registered_caller or tostring(registered_caller) ~= caller then
                            send_open(caller, contract.reply(request.request_id, "open", "permission_denied", "Open caller is not admitted to this workspace host"))
                        elseif origin_error then
                            send_open(caller, contract.reply(request.request_id, "open", "unavailable", origin_error))
                        elseif not ready or stopping then
                            send_open(caller, contract.reply(request.request_id, "open", "unavailable", "Workspace host is not ready"))
                        elseif pending_opens[request.request_id] then
                            -- The original broker request owns the reply. A
                            -- duplicate caller waits for that exact result.
                            local waiters = pending_opens[request.request_id]
                            local fingerprint = contract.argument_fingerprint(request.arguments)
                            if waiters.definition_id ~= request.definition_id or waiters.arguments_fingerprint ~= fingerprint then
                                send_open(caller, contract.reply(request.request_id, "open", "request_conflict", "Request ID was reused for another application"))
                            elseif not waiters.expires then
                                send_open(caller, contract.reply(request.request_id, "open", "uncertain", "Application open outcome is unknown"))
                            elseif #waiters.callers >= MAX_OPEN_WAITERS then
                                send_open(caller, contract.reply(request.request_id, "open", "busy", "Too many callers are waiting for this open"))
                            else
                                waiters.callers[#waiters.callers + 1] = caller
                            end
                        else
                            local pending_count = 0
                            for _ in pairs(pending_opens) do pending_count = pending_count + 1 end
                            if pending_count >= MAX_PENDING_OPENS then
                                send_open(caller, contract.reply(request.request_id, "open", "busy", "Too many pending application opens"))
                            else
                                pending_opens[request.request_id] = {callers = {caller}, definition_id = request.definition_id,
                                    arguments_fingerprint = contract.argument_fingerprint(request.arguments),
                                    expires = time.now():unix_nano() / 1000000000 + 30, display_id = display_id}
                                local sent, send_error = process.send(broker, "bee.app.request", {version = 1, request_id = request.request_id, op = "open",
                                    workspace_id = workspace_id, id = "", instance_id = "", definition_id = request.definition_id,
                                    thread_id = request.provenance.thread_id, runtime_provenance = request.provenance,
                                    recipient = "", restore_instance_id = "", restore_view_id = "", resume_schema = "",
                                    resume_state = "", arguments = request.arguments})
                                if not sent then
                                    pending_opens[request.request_id] = nil
                                    send_open(caller, contract.reply(request.request_id, "open", "unavailable", tostring(send_error or "Workspace broker rejected request")))
                                end
                            end
                        end
                    end
                elseif selected.channel == requests then
                    local request = contract.request(data)
                    local caller = tostring(message:from())
                    if request and not connections.request(client_connections, caller, request, data, ready and not stopping, snapshot.applications) and caller == owner then
                        if request.workspace_id ~= workspace_id or not ready or stopping then
                            local reply = contract.reply(request.request_id, request.op,
                                request.workspace_id ~= workspace_id and "workspace_mismatch" or "busy", "Workspace request unavailable")
                            reply.workspace_id = workspace_id
                            deliver("bee.app.reply", reply)
                        else
                            if request.op == "shutdown" then stopping = true end
                            send("bee.app.request", data)
                        end
                    end
                elseif selected.channel == checkpoints and message:from() == broker then
                    local record = recovery.record(data)
                    if type(data) == "table" and data.version == 1 and data.workspace_id == workspace_id
                        and contract.text(data.request_id, 80) and record then
                        local committed, err = replace_record(record)
                        send("bee.application.persisted", {version = 1, request_id = data.request_id,
                            error_code = committed and "" or "persistence_failed", error = err or ""})
                        if committed then deliver("bee.host.checkpoint", {version = 1, workspace_id = workspace_id, record = record}) end
                    end
                elseif selected.channel == replies and message:from() == broker then
                    local reply = decode.reply(data)
                    if reply and decode.belongs(reply, workspace_id) then
                        local open_waiters = pending_opens[reply.request_id]
                        if open_waiters then
                            pending_opens[reply.request_id] = nil
                        end
                        local pending_transfer = pending_transfers[reply.request_id]
                        if pending_transfer then
                            -- A broker bind can emit an intermediate attachment
                            -- report before its final bind reply.  Both are
                            -- private transfer protocol traffic; neither may
                            -- become an ordinary client route.
                            if reply.op ~= "bind" then
                                -- Keep waiting for the final revocation result.
                            else
                                pending_transfers[reply.request_id] = nil
                                local request = pending_transfer.request
                                local outcome, outcome_error
                                local code, error_text, assignment_revision = reply.error_code, reply.error, 0
                                if reply.error_code == "" then
                                    outcome, outcome_error = database.assignments:commit({request_id = pending_transfer.receipt,
                                        view_id = request.view_id, instance_id = request.instance_id})
                                    if outcome and outcome.assignment then assignment_revision = outcome.assignment.revision
                                    else code, error_text = "persistence_failed", tostring(outcome_error) end
                                elseif reply.error_code == "revoke_failed" then
                                    -- attachment.replace documents this code as
                                    -- retaining the old mount, so it is safe to
                                    -- settle the intent back to the source.
                                    outcome, outcome_error = database.assignments:fail({request_id = pending_transfer.receipt,
                                        view_id = request.view_id, instance_id = request.instance_id, error = reply.error})
                                    if not outcome then code, error_text = "persistence_failed", tostring(outcome_error) end
                                else
                                    -- Do not guess that an arbitrary broker
                                    -- error left the source mount intact.  The
                                    -- prepared durable fence remains for later
                                    -- reconciliation.
                                    code = "uncertain"
                                    error_text = reply.error ~= "" and reply.error or "Transfer revoke outcome is uncertain"
                                end
                                if outcome then connections.assignments(client_connections) end
                                transfer_result(pending_transfer.caller, request, assignment_revision, code, error_text)
                            end
                        else
                            local preserved_record: recovery.Record? = nil
                            if not stopping and reply.op == "closed" and reply.error_code == "application_failed" then
                                for _, saved in ipairs(snapshot.applications) do
                                    if saved.id == reply.id and saved.instance_id == reply.instance_id
                                        and saved.restart_policy == "automatic" then
                                        preserved_record = saved
                                    end
                                    if preserved_record then break end
                                end
                            end
                            local next_inventory = inventory.observe(live_inventory, reply)
                            if not preserved_record and not stopping
                                and ((reply.op == "close" and reply.error == "") or reply.op == "closed") then
                                local committed, err = replace_record(nil, reply.id)
                                if not committed then error("Workspace save failed: " .. tostring(err)) end
                            end
                            -- A broker closed reply is the only live-process
                            -- proof used to retire an exact assignment.  Keep
                            -- unresolved prepared fences for recovery, and
                            -- retain every receipt regardless of retirement.
                            if reply.op == "closed" and not preserved_record then
                                local assigned, assignment_error = database.assignments:get({view_id = reply.id, instance_id = reply.instance_id})
                                if assignment_error then error("Read closed display assignment: " .. tostring(assignment_error)) end
                                if assigned and not assigned.intent then
                                    local retired, retire_error = database.assignments:retire({view_id = reply.id, instance_id = reply.instance_id})
                                    if not retired then error("Retire closed display assignment: " .. tostring(retire_error)) end
                                    connections.assignments(client_connections)
                                end
                            end
                            if next_inventory then
                                live_inventory = next_inventory
                                if settle_opened_intent(reply) and ready then connections.assignments(client_connections) end
                                if ready then connections.publish(client_connections, live_inventory, "views") end
                            end
                            if open_waiters then
                                reply.workspace_id = workspace_id
                                local assigned_display: string? = nil
                                if reply.error_code == "" and open_waiters.display_id then
                                    local existing, assignment_error = database.assignments:get({view_id = reply.id, instance_id = reply.instance_id})
                                    if existing then
                                        -- A replay must not undo a later display transfer.
                                        assigned_display = existing.assignment.display_id
                                    elseif not assignment_error then
                                        local claimed, claim_error = database.assignments:claim({view_id = reply.id,
                                            instance_id = reply.instance_id, display_id = open_waiters.display_id})
                                        if claimed then
                                            assigned_display = claimed.display_id
                                            connections.assignments(client_connections)
                                        else assignment_error = claim_error or "Display assignment failed" end
                                    end
                                    if assignment_error then reply.error_code, reply.error = "persistence_failed", assignment_error end
                                end
                                for _, open_caller in ipairs(open_waiters.callers) do
                                    process.send(open_caller, "bee.host.application.reply", {version = 1, workspace_id = workspace_id,
                                        request_id = reply.request_id, reply = reply, display_id = assigned_display})
                                end
                            end
                            if not open_waiters and not connections.reply(client_connections, reply, live_inventory) then
                                if restoring ~= "" and reply.request_id == restoring and reply.op == "open" then
                                    deliver("bee.host.restore_result", reply)
                                    restoring = ""
                                    restore_next()
                                else deliver("bee.app.reply", reply) end
                            end
                            if stopping and reply.op == "shutdown" then break end
                        end
                    end
                elseif selected.channel == questions and message:from() == broker then
                    connections.questions(client_connections, data)
                    deliver("bee.interaction.state", data)
                elseif selected.channel == selections then
                    connections.selection(client_connections, tostring(message:from()), data)
                elseif selected.channel == client_answers then
                    connections.answer(client_connections, tostring(message:from()), data)
                elseif selected.channel == appearance_changes then
                    connections.appearance_changed(client_connections, tostring(message:from()), data)
                elseif selected.channel == client_appearance then
                    connections.appearance_result(client_connections, tostring(message:from()), data)
                elseif selected.channel == answers and message:from() == owner then
                    local response = interaction.response(data)
                    if response then send("bee.interaction.response", data) end
                elseif selected.channel == shutdown_requests and message:from() == owner then
                    if ready and not stopping and type(data) == "table" and data.version == 1 and data.op == "prepare" then
                        local sent, err = process.send(broker, "bee.application.shutdown", {version = 1, op = "prepare"})
                        if not sent then
                            local reply = contract.reply("", "quit", "delivery_failed", tostring(err))
                            reply.workspace_id = workspace_id
                            deliver("bee.app.reply", reply)
                        end
                    end
                elseif selected.channel == preferences and message:from() == broker then
                    connections.appearance(client_connections, tostring(message:from()), data, ready and not stopping)
                end
            end
        end
    end
    local completed, run_error = pcall(run)
    if open_timer then open_timer:stop() end
    pending_opens = {}
    database:close()
    process.registry.unregister(host_registry_name)
    -- A cancelled broker runs its application cleanup before it exits.
    if not broker_exited then execution.stop({broker}, events, BROKER_STOP_GRACE) end
    for _, subscription in ipairs({requests, open_requests, replies, catalogs, checkpoints, questions, answers, preferences, shutdown_requests, client_requests, transfer_requests, selections, client_answers, appearance_changes, client_appearance, broker_ready, binding_requests, binding_recovered}) do
        process.unlisten(subscription)
    end
    if not completed then error(run_error) end
    if fatal then error(fatal) end
end

return {main = main}
