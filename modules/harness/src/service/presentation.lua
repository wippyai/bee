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
local M = {}
local OWNER = "bee.session.window/"
local CALLER = "bee.session.viewer/"
local TOPIC = "bee.session.window.request"
local REPLY = "bee.session.window.reply"
type Object = {[string]: unknown}
local function fail(message: string): Object return {ok = false, error = {code = "UNAVAILABLE", message = message}} end
local function rpc(target: string?, request: Object, startup: admission.Request?, name: string?, operation_key: string?): Object
    local token = CALLER .. assert(uuid.v7())
    local replies = assert(process.listen(REPLY, {message = true}))
    assert(process.registry.register(token))
    request.caller_token = token
    local sent: boolean? = nil
    local err: unknown = nil
    if startup and name then
        local spawned, spawn_error = process.with_options({}):with_scope(assert(security.scope())):spawn("bee.harness.service:presentation_owner", "bee:workers", startup, name, token, operation_key)
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
    if not body or not spec or not actor or not workspace or type(body.operation_key) ~= "string" then return fail("window admission identity is missing") end
    local digest = assert(hash.sha256(actor:id() .. "\n" .. workspace .. "\n" .. body.operation_key))
    local profile = bounds.object(spec.profile)
    local plan, refused = admission.resolve(tostring(spec.definition), "window", workspace,
        profile and bounds.id(profile.id), profile and bounds.integer(profile.revision))
    if not plan then return refused or fail("window plan unavailable") end
    local setup, setup_error = funcs.call("bee.harness.launch:setup", {workspace_id = workspace,
        definition_ref = plan.definition_ref, expected_plan_digest = plan.plan_digest,
        saved_profile_id = plan.saved_profile_id, saved_profile_revision = plan.saved_profile_revision})
    local prepared = bounds.object(setup)
    if setup_error or not prepared or prepared.ok ~= true then return fail(tostring(setup_error or (prepared and prepared.error) or "window setup failed")) end
    local request, request_error = admission.decode_request({request_id = digest, definition_ref = plan.definition_ref,
        workspace_id = workspace, brief = "", mode = "window", workdir = spec.workdir,
        saved_profile_id = plan.saved_profile_id, saved_profile_revision = plan.saved_profile_revision,
        expected_plan_digest = plan.plan_digest})
    if not request then return fail(request_error or "window admission request invalid") end
    local name = OWNER .. digest
    local owner = process.registry.lookup(name)
    local reply: Object
    if owner then reply = rpc(tostring(owner), {op = "open", request = request, operation_key = body.operation_key})
    else reply = rpc(nil, {op = "open", request = request, operation_key = body.operation_key}, request, name, body.operation_key :: string) end
    local receipt = reply.ok == true and bounds.object(reply.value) or nil
    if receipt and type(receipt.session) == "string" and meta.definition_id ~= "bee.harness.app:app" then
        -- The existing host path chooses a live display and checks the caller's runtime grant.
        funcs.call("bee.apps:open_call", {definition_id = "bee.harness.app:app",
            arguments = {"--session", receipt.session}, presentation_session = receipt.session, idempotency_key = assert(uuid.v7())})
    end
    return reply
end
function M.attach(value: unknown): Object
    local request = bounds.object(value)
    local session = request and bounds.id(request.session)
    if not request or not session or bounds.fields(request, {"session", "detach"})
        or (request.detach ~= nil and type(request.detach) ~= "boolean") then return fail("invalid viewer request") end
    local raw, err = funcs.call("bee.sessions.binding:get", {session = session})
    local reply = bounds.object(raw)
    if err or not reply or reply.ok ~= true then
        local fault = reply and bounds.object(reply.error)
        return fail(tostring(err or (fault and fault.message) or "session is not visible"))
    end
    local owner = process.registry.lookup(OWNER .. session)
    if not owner then return fail("the session has no live terminal") end
    return rpc(tostring(owner), {op = request.detach == true and "detach" or "attach"})
end
local function run(value: unknown, name: unknown, initial_token: string, operation_key: string)
    local request, err = admission.decode_request(value)
    if not request or type(name) ~= "string" or name ~= OWNER .. request.request_id then error(err or "invalid presentation owner") end
    local requests = assert(process.listen(TOPIC, {message = true}))
    local events = assert(process.events())
    assert(process.registry.register(name))
    local admitted, refused = admission.admit_request(request, operation_key)
    if not admitted or not admitted.session_ref then error(tostring(refused and refused.error and refused.error.message or "window was not admitted")) end
    local session = admitted.session_ref
    local alias = OWNER .. session
    assert(process.registry.register(alias))
    local view = assert(tty.viewport({width = 80, height = 24}))
    local grant = assert(view:grant())
    local encoded = assert(json.encode({request_id = request.request_id, definition_ref = request.definition_ref,
        brief = "", workdir = request.workdir, expected_plan_digest = request.expected_plan_digest,
        saved_profile_id = request.saved_profile_id, saved_profile_revision = request.saved_profile_revision,
        thread_id = admitted.thread_id}))
    local pid = assert(process.with_options({terminal = grant}):spawn_monitored("bee.harness.service:presentation_executor", "bee:workers", {
        version = 1, broker_pid = process.pid(), workspace_pid = process.pid(), workspace_id = request.workspace_id,
        instance_id = request.request_id, view_id = request.request_id, definition_id = "bee.harness.app:app",
        execution_generation = 1, definition_revision = "1", registry_revision = "1", launch_token = request.request_id,
        resume_schema = "bee.agent.window@1", resume_state = "", arguments = {encoded}}, operation_key))
    local function opened(token: string)
        local raw, lookup_error = funcs.call("bee.threads.service:operation_lookup", {operation_key = operation_key})
        local lookup = bounds.object(raw)
        local result = lookup and bounds.object(lookup.value)
        local reply: Object
        if lookup_error or not lookup or lookup.ok ~= true or not result then reply = fail("window receipt unavailable")
        else reply = {ok = true, value = result.receipt} end
        reply.caller_token = token
        local caller = process.registry.lookup(token)
        if caller then process.send(caller, REPLY, reply) end
    end
    opened(initial_token)
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
            if body.op == "open" then
                local supplied, decode_error = admission.decode_request(body.request)
                local expected = assert(canonical.encode(request, 16384, 16))
                local candidate = supplied and canonical.encode(supplied, 16384, 16)
                if not supplied or candidate ~= expected or body.operation_key ~= operation_key then reply = fail(decode_error or "window operation key changed")
                else
                    local raw, lookup_error = funcs.call("bee.threads.service:operation_lookup", {operation_key = operation_key})
                    local lookup = bounds.object(raw)
                    local result = lookup and bounds.object(lookup.value)
                    if lookup_error or not lookup or lookup.ok ~= true or not result then reply = fail("window receipt unavailable")
                    else reply = {ok = true, value = result.receipt} end
                end
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
    process.registry.unregister(alias, process.registry.LOCAL)
    process.registry.unregister(name, process.registry.LOCAL)
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
