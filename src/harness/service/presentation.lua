-- MIT. Retained presentation uses the admitted window executor and hooks.
local ctx = require("ctx")
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local hash = require("hash")
local security = require("security")
local funcs = require("funcs")
local json = require("json")
local tty = require("tty")
local eventbus = require("events")
local bounds = require("bounds")
local admission = require("admission")
local setup = require("setup")
local canonical = require("canonical")
local recovery = require("recovery")
local principal = require("principal")
local viewer = require("viewer")
local M = {}
local OWNER = "bee.session.window/"
local CALLER = "bee.session.viewer/"
local TOPIC = "bee.session.window.request"
local REPLY = "bee.session.window.reply"
local REVIEW = "bee.session.window.review"
local env = require("env")
local logger = require("logger")
-- idle_period is the host's idle period for an unused agent, a duration such
-- as "24h"; an empty value keeps agents running until their session closes.
local function idle_period(): string?
    local configured = env.get("bee.harness.service:session_idle_stop")
    if type(configured) ~= "string" or configured == "" then return nil end
    local probe = time.timer(configured)
    if not probe then
        logger:warn("Session idle period is not a duration", {value = configured})
        return nil
    end
    probe:stop()
    return configured
end
type Object = {[string]: unknown}
local function fail(message: string): Object return {ok = false, error = {code = "UNAVAILABLE", message = message}} end
-- A window runs as its own application principal, named by the request that
-- first admitted it, so its session, thread membership and operation keys
-- belong to the window: any viewer in the workspace can reopen it.
type Window = {actor: security.Actor, workspace: string, trait_ceiling: {string}?}
local function window(workspace: string, request_id: string, trait_ceiling: {string}?): Window?
    local value = principal.value(workspace, request_id, "bee.harness.app:app", "1", 1)
    local actor = value and security.new_actor(value.id, value.metadata)
    if not actor then return nil end
    return {actor = actor, workspace = workspace, trait_ceiling = trait_ceiling}
end
local rpc = viewer.rpc

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
        profile and bounds.id(profile.id), profile and bounds.integer(profile.revision), nil, nil, nil, nil, spec.overrides)
    if not plan then return refused or fail("window plan unavailable") end
    local prepared = setup.run(plan, workspace, spec.workdir)
    if prepared.ok ~= true then return fail(tostring(prepared.error or "window setup failed")) end
    local request, request_error = admission.decode_request({request_id = digest, definition_ref = plan.definition_ref,
        workspace_id = workspace, brief = "", mode = "window", workdir = prepared.workdir,
        saved_profile_id = plan.saved_profile_id, saved_profile_revision = plan.saved_profile_revision,
        expected_plan_digest = plan.plan_digest, overrides = spec.overrides})
    if not request then return fail(request_error or "window admission request invalid") end
    local name = OWNER .. digest
    local owner = process.registry.lookup(name)
    local reply: Object
    if owner then reply = rpc(tostring(owner), {op = "open", request = request, operation_key = operation_key})
    else
        local owner_window = window(workspace, digest, bounds.ids(ctx.get("bee.agent.trait_ceiling"), true))
        if not owner_window then return fail("window principal could not be created") end
        reply = rpc(nil, {op = "open", request = request, operation_key = operation_key}, request, name, operation_key, owner_window)
    end
    -- The session runs whether or not anyone watches it; the person opens its
    -- terminal from Agents.
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
    if live then return rpc(tostring(live), {op = "start"}) end
    local raw, err = funcs.call("bee.threads.sessions.binding:restore", {session = session})
    local reply = bounds.object(raw)
    if err or not reply or reply.ok ~= true then
        local fault = reply and bounds.object(reply.error)
        return fail(tostring(err or (fault and fault.message) or "the window cannot be restored"))
    end
    local facts = bounds.object(reply.value)
    local saved, saved_error = recovery.decode(facts and {definition_ref = facts.definition_ref, plan_digest = facts.plan_digest,
        origin_request_id = facts.origin_request_id, previous_attempt_id = facts.previous_attempt_id, thread_id = facts.thread_id, overrides = facts.overrides,
        saved_profile_id = facts.saved_profile_id, saved_profile_revision = facts.saved_profile_revision})
    if not saved then return fail(saved_error or "the window restore facts are malformed") end
    local actor = security.actor()
    local meta = actor and bounds.object(actor:meta())
    local workspace = meta and bounds.id(meta.workspace_id)
    if not workspace then return fail("window restore identity is missing") end
    local operation_key = bounds.text(facts and facts.operation_key, 128)
    if not operation_key or operation_key == "" then return fail("the window restore facts omit the session key") end
    -- The window reopens as the principal that owns its session and admits the
    -- continuation under the key that created it, so admission attaches the
    -- same session.
    local owner = bounds.id(facts and facts.owner_id)
    local prefix = "bee.application:" .. workspace .. ":"
    local instance = owner and owner:sub(1, #prefix) == prefix and owner:sub(#prefix + 1) or nil
    if not instance or instance == "" then return fail("the window session is not owned by an application of this workspace") end
    local owner_window = window(workspace, instance, bounds.ids(facts and facts.trait_ceiling, true))
    if not owner_window then return fail("window principal could not be created") end
    return rpc(nil, {op = "resume"}, {resume = saved, session = session, workspace_id = workspace}, OWNER .. session, operation_key, owner_window)
end

-- type delivers a message into a session's terminal. A terminal that is gone
-- or not started yet starts instead; its agent takes the waiting message as
-- its launch prompt.
function M.type(value: unknown): Object
    local body = bounds.object(value)
    local session = body and bounds.id(body.session)
    local text = body and bounds.text(body.text, 65536)
    if not body or not session or not text or bounds.fields(body, {"session", "text"}) then return fail("invalid window message") end
    local owner = process.registry.lookup(OWNER .. session)
    if not owner then
        local restored = M.restore({session = session})
        if restored.ok ~= true then return restored end
        return {ok = true, value = {typed = false}}
    end
    return rpc(tostring(owner), {op = "type", text = text})
end

-- activity tells a session's window whether its agent is working, from the
-- turn it accepted, or idle, after its turn ended with nothing waiting. A
-- window that is not running has nothing to keep or stop.
function M.activity(value: unknown): Object
    local body = bounds.object(value)
    local session = body and bounds.id(body.session)
    local state = body and body.state
    if not body or not session or bounds.fields(body, {"session", "state"}) or (state ~= "working" and state ~= "idle") then
        return fail("invalid window activity report")
    end
    local owner = process.registry.lookup(OWNER .. session)
    if not owner then return {ok = true, value = {}} end
    return rpc(tostring(owner), {op = state})
end

M.attach = viewer.attach

-- start spawns the window executor on a fresh viewport and returns both.
local function start(workspace_id: string, request_id: string, arguments: {string}, resume_state: string, operation_key: string, admitted: admission.Admitted?): (tty.Viewport, string)
    local view = assert(tty.viewport({width = 80, height = 24}))
    local grant = assert(view:grant())
    local pid = assert(process.with_options({terminal = grant})
        :with_context({["bee.workspace_id"] = workspace_id, ["bee.agent.trait_ceiling"] = ctx.get("bee.agent.trait_ceiling")})
        :spawn_linked_monitored("bee.harness.service:presentation_executor", "bee:workers", {
        version = 1, broker_pid = process.pid(), workspace_pid = process.pid(), workspace_id = workspace_id,
        instance_id = request_id, view_id = request_id, definition_id = "bee.harness.app:app",
        execution_generation = 1, definition_revision = "1", registry_revision = "1", launch_token = request_id,
        resume_schema = recovery.SCHEMA, resume_state = resume_state, arguments = arguments}, operation_key, admitted))
    return view, tostring(pid)
end
local function run(value: unknown, name: unknown, initial_token: string, operation_key: string, supervisor: string)
    local requests = assert(process.listen(TOPIC, {message = true}))
    local events = assert(process.events())
    local attention = assert(eventbus.subscribe("bee.attention"))
    local self_actor = security.actor()
    local self_id = self_actor and self_actor:id() or ""
    local thread_id: string? = nil
    local request_body = bounds.object(value)
    local restoring = request_body and bounds.object(request_body.resume)
    local request: admission.Request? = nil
    local aliases: {string} = {}
    local session_ref: string? = nil
    local view: tty.Viewport? = nil
    local pid: string? = nil
    -- launch starts the window executor once; an opened session's agent
    -- starts when it is first needed: a message for it, or a viewer.
    local launch: (() -> ())? = nil
    local function ensure_started()
        if view or not launch then return end
        launch()
    end
    local function reply_to(token: string, reply: Object)
        reply.caller_token = token
        process.send(supervisor, REPLY, reply)
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
        session_ref = session
        thread_id = saved.thread_id
        local encoded = assert(recovery.encode(saved))
        view, pid = start(workspace, assert(uuid.v7()), {}, encoded, operation_key)
        reply_to(initial_token, {ok = true, value = {session = session}})
    else
        local decoded, err = admission.decode_request(value)
        if not decoded or type(name) ~= "string" or name ~= OWNER .. decoded.request_id then error(err or "invalid presentation owner") end
        request = decoded
        assert(process.registry.register(name))
        local admitted, refused = admission.admit_request(decoded, operation_key)
        if not admitted or not admitted.session_ref then error(tostring(refused and refused.error and refused.error.message or "window was not admitted")) end
        local alias = OWNER .. admitted.session_ref
        session_ref = admitted.session_ref
        thread_id = admitted.thread_id
        assert(process.registry.register(alias))
        aliases = {name, alias}
        local encoded = assert(json.encode({request_id = decoded.request_id, definition_ref = decoded.definition_ref,
            brief = "", workdir = decoded.workdir, overrides = decoded.overrides, expected_plan_digest = decoded.expected_plan_digest,
            saved_profile_id = decoded.saved_profile_id, saved_profile_revision = decoded.saved_profile_revision,
            thread_id = admitted.thread_id}))
        launch = function() view, pid = start(decoded.workspace_id, decoded.request_id, {encoded}, "", operation_key, admitted) end
        reply_to(initial_token, receipt())
    end
    local mount: string? = nil
    local recipient: string? = nil
    -- The request waiting for the person on this session's behalf: one its
    -- thread is bound to, or one this window asked for while it starts. The
    -- attached viewer shows it until the request settles.
    local review: {approval_id: string, title: string}? = nil
    local function show_review()
        if recipient then process.send(recipient, REVIEW, {review = review or false}) end
    end
    local function attend(event: {[string]: unknown})
        local next_review, changed = viewer.review(review, event, thread_id, self_id)
        if changed then
            review = next_review
            show_review()
        end
    end
    -- An agent nobody uses stops after the host's idle period: idle since its
    -- last turn ended with nothing waiting, and no viewer attached. A message,
    -- a start or a viewer keeps it running; the next message resumes it.
    local idle = false
    local idle_after = idle_period()
    local idle_timer: time.Timer? = nil
    local function disarm()
        if idle_timer then idle_timer:stop() end
        idle_timer = nil
    end
    local function arm()
        if idle and not recipient and pid and not idle_timer and idle_after then idle_timer = time.timer(idle_after) end
    end
    while true do
        local cases = {requests:case_receive(), events:case_receive(), attention:channel():case_receive()}
        local stopping = idle_timer
        if stopping then cases[#cases + 1] = stopping:channel():case_receive() end
        local event = channel.select(cases)
        if not event.ok then break end
        if stopping and event.channel == stopping:channel() then
            idle_timer = nil
            -- Sessions decides at this moment: no turn, nothing waiting and
            -- no work the agent still runs of its own; otherwise it keeps
            -- running for another idle period.
            local raw, check_error = funcs.call("bee.threads.sessions.binding:idle_check", {session = session_ref})
            local checked = bounds.object(raw)
            local verdict = checked and checked.ok == true and bounds.object(checked.value) or nil
            if pid and not check_error and verdict and verdict.stop == true then
                process.cancel(pid, "session idle")
            else
                if check_error or not verdict then logger:warn("Session idle check unavailable", {session = session_ref, cause = tostring(check_error)}) end
                arm()
            end
        elseif event.channel == attention:channel() then
            attend(event.value)
        elseif event.channel == events then
            if pid and event.value.kind == process.event.EXIT and tostring(event.value.from) == pid then break end
            if event.value.kind == process.event.CANCEL then
                if not pid then break end
                process.cancel(pid, "session owner stopping")
            end
        else
            local sender = tostring(event.value:from())
            local body = bounds.object(event.value:payload():data())
            local token = body and bounds.id(body.caller_token)
            if not body or bounds.fields(body, {"op", "request", "caller_token", "operation_key", "text"}) or not token or token:sub(1, #CALLER) ~= CALLER
                or tostring(process.registry.lookup(token)) ~= sender then goto next_request end
            local reply: Object
            if body.op == "open" and request then
                local supplied, decode_error = admission.decode_request(body.request)
                local expected = assert(canonical.encode(request, 16384, 16))
                local candidate = supplied and canonical.encode(supplied, 16384, 16)
                if not supplied or candidate ~= expected or body.operation_key ~= operation_key then reply = fail(decode_error or "window operation key changed")
                else reply = receipt() end
            elseif body.op == "idle" then
                idle = true
                arm()
                reply = {ok = true, value = {}}
            elseif body.op == "working" then
                idle = false
                disarm()
                reply = {ok = true, value = {}}
            elseif body.op == "start" then
                idle = false
                disarm()
                ensure_started()
                reply = {ok = true, value = {}}
            elseif body.op == "attach" then
                idle = false
                disarm()
                ensure_started()
                local current = assert(view)
                if mount then assert(current:revoke(mount)) end
                mount = assert(current:mount(sender, {observe = true, input = true, resize = true}))
                recipient = sender
                reply = {ok = true, value = {mount = mount}}
            elseif body.op == "type" and bounds.text(body.text, 65536) then
                idle = false
                disarm()
                if not view then
                    -- A terminal that has not started takes the waiting
                    -- message as its agent's launch prompt.
                    ensure_started()
                    reply = {ok = true, value = {typed = false}}
                else
                    -- The message reaches the agent the way a person's typing
                    -- does: pasted into its prompt, then submitted.
                    local pasted, paste_error = view:send({type = "paste", text = tostring(body.text)})
                    local entered, enter_error = nil, nil
                    if pasted then entered, enter_error = view:send({type = "key", key = "enter", key_type = "enter", action = "press"}) end
                    if entered then reply = {ok = true, value = {typed = true}}
                    else reply = fail("the terminal did not take the message: " .. tostring(paste_error or enter_error)) end
                end
            elseif body.op == "detach" and recipient == sender then
                if mount and view then assert(view:revoke(mount)) end
                mount, recipient = nil, nil
                arm()
                reply = {ok = true, value = {}}
            else reply = fail("invalid window operation") end
            reply.caller_token = token
            process.send(sender, REPLY, reply)
            if body.op == "attach" and review then show_review() end
        end
        ::next_request::
    end
    disarm()
    attention:close()
    if view then view:close() end
    for _, registered in ipairs(aliases) do process.registry.unregister(registered, process.registry.LOCAL) end
end
function M.main(value: unknown, name: unknown, initial_token: unknown, operation_key: unknown, supervisor: string)
    assert(supervisor == tostring(process.registry.lookup("bee.harness.presentation", process.registry.LOCAL)), "presentation supervisor is missing")
    local token = bounds.id(initial_token)
    if not token or token:sub(1, #CALLER) ~= CALLER then error("invalid window caller token") end
    local key = bounds.text(operation_key, 128)
    if not key or key == "" then error("invalid presentation operation key") end
    local ok, err = pcall(run, value, name, token, key, supervisor)
    if not ok then
        local reply = fail(tostring(err))
        reply.caller_token = token
        process.send(supervisor, REPLY, reply)
        error(tostring(err))
    end
end
return M
