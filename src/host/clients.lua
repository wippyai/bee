-- MIT. Host-owned client admissions, request correlation and renderer grants.
-- Runs in the host actor; database and application lifecycle remain with it.
local process = require("process")
local uuid = require("uuid")
local hash = require("hash")
local clients = require("clients")
local contract = require("contract")
local inventory = require("inventory")
local questions = require("questions")
local interaction = require("interaction")
local recovery = require("recovery")
local records = require("records")
local transfer = require("transfer")
type Route = {recipient: string, connection_id: string, request_id: string, op: contract.RequestOp, completed: boolean,
    renderer_generation: string, fingerprint: string, resume: recovery.Resume?, display_id: string}
type ChangeOp = "render" | "detach"
type Change = {op: ChangeOp, recipient: string, connection_id: string, request_id: string, renderer: string}
type AppearanceOp = "state" | "set" | "inherit"
type AppearanceRoute = {request_id: string, action: AppearanceOp, recipient: string, connection_id: string,
    renderer: string, renderer_generation: string, theme: string, background: string, taskbar: string}
type Assignment = {view_id: string, instance_id: string, display_id: string, revision: integer}
type AssignmentResult = {assignment: Assignment, intent: unknown?}
type AssignmentEntries = {AssignmentResult}
-- The client router runs inside the host actor. It may read assignment fences
-- and claim the initial display for a newly opened identity; all persistence
-- remains host-owned, so tests can provide a narrow fail-on-use adapter.
type Assignments = {
    get: (Assignments, unknown) -> (AssignmentResult?, string?),
    reconcile: (Assignments) -> (AssignmentEntries?, string?),
    claim: (Assignments, unknown) -> (Assignment?, string?),
}
type State = {owner: string, broker: string, workspace_id: string, self: string,
    assignments: Assignments,
    inventory: inventory.State,
    questions: questions.State,
    admitted: {[string]: clients.Client}, count: integer, routes: {[string]: Route}, route_count: integer,
    completed: {string}, changes: {[string]: Change}, queued_detaches: {[string]: string},
    appearance_routes: {[string]: AppearanceRoute}, assignment_revision: integer}
local M = {}
function M.new(owner: string, broker: string, workspace_id: string, assignments: Assignments): State
    return {owner = owner, broker = broker, workspace_id = workspace_id, self = tostring(process.pid()), assignments = assignments,
        inventory = inventory.new(workspace_id),
        questions = questions.new(workspace_id),
        admitted = {}, count = 0, routes = {}, route_count = 0, completed = {}, changes = {}, queued_detaches = {},
        appearance_routes = {}, assignment_revision = 0}
end
function M.assignment_access(
    get: (unknown) -> (AssignmentResult?, string?),
    reconcile: () -> (AssignmentEntries?, string?),
    claim: (unknown) -> (Assignment?, string?)
): Assignments
    return {
        get = function(_: Assignments, value: unknown): (AssignmentResult?, string?) return get(value) end,
        reconcile = function(_: Assignments): (AssignmentEntries?, string?) return reconcile() end,
        claim = function(_: Assignments, value: unknown): (Assignment?, string?) return claim(value) end,
    }
end
function M.assignments(state: State)
    local entries, read_error = state.assignments:reconcile()
    if read_error or not entries then error("Reconcile display assignments: " .. tostring(read_error)) end
    state.assignment_revision = state.assignment_revision + 1
    for _, client in pairs(state.admitted) do
        local items: {unknown}, displays: {unknown} = {}, {}
        for _, entry in ipairs(entries) do items[#items + 1] = {view_id = entry.assignment.view_id, instance_id = entry.assignment.instance_id,
            display_id = entry.assignment.display_id, revision = entry.assignment.revision, pending = entry.intent ~= nil} end
        for _, candidate in pairs(state.admitted) do displays[#displays + 1] = {display_id = candidate.display_id,
            available = not candidate.detaching and candidate.renderer ~= "", control = candidate.permissions.control} end
        process.send(client.recipient, "bee.host.assignments", {version = 1, workspace_id = state.workspace_id,
            connection_id = client.connection_id, display_id = client.display_id, revision = state.assignment_revision,
            items = items, displays = displays})
    end
end
local function result(state: State, id: string, op: string, recipient: string, connection_id: string, code: string, message: string)
    assert(process.send(state.owner, "bee.host.client_result", {version = 1, request_id = id, op = op,
        workspace_id = state.workspace_id, recipient = recipient, connection_id = connection_id,
        display_id = state.admitted[recipient] and state.admitted[recipient].display_id or "",
        error_code = code, error = message}))
end

local function appearance_result(state: State, request_id: string, action: AppearanceOp,
    connection_id: string, renderer: string, renderer_generation: string,
    theme: string, background: string, taskbar: string, code: string, message: string)
    -- This reply is consumed only by the authenticated broker. The stable
    -- client connection fields are retained for diagnostics and correlation;
    -- the broker already authenticated the originating Settings process.
    assert(process.send(state.broker, "bee.appearance.state", {version = 1, scope = "client",
        request_id = request_id, action = action, workspace_id = state.workspace_id,
        connection_id = connection_id, renderer = renderer, renderer_generation = renderer_generation,
        revision = 0, theme = theme, background = background, taskbar = taskbar,
        error_code = code, error = message}))
end

local function failed_appearance(state: State, route: AppearanceRoute, code: string, message: string)
    appearance_result(state, route.request_id, route.action, route.connection_id, route.renderer,
        route.renderer_generation, route.theme, route.background, route.taskbar, code, message)
end
local function pending(state: State, client: clients.Client): Change?
    for _, change in pairs(state.changes) do if change.connection_id == client.connection_id then return change end end
    return nil
end
-- M.exited starts this change without a caller when an admitted renderer exits.
local function exited_release(value: Change): boolean
    return value.op == "render" and value.request_id == "" and value.renderer == ""
end
local function change(state: State, client: clients.Client, op: ChangeOp, request_id: string, renderer: string)
    local id = uuid.v7()
    state.changes[id] = {op = op, request_id = request_id, renderer = renderer, recipient = client.recipient, connection_id = client.connection_id}
    assert(process.send(state.broker, "bee.app.request", {version = 1, request_id = id, workspace_id = state.workspace_id,
        op = "unbind", recipient = client.renderer ~= "" and client.renderer or client.recipient}))
end
local function detach(state: State, client: clients.Client, request_id: string)
    client.detaching = true
    questions.forget(state.questions, client.connection_id)
    local previous = pending(state, client)
    if previous then
        if previous.op == "render" and state.queued_detaches[client.connection_id] == nil then
            state.queued_detaches[client.connection_id] = request_id
        elseif request_id ~= "" then
            result(state, request_id, "detach", client.recipient, client.connection_id, "busy", "Detach is pending")
        end
        return
    end
    change(state, client, "detach", request_id, "")
end
local function send_questions(state: State, client: clients.Client)
    if client.detaching or not client.permissions.control then return end
    local snapshot = questions.snapshot(state.questions, client.connection_id)
    if snapshot and not process.send(client.recipient, "bee.host.questions", snapshot) then detach(state, client, "") end
end
function M.questions(state: State, data: unknown)
    if not questions.update(state.questions, data) then error("Invalid broker question snapshot") end
    for _, client in pairs(state.admitted) do send_questions(state, client) end
end
function M.selection(state: State, caller: string, data: unknown)
    local client = state.admitted[caller]
    if not client or client.detaching or not client.permissions.control then return end
    if questions.select(state.questions, client.connection_id, data) then send_questions(state, client) end
end
function M.answer(state: State, caller: string, data: unknown)
    local client = state.admitted[caller]
    if not client or client.detaching then return end
    local response = interaction.response(data)
    if not response then return end
    local code, failure = "permission_denied", "Client interaction control is not granted"
    if client.permissions.control then
        local accepted, reason = questions.answer(state.questions, client.connection_id, data)
        code, failure = reason or "", reason or ""
        if accepted then
            local sent, err = process.send(state.broker, "bee.interaction.response", {version = 1,
                request_id = accepted.request_id, id = accepted.id, instance_id = accepted.instance_id,
                action = accepted.action, value = accepted.value})
            if sent then questions.dispatched(state.questions, accepted)
            else code, failure = "delivery_failed", tostring(err) end
        end
    end
    if not process.send(client.recipient, "bee.host.question_result", {version = 1, workspace_id = state.workspace_id,
        connection_id = client.connection_id, request_id = response.request_id, id = response.id,
        instance_id = response.instance_id, error_code = code, error = failure}) then detach(state, client, "") end
end
local function presentation(state: State, client: clients.Client, code: string, message: string): (boolean, string?)
    local sent, err = process.send(client.recipient, "bee.host.presentation", {version = 1, workspace_id = state.workspace_id,
        connection_id = client.connection_id, renderer = client.renderer, generation = client.renderer_generation,
        pending = client.rendering, error_code = code, error = message})
    return sent == true, err and tostring(err) or nil
end
local function render(state: State, client: clients.Client, renderer: string, request_id: string)
    if client.renderer == renderer and not client.rendering then
        local sent, err = presentation(state, client, "", "")
        if not sent then detach(state, client, "") end
        result(state, request_id, "render", client.recipient, client.connection_id, sent and "" or "delivery_failed", err or "")
        return
    end
    client.rendering = true
    client.renderer_generation = uuid.v7()
    change(state, client, "render", request_id, renderer)
end
local function reserved(state: State, recipient: string, except: string): boolean
    if recipient == "" then return false end
    if recipient == state.owner or recipient == state.broker or recipient == state.self then return true end
    for _, client in pairs(state.admitted) do
        if client.connection_id ~= except and (client.recipient == recipient or client.renderer == recipient) then return true end
    end
    for _, value in pairs(state.changes) do
        if value.connection_id ~= except and value.renderer == recipient then return true end
    end
    return false
end
local function display_reserved(state: State, display_id: string): boolean
    -- Detaching admissions remain in state.admitted until revocation and
    -- monitor removal complete, so the durable display writer stays fenced
    -- throughout cleanup and any failed cleanup retry.
    for _, client in pairs(state.admitted) do
        if client.display_id == display_id then return true end
    end
    return false
end
local function forget(state: State, connection_id: string)
    for id, route in pairs(state.routes) do
        if route.connection_id == connection_id then state.routes[id] = nil; state.route_count = state.route_count - 1 end
    end
    local retained: {string} = {}
    for _, id in ipairs(state.completed) do if state.routes[id] then retained[#retained + 1] = id end end
    state.completed = retained
    for id, route in pairs(state.appearance_routes) do
        if route.connection_id == connection_id then
            failed_appearance(state, route, "unavailable", "Client connection was detached")
            state.appearance_routes[id] = nil
        end
    end
end
function M.control(state: State, caller: string, data: unknown, ready: boolean): string?
    if caller ~= state.owner then return nil end
    local control = clients.control(data)
    if not control then return nil end
    local joined_recipient: string? = nil
    local client = state.admitted[control.recipient]
    local code, failure = "", ""
    if control.workspace_id ~= state.workspace_id then code, failure = "workspace_mismatch", "Foreign workspace"
    elseif not ready then code, failure = "busy", "Host is not accepting clients"
    elseif control.recipient == state.owner or control.recipient == state.self or control.recipient == state.broker then
        code, failure = "invalid_argument", "Core owners cannot be desktop clients"
    elseif control.op == "detach" then
        if client then detach(state, client, control.request_id); return nil end
        code, failure = "not_found", "Client is not admitted"
    elseif control.op == "render" then
        local previous = client and pending(state, client) or nil
        if not client then code, failure = "not_found", "Client is not admitted"
        elseif client.detaching or (previous and not exited_release(previous)) then code, failure = "busy", "Client grants are changing"
        elseif reserved(state, control.renderer, client.connection_id) then code, failure = "permission_denied", "Renderer belongs to another owner"
        elseif previous then
            -- The exited renderer's unbind revokes exactly the grants a replacement
            -- needs revoked, so the replacement completes that change.
            previous.request_id, previous.renderer = control.request_id, control.renderer
            return nil
        else render(state, client, control.renderer, control.request_id); return nil end
    elseif control.permissions then
        if client and control.display_id ~= client.display_id then
            code, failure = "identity_conflict", "Client is already admitted under another display"
        elseif not client and display_reserved(state, control.display_id) then
            code, failure = "identity_conflict", "Display is already admitted"
        elseif client and (client.detaching or not clients.same_permissions(client.permissions, control.permissions)) then
            code, failure = "busy", "Detach the current admission before replacing its permissions"
        elseif not client and (state.count >= 8 or reserved(state, control.recipient, "")) then
            code, failure = "busy", "Client recipient or capacity is unavailable"
        else
            if not client then
                local monitored, monitor_error = process.monitor(control.recipient)
                if not monitored then code, failure = "unavailable", tostring(monitor_error)
                else
                    local joined: clients.Client = {recipient = control.recipient, connection_id = uuid.v7(),
                        permissions = control.permissions, detaching = false, renderer = control.recipient,
                        renderer_generation = uuid.v7(), rendering = false, display_id = control.display_id}
                    client = joined
                    state.admitted[control.recipient] = joined
                    state.count = state.count + 1
                end
            end
            if client and code == "" then
                local sent, send_error = process.send(client.recipient, "bee.host.admitted", {version = 1,
                    workspace_id = state.workspace_id, connection_id = client.connection_id, permissions = client.permissions,
                    renderer = client.renderer, renderer_generation = client.renderer_generation, renderer_pending = client.rendering,
                    display_id = client.display_id})
                if not sent then code, failure = "delivery_failed", tostring(send_error); detach(state, client, "")
                else joined_recipient = client.recipient; M.assignments(state) end
            end
        end
    end
    result(state, control.request_id, control.op, control.recipient, client and client.connection_id or "", code, failure)
    return joined_recipient
end
function M.publish(state: State, value: inventory.State, kind: "catalog" | "views", recipient: string?)
    if value.workspace_id ~= state.workspace_id then error("Foreign workspace inventory") end
    state.inventory = value
    for _, client in pairs(state.admitted) do
        if not client.detaching and (recipient == nil or recipient == client.recipient) then
            local sent = false
            if kind == "catalog" then
                sent = process.send(client.recipient, "bee.host.catalog", inventory.catalog_message(value, client.connection_id)) == true
            else
                sent = process.send(client.recipient, "bee.host.views", inventory.views_message(value, client.connection_id)) == true
            end
            if not sent then detach(state, client, "") end
        end
    end
end
local function deliver_reply(state: State, client: clients.Client, reply: contract.Reply)
    if not process.send(client.recipient, "bee.host.reply", {version = 1, reply = reply,
        views = inventory.views_message(state.inventory, client.connection_id)}) then detach(state, client, "") end
end

-- A crashed producer has no pending client request to correlate. Route its
-- closed reply by the durable display assignment while that fence still
-- exists, so the person sees the failure after the view is retired.
function M.failure(state: State, reply: contract.Reply): boolean
    if reply.op ~= "closed" or reply.error_code ~= "application_failed" then return false end
    local found, problem = state.assignments:get({view_id = reply.id, instance_id = reply.instance_id})
    if problem or not found then return false end
    local delivered = false
    for _, client in pairs(state.admitted) do
        if not client.detaching and client.display_id == found.assignment.display_id then
            deliver_reply(state, client, reply)
            delivered = true
        end
    end
    return delivered
end
local function reject(state: State, client: clients.Client, request: contract.Request, reason: string, message: string)
    local reply = contract.reply(request.request_id, request.op, reason, message)
    reply.workspace_id = state.workspace_id
    deliver_reply(state, client, reply)
end
local function live_identity(state: State, view_id: string, instance_id: string): boolean
    for _, view in ipairs(state.inventory.views) do
        if view.view_id == view_id and view.instance_id == instance_id then return true end
    end
    return false
end
function M.request(state: State, caller: string, request: contract.Request, data: unknown, ready: boolean, saved: {records.Record}): boolean
    local client = state.admitted[caller]
    if not client then return false end
    local code = ""
    if type(data) ~= "table" or data.connection_id ~= client.connection_id or client.detaching then code = "permission_denied"
    elseif request.op == "bind" and data.renderer_generation ~= client.renderer_generation then code = "stale_renderer"
    elseif request.op == "bind" and client.rendering then code = "busy"
    elseif request.op == "bind" and client.renderer == "" then code = "unavailable"
    elseif not clients.allowed(client, request) then code = "permission_denied"
    elseif request.workspace_id ~= state.workspace_id then code = "workspace_mismatch"
    elseif not ready then code = "busy" end
    if code == "" and request.op == "bind" and request.observer ~= true and client.permissions.control then
        local assigned, assignment_error = state.assignments:get({view_id = request.id, instance_id = request.instance_id})
        if assignment_error then error("Read display assignment: " .. tostring(assignment_error)) end
        if not assigned then
            -- Recovered and pre-admission applications can be live before any
            -- client opened them through this router. The first authenticated
            -- controller claims only that exact live incarnation; a dormant or
            -- mismatched identity cannot create an assignment through bind.
            if not live_identity(state, request.id, request.instance_id) then code = "permission_denied"
            else
                local claimed, claim_error = state.assignments:claim({view_id = request.id, instance_id = request.instance_id,
                    display_id = client.display_id})
                if not claimed then code = "persistence_failed"
                elseif claimed.display_id ~= client.display_id then code = "permission_denied"
                else M.assignments(state) end
            end
        elseif assigned.intent or assigned.assignment.display_id ~= client.display_id then code = "permission_denied" end
    end
    if code ~= "" then
        reject(state, client, request, code, code == "workspace_mismatch" and "Request targets another workspace" or "Client request rejected")
        return true
    end
    if request.op == "bind" then request.observer = not client.permissions.control or request.observer == true end
    local generation = request.op == "bind" and client.renderer_generation or ""
    local internal, hash_error = hash.sha256(client.connection_id .. "\0" .. generation .. "\0" .. request.request_id)
    if not internal then error(tostring(hash_error)) end
    local fingerprint = contract.argument_fingerprint({request.op, request.id, request.instance_id,
        request.definition_id, request.thread_id or "", request.recipient, tostring(request.observer == true)}) .. contract.argument_fingerprint(request.arguments)
    local existing = state.routes[internal]
    if existing and existing.fingerprint ~= fingerprint then
        reject(state, client, request, "request_conflict", "Request ID was reused for another operation")
        return true
    end
    if not state.routes[internal] then
        while state.route_count >= 128 and #state.completed > 0 do
            local oldest = table.remove(state.completed, 1)
            if state.routes[oldest] then state.routes[oldest] = nil; state.route_count = state.route_count - 1 end
        end
        if state.route_count >= 128 then reject(state, client, request, "busy", "Client request capacity reached"); return true end
        local resume: recovery.Resume? = nil
        if request.op == "open" then
            local reserved: {[string]: boolean} = {}
            for _, route in pairs(state.routes) do
                if not route.completed and route.resume then reserved[route.resume.instance_id] = true end
            end
            resume = recovery.select(saved, state.inventory, request.definition_id, reserved, request.thread_id)
        end
        state.routes[internal] = {recipient = client.recipient, connection_id = client.connection_id, request_id = request.request_id,
            op = request.op, completed = false, renderer_generation = generation, fingerprint = fingerprint, resume = resume, display_id = client.display_id}
        state.route_count = state.route_count + 1
    end
    -- Keep this selection on the correlation record, including after completion:
    -- retries must reach the broker with the same recovery fingerprint.
    local route = state.routes[internal]
    if request.op == "open" and route and route.resume then
        request.restore_view_id, request.restore_instance_id = route.resume.view_id, route.resume.instance_id
        request.resume_schema, request.resume_state = route.resume.schema, route.resume.state
        request.thread_id = route.resume.thread_id
    end
    request.request_id = internal
    if request.op == "bind" then request.recipient = client.renderer end
    local sent, send_error = process.send(state.broker, "bee.app.request", request)
    if not sent then
        -- A refused enqueue has no broker outcome. Release only a reservation
        -- created by this attempt; an older in-flight/replayed route still owns
        -- its original request and recovery selection.
        if not existing then
            state.routes[internal] = nil
            state.route_count = state.route_count - 1
        end
        request.request_id = route and route.request_id or request.request_id
        reject(state, client, request, "delivery_failed", tostring(send_error))
    end
    return true
end
-- The host derives source display authority from the admitted caller. The
-- transfer payload never selects a source client or renderer handle.
function M.transfer(state: State, caller: string, data: unknown, ready: boolean): (transfer.Request?, clients.Client?, string?)
    local request = transfer.request(data)
    local client = state.admitted[caller]
    if not request then return nil, nil, "permission_denied" end
    if not client then return request, nil, "permission_denied" end
    if not ready or client.detaching or not client.permissions.control then return request, nil, "unavailable" end
    if request.workspace_id ~= state.workspace_id or request.connection_id ~= client.connection_id
        or request.renderer_generation ~= client.renderer_generation or client.rendering or client.renderer == "" then
        return request, nil, "stale_renderer"
    end
    return request, client, nil
end

-- A new transfer requires both ends to be present at the durable owner.  This
-- deliberately runs only for a new receipt: completed receipts must remain
-- replayable after either display has later detached.
function M.transfer_ready(state: State, request: transfer.Request, source: clients.Client): string?
    local live = false
    for _, item in ipairs(state.inventory.views) do
        if item.view_id == request.view_id and item.instance_id == request.instance_id then live = true; break end
    end
    if not live then return "not_found" end
    local current, read_error = state.assignments:get({view_id = request.view_id, instance_id = request.instance_id})
    if read_error then error("Read display assignment before transfer: " .. tostring(read_error)) end
    if not current or current.intent or current.assignment.display_id ~= source.display_id
        or current.assignment.revision ~= request.expected_revision then return "stale_assignment" end
    if request.target_display_id == source.display_id then return "invalid_target" end
    for _, target in pairs(state.admitted) do
        if target.display_id == request.target_display_id then
            if target.detaching or not target.permissions.control or target.renderer == "" or target.rendering then return "unavailable" end
            return nil
        end
    end
    return "unavailable"
end
local function release_renderer(client: clients.Client): (boolean, string?)
    if client.renderer ~= "" and client.renderer ~= client.recipient then
        local released, err = process.unmonitor(client.renderer)
        if not released then return false, tostring(err) end
    end
    client.renderer = ""
    return true, nil
end

-- Forward through the currently admitted display.
local function forward_appearance(state: State, request_id: string)
    local route = state.appearance_routes[request_id]
    if not route then error("Missing admitted appearance route") end
    local sent, err = process.send(route.recipient, "bee.client.appearance.request", {version = 1,
        request_id = route.request_id, action = route.action, workspace_id = state.workspace_id,
        connection_id = route.connection_id, renderer = route.renderer,
        renderer_generation = route.renderer_generation, theme = route.theme,
        background = route.background, taskbar = route.taskbar})
    if not sent then
        state.appearance_routes[request_id] = nil
        failed_appearance(state, route, "delivery_failed", tostring(err))
    end
end

-- Route an appearance request from the broker to the stable client owner only
-- when the broker's attachment recipient is the client's current renderer.
-- A nonempty recipient must be a currently admitted renderer. The private host
-- never interprets an unknown renderer as permission to change workspace state.
function M.appearance(state: State, caller: string, data: unknown, ready: boolean): boolean
    if caller ~= state.broker then return false end
    local request = clients.appearance(data)
    if not request or request.recipient == "" then return false end

    local client: clients.Client? = nil
    for _, candidate in pairs(state.admitted) do
        if candidate.renderer == request.recipient then client = candidate; break end
    end
    if not client then
        appearance_result(state, request.request_id, request.action, "", request.recipient, "",
            request.theme, request.background, request.taskbar, "stale_renderer", "Client renderer is not admitted")
        return true
    end

    local route: AppearanceRoute = {request_id = request.request_id, action = request.action,
        recipient = client.recipient, connection_id = client.connection_id, renderer = client.renderer,
        renderer_generation = client.renderer_generation, theme = request.theme, background = request.background,
        taskbar = request.taskbar}
    local code, message = "", ""
    if not ready then code, message = "busy", "Host is not accepting clients"
    elseif client.detaching then code, message = "unavailable", "Client is detaching"
    elseif request.action ~= "state" and not client.permissions.appearance then code, message = "permission_denied", "Client appearance is not granted"
    elseif client.renderer == "" then code, message = "unavailable", "Client renderer is unavailable"
    elseif state.appearance_routes[request.request_id] then code, message = "request_conflict", "Appearance request ID was reused"
    else
        local count = 0
        for _, pending_route in pairs(state.appearance_routes) do
            if pending_route.connection_id == client.connection_id then count = count + 1 end
        end
        if count >= 16 then code, message = "busy", "Client appearance request capacity reached" end
    end
    if code ~= "" then
        failed_appearance(state, route, code, message)
        return true
    end

    state.appearance_routes[request.request_id] = route
    forward_appearance(state, request.request_id)
    return true
end

-- Only the stable admitted client execution may answer a route. The renderer
-- and connection generation must still be the exact values selected by the
-- host when the request was delivered.
-- An admitted display owns its committed presentation, not the workspace defaults.
function M.appearance_changed(state: State, caller: string, data: unknown): boolean
    local update = clients.appearance_changed(data)
    local client = state.admitted[caller]
    if not update or not client or client.detaching or client.rendering or not client.permissions.control
        or update.workspace_id ~= state.workspace_id or update.connection_id ~= client.connection_id
        or update.renderer ~= client.renderer or update.renderer_generation ~= client.renderer_generation then return false end
    assert(process.send(state.broker, "bee.appearance.state", {version = 1, scope = "display",
        renderer = update.renderer, revision = update.revision, theme = update.theme,
        background = update.background, taskbar = update.taskbar}))
    return true
end

function M.appearance_result(state: State, caller: string, data: unknown): boolean
    local response = clients.appearance_result(data)
    if not response then return false end
    local route = state.appearance_routes[response.request_id]
    if not route or caller ~= route.recipient or response.workspace_id ~= state.workspace_id
        or response.action ~= route.action or response.connection_id ~= route.connection_id
        or response.renderer ~= route.renderer or response.renderer_generation ~= route.renderer_generation then
        return false
    end
    state.appearance_routes[response.request_id] = nil
    local client = state.admitted[caller]
    if not client or client.detaching or client.rendering or client.connection_id ~= route.connection_id
        or client.renderer ~= route.renderer or client.renderer_generation ~= route.renderer_generation then
        failed_appearance(state, route, "stale_renderer", "Client renderer changed before appearance completed")
        return true
    end
    assert(process.send(state.broker, "bee.appearance.state", {version = 1, scope = "client",
        request_id = response.request_id, action = response.action, workspace_id = state.workspace_id,
        connection_id = response.connection_id, renderer = response.renderer,
        renderer_generation = response.renderer_generation, revision = response.revision,
        theme = response.theme, background = response.background, taskbar = response.taskbar,
        error_code = response.error_code, error = response.error}))
    return true
end

function M.reply(state: State, reply: contract.Reply, current: inventory.State): boolean
    if current.workspace_id ~= state.workspace_id then error("Foreign workspace result inventory") end
    state.inventory = current
    local changed = state.changes[reply.request_id]
    if changed and reply.op == "unbind" then
        state.changes[reply.request_id] = nil
        local client = state.admitted[changed.recipient]
        if not client or client.connection_id ~= changed.connection_id then return true end
        local delivery_failed = false
        if reply.error_code == "" then
            local released, release_error = release_renderer(client)
            if not released then reply.error_code, reply.error = "unmonitor_failed", release_error or "Renderer monitor removal failed" end
        end
        if changed.op == "detach" then
            if reply.error_code == "" then
                local unmonitored, err = process.unmonitor(client.recipient)
                if not unmonitored then reply.error_code, reply.error = "unmonitor_failed", tostring(err)
                else
                    forget(state, client.connection_id)
                    state.admitted[client.recipient] = nil
                    state.count = state.count - 1
                    process.send(client.recipient, "bee.host.detached", {version = 1, workspace_id = state.workspace_id, connection_id = client.connection_id})
                end
            end
        else
            if reply.error_code == "" then
                local renderer = client.detaching and "" or changed.renderer
                if client.detaching then reply.error_code, reply.error = "cancelled", "Renderer replacement superseded by client detach" end
                if renderer ~= "" and renderer ~= client.recipient then
                    local monitored, err = process.monitor(renderer)
                    if not monitored then reply.error_code, reply.error = "unavailable", tostring(err); renderer = "" end
                end
                client.renderer, client.rendering = renderer, false
            end
            local sent, err = presentation(state, client, reply.error_code, reply.error)
            if not sent then
                delivery_failed = true
                if reply.error_code == "" then reply.error_code, reply.error = "delivery_failed", err or "Client presentation delivery failed" end
            end
        end
        result(state, changed.request_id, changed.op, client.recipient, client.connection_id, reply.error_code, reply.error)
        local queued = state.queued_detaches[client.connection_id]
        if queued ~= nil or delivery_failed then state.queued_detaches[client.connection_id] = nil; detach(state, client, queued or "") end
        return true
    end
    local route = state.routes[reply.request_id]
    if not route then return false end
    if not route.completed and (reply.op == route.op or (route.op == "open" and reply.op == "focus")
        or (reply.error_code ~= "" and reply.op ~= "attached" and reply.op ~= "closing")) then
        route.completed = true
        state.completed[#state.completed + 1] = reply.request_id
    end
    local client = state.admitted[route.recipient]
    -- The initiating admitted display owns a newly opened live view before
    -- its usable reply is delivered. A failed durable claim leaves the app
    -- unbound from client control rather than creating an unfenced grant.
    if route.op == "open" and reply.op == "open" and reply.error_code == "" then
        local claimed, claim_error = state.assignments:claim({view_id = reply.id, instance_id = reply.instance_id,
            display_id = route.display_id})
        if not claimed then
            reply.error_code, reply.error = "persistence_failed", tostring(claim_error)
        else M.assignments(state) end
    end
    if client and not client.detaching and client.connection_id == route.connection_id
        and (route.op ~= "bind" or (not client.rendering and route.renderer_generation == client.renderer_generation)) then
        reply.request_id, reply.resume_state = route.request_id, ""
        if reply.op ~= "attached" then reply.mount = "" end
        deliver_reply(state, client, reply)
    end
    return true
end
function M.exited(state: State, pid: string)
    local client = state.admitted[pid]
    if client then detach(state, client, ""); return end
    for _, item in pairs(state.admitted) do
        if item.renderer == pid and not pending(state, item) then
            if item.detaching then detach(state, item, "") else render(state, item, "", "") end
        end
    end
end
return M
