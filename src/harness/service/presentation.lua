-- MIT. Retained presentation uses the admitted window executor and hooks.
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local hash = require("hash")
local security = require("security")
local funcs = require("funcs")
local json = require("json")
local tty = require("tty")
local bounds = require("bounds")
local admission = require("admission")
local canonical = require("canonical")
local recovery = require("recovery")
local principal = require("principal")
local M = {}
local OWNER = "bee.session.window/"
local CALLER = "bee.session.viewer/"
local TOPIC = "bee.session.window.request"
local REPLY = "bee.session.window.reply"
local RESTORE = "bee.harness.binding:present_restore"
type Object = {[string]: unknown}
local function fail(message: string): Object return {ok = false, error = {code = "UNAVAILABLE", message = message}} end
-- A window runs as its own application principal, named by the request that
-- first admitted it, so its session, thread membership and operation keys
-- belong to the window: any viewer in the workspace can reopen it.
type Window = {actor: security.Actor, workspace: string}
local function window(workspace: string, request_id: string): Window?
    local value = principal.value(workspace, request_id, "bee.harness.app:app", "1", 1)
    local actor = value and security.new_actor(value.id, value.metadata)
    if not actor then return nil end
    return {actor = actor, workspace = workspace}
end
local function rpc(target: string?, request: Object, startup: Object?, name: string?, operation_key: string?, owner: Window?): Object
    local token = CALLER .. assert(uuid.v7())
    local replies = assert(process.listen(REPLY, {message = true}))
    assert(process.registry.register(token))
    request.caller_token = token
    local sent: boolean? = nil
    local err: unknown = nil
    if startup and name and owner then
        local spawned, spawn_error = process.with_options({}):with_context({["bee.workspace_id"] = owner.workspace})
            :with_actor(owner.actor):with_scope(assert(security.scope()))
            :spawn("bee.harness.service:presentation_owner", "bee:workers", startup, name, token, operation_key)
        if spawned then target = tostring(spawned); sent = true else err = spawn_error end
    elseif target then sent, err = process.send(target, TOPIC, request) end
    local reply: Object = fail(tostring(err or "window owner did not answer"))
    if sent then
        local timer = assert(time.timer("30s"))
        while true do
            local event = channel.select({replies:case_receive(), timer:channel():case_receive()})
            if not event.ok or event.channel ~= replies then break end
            if tostring(event.value:from()) == target then
                local value = bounds.object(event.value:payload():data())
                if value and value.caller_token == token then reply = value; reply.caller_token = nil; break end
            end
        end
        timer:stop()
    end
    process.registry.unregister(token, process.registry.LOCAL)
    process.unlisten(replies)
    return reply
end
function M.open(value: unknown): Object
    local body = bounds.object(value)
    local spec = body and bounds.object(body.spec)
    local actor = security.actor()
    local meta = actor and bounds.object(actor:meta())
    local workspace = meta and bounds.id(meta.workspace_id)
    local operation_key = body and body.operation_key
    if not body or not spec or not actor or not workspace or type(operation_key) ~= "string" then return fail("window admission identity is missing") end
    local digest = assert(hash.sha256(actor:id() .. "\n" .. workspace .. "\n" .. operation_key))
    local profile = bounds.object(spec.profile)
    local plan, refused = admission.resolve(tostring(spec.definition), "window", workspace,
        profile and bounds.id(profile.id), profile and bounds.integer(profile.revision))
    if not plan then return refused or fail("window plan unavailable") end
    local setup, setup_error = funcs.call("bee.harness.binding:setup", {workspace_id = workspace,
        definition_ref = plan.definition_ref, expected_plan_digest = plan.plan_digest,
        saved_profile_id = plan.saved_profile_id, saved_profile_revision = plan.saved_profile_revision, workdir = spec.workdir})
    local prepared = bounds.object(setup)
    if setup_error or not prepared or prepared.ok ~= true then return fail(tostring(setup_error or (prepared and prepared.error) or "window setup failed")) end
    local request, request_error = admission.decode_request({request_id = digest, definition_ref = plan.definition_ref,
        workspace_id = workspace, brief = "", mode = "window", workdir = prepared.workdir,
        saved_profile_id = plan.saved_profile_id, saved_profile_revision = plan.saved_profile_revision,
        expected_plan_digest = plan.plan_digest})
    if not request then return fail(request_error or "window admission request invalid") end
    local name = OWNER .. digest
    local owner = process.registry.lookup(name)
    local reply: Object
    if owner then reply = rpc(tostring(owner), {op = "open", request = request, operation_key = operation_key})
    else
        local owner_window = window(workspace, digest)
        if not owner_window then return fail("window principal could not be created") end
        reply = rpc(nil, {op = "open", request = request, operation_key = operation_key}, request, name, operation_key, owner_window)
    end
    local receipt = reply.ok == true and bounds.object(reply.value) or nil
    if receipt and type(receipt.session) == "string" and meta.definition_id ~= "bee.harness.app:app" then
        -- The existing host path chooses a live display and checks the caller's runtime grant.
        funcs.call("bee.apps:open_call", {definition_id = "bee.harness.app:app",
            arguments = {"--session", receipt.session}, presentation_session = receipt.session, idempotency_key = assert(uuid.v7())})
    end
    return reply
end
-- resume starts an owner for a window session whose terminal is gone. Sessions
-- reports the admitted continuation; the window app restores from it as from
-- its own checkpoint, so admission resumes the same native conversation.
function M.restore(value: unknown): Object
    local body = bounds.object(value)
    local session = body and bounds.id(body.session)
    if not body or not session or bounds.fields(body, {"session"}) then return fail("invalid window restore request") end
    local live = process.registry.lookup(OWNER .. session)
    if live then return {ok = true, value = {session = session}} end
    local raw, err = funcs.call("bee.threads.sessions.binding:restore", {session = session})
    local reply = bounds.object(raw)
    if err or not reply or reply.ok ~= true then
        local fault = reply and bounds.object(reply.error)
        return fail(tostring(err or (fault and fault.message) or "the window cannot be restored"))
    end
    local facts = bounds.object(reply.value)
    local saved, saved_error = recovery.decode(facts and {definition_ref = facts.definition_ref, plan_digest = facts.plan_digest,
        origin_request_id = facts.origin_request_id, previous_attempt_id = facts.previous_attempt_id, thread_id = facts.thread_id,
        saved_profile_id = facts.saved_profile_id, saved_profile_revision = facts.saved_profile_revision})
    if not saved then return fail(saved_error or "the window restore facts are malformed") end
    local actor = security.actor()
    local meta = actor and bounds.object(actor:meta())
    local workspace = meta and bounds.id(meta.workspace_id)
    if not workspace then return fail("window restore identity is missing") end
    local operation_key = bounds.text(facts and facts.operation_key, 128)
    if not operation_key or operation_key == "" then return fail("the window restore facts omit the session key") end
    -- The window app admits the continuation under the key that created the
    -- session, so admission attaches the same session.
    local owner_window = window(workspace, saved.origin_request_id)
    if not owner_window then return fail("window principal could not be created") end
    return rpc(nil, {op = "resume"}, {resume = saved, session = session, workspace_id = workspace}, OWNER .. session, operation_key, owner_window)
end

function M.attach(value: unknown): Object
    local request = bounds.object(value)
    local session = request and bounds.id(request.session)
    if not request or not session or bounds.fields(request, {"session", "detach"})
        or (request.detach ~= nil and type(request.detach) ~= "boolean") then return fail("invalid viewer request") end
    local raw, err = funcs.call("bee.threads.sessions.binding:get", {session = session})
    local reply = bounds.object(raw)
    if err or not reply or reply.ok ~= true then
        local fault = reply and bounds.object(reply.error)
        return fail(tostring(err or (fault and fault.message) or "session is not visible"))
    end
    local owner = process.registry.lookup(OWNER .. session)
    if not owner and request.detach ~= true then
        local resumed, resume_error = funcs.call(RESTORE, {session = session})
        local restored = bounds.object(resumed)
        if resume_error or not restored then return fail(tostring(resume_error or "window restore reply unavailable")) end
        if restored.ok ~= true then return restored end
        owner = process.registry.lookup(OWNER .. session)
    end
    if not owner then return fail("the session has no live terminal") end
    return rpc(tostring(owner), {op = request.detach == true and "detach" or "attach"})
end
-- start spawns the window executor on a fresh viewport and returns both.
local function start(workspace_id: string, request_id: string, arguments: {string}, resume_state: string, operation_key: string): (tty.Viewport, string)
    local view = assert(tty.viewport({width = 80, height = 24}))
    local grant = assert(view:grant())
    local pid = assert(process.with_options({terminal = grant}):spawn_monitored("bee.harness.service:presentation_executor", "bee:workers", {
        version = 1, broker_pid = process.pid(), workspace_pid = process.pid(), workspace_id = workspace_id,
        instance_id = request_id, view_id = request_id, definition_id = "bee.harness.app:app",
        execution_generation = 1, definition_revision = "1", registry_revision = "1", launch_token = request_id,
        resume_schema = recovery.SCHEMA, resume_state = resume_state, arguments = arguments}, operation_key))
    return view, tostring(pid)
end
local function run(value: unknown, name: unknown, initial_token: string, operation_key: string)
    local requests = assert(process.listen(TOPIC, {message = true}))
    local events = assert(process.events())
    local restoring = bounds.object(bounds.object(value) and (value :: Object).resume)
    local request: admission.Request? = nil
    local aliases: {string} = {}
    local started_view: tty.Viewport? = nil
    local started_pid: string? = nil
    local function reply_to(token: string, reply: Object)
        reply.caller_token = token
        local caller = process.registry.lookup(token)
        if caller then process.send(caller, REPLY, reply) end
    end
    local function receipt(): Object
        local raw, lookup_error = funcs.call("bee.threads.binding:operation_lookup", {operation_key = operation_key})
        local lookup = bounds.object(raw)
        local result = lookup and bounds.object(lookup.value)
        if lookup_error or not lookup or lookup.ok ~= true or not result then return fail("window receipt unavailable") end
        return {ok = true, value = result.receipt}
    end
    if restoring then
        local body = assert(bounds.object(value))
        local saved, saved_error = recovery.decode(restoring)
        local session, workspace = bounds.id(body.session), bounds.id(body.workspace_id)
        if not saved or not session or not workspace or name ~= OWNER .. session then error(saved_error or "invalid window restore") end
        assert(process.registry.register(OWNER .. session))
        aliases = {OWNER .. session}
        local encoded = assert(recovery.encode(saved))
        started_view, started_pid = start(workspace, assert(uuid.v7()), {}, encoded, operation_key)
        reply_to(initial_token, {ok = true, value = {session = session}})
    else
        local decoded, err = admission.decode_request(value)
        if not decoded or type(name) ~= "string" or name ~= OWNER .. decoded.request_id then error(err or "invalid presentation owner") end
        request = decoded
        assert(process.registry.register(name))
        local admitted, refused = admission.admit_request(decoded, operation_key)
        if not admitted or not admitted.session_ref then error(tostring(refused and refused.error and refused.error.message or "window was not admitted")) end
        local alias = OWNER .. admitted.session_ref
        assert(process.registry.register(alias))
        aliases = {name, alias}
        local encoded = assert(json.encode({request_id = decoded.request_id, definition_ref = decoded.definition_ref,
            brief = "", workdir = decoded.workdir, expected_plan_digest = decoded.expected_plan_digest,
            saved_profile_id = decoded.saved_profile_id, saved_profile_revision = decoded.saved_profile_revision,
            thread_id = admitted.thread_id}))
        started_view, started_pid = start(decoded.workspace_id, decoded.request_id, {encoded}, "", operation_key)
        reply_to(initial_token, receipt())
    end
    local view, pid = assert(started_view), assert(started_pid)
    local mount: string? = nil
    local recipient: string? = nil
    while true do
        local event = channel.select({requests:case_receive(), events:case_receive()})
        if not event.ok then break end
        if event.channel == events then
            if event.value.kind == process.event.EXIT and tostring(event.value.from) == tostring(pid) then break end
            if event.value.kind == process.event.CANCEL then process.cancel(pid, "session owner stopping") end
        else
            local sender = tostring(event.value:from())
            local body = bounds.object(event.value:payload():data())
            local token = body and bounds.id(body.caller_token)
            if not body or bounds.fields(body, {"op", "request", "caller_token", "operation_key"}) or not token or token:sub(1, #CALLER) ~= CALLER
                or tostring(process.registry.lookup(token)) ~= sender then goto next_request end
            local reply: Object
            if body.op == "open" and request then
                local supplied, decode_error = admission.decode_request(body.request)
                local expected = assert(canonical.encode(request, 16384, 16))
                local candidate = supplied and canonical.encode(supplied, 16384, 16)
                if not supplied or candidate ~= expected or body.operation_key ~= operation_key then reply = fail(decode_error or "window operation key changed")
                else reply = receipt() end
            elseif body.op == "attach" then
                if mount then assert(view:revoke(mount)) end
                mount = assert(view:mount(sender, {observe = true, input = true, resize = true}))
                recipient = sender
                reply = {ok = true, value = {mount = mount}}
            elseif body.op == "detach" and recipient == sender then
                if mount then assert(view:revoke(mount)) end
                mount, recipient = nil, nil
                reply = {ok = true, value = {}}
            else reply = fail("invalid window operation") end
            reply.caller_token = token
            process.send(sender, REPLY, reply)
        end
        ::next_request::
    end
    view:close()
    for _, registered in ipairs(aliases) do process.registry.unregister(registered, process.registry.LOCAL) end
end
function M.main(value: unknown, name: unknown, initial_token: unknown, operation_key: unknown)
    local token = bounds.id(initial_token)
    if not token or token:sub(1, #CALLER) ~= CALLER then error("invalid window caller token") end
    local key = bounds.text(operation_key, 128)
    if not key or key == "" then error("invalid presentation operation key") end
    local ok, err = pcall(run, value, name, token, key)
    if not ok then
        local caller = process.registry.lookup(token)
        if caller then
            local reply = fail(tostring(err))
            reply.caller_token = token
            process.send(caller, REPLY, reply)
        end
        error(tostring(err))
    end
end
return M
