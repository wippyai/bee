-- MIT. Terminal-window message delivery for session owners: a queued message
-- is typed into the agent's terminal once the agent has ended a turn, and the
-- launch prompt, idle check and hook boundary carry a window's agent through
-- its turns.
local bounds = require("bounds")
local json = require("json")
local journal = require("journal")
local hash = require("hash")
local canonical = require("canonical")
local security = require("security")
local funcs = require("funcs")
local cancellation = require("cancellation")
local replies = require("replies")
local M = {}
type Object = replies.Object
type Reply = replies.Reply
local object = replies.object
local fail = replies.fail
local unavailable = replies.unavailable
local succeed = replies.succeed
local request_input = replies.request_input
local identity = replies.identity
local key = replies.key
local ref = replies.ref
local describe = replies.describe
local TYPE = "bee.harness.binding:present_type"
local RESUME = "bee.harness.binding:present_restore"
local ACTIVITY = "bee.harness.binding:present_activity"

-- The turn's result is the agent's final message; a harness whose stop
-- carries no message ended its turn with the reply only on its screen.
local function reply_of(answer: unknown): string
    if type(answer) == "string" then return answer end
    return "The agent ended its turn; its reply is shown in its terminal"
end

-- prompt_text is a message's input as the text typed for it.
local function prompt_text(value: unknown): string?
    if type(value) == "string" then return value end
    return (canonical.encode(value, 16384, 16))
end

-- marker opens the sender line Bee types above a turn's message. It names the
-- turn by a digest of its ref, which the agent's submitted prompt carries in
-- whatever form its terminal renders pasted text.
local function marker(turn: string): string
    return "[Bee message #" .. assert(hash.sha256(turn)):sub(1, 12)
end

-- message_text is what a queued message types into the agent's prompt: the
-- turn's sender line, naming a sender other than the session the way
-- Sessions lists it, above the message.
local function message_text(turn: string, input: unknown, sender: Object?, session: string): string?
    local prompt = prompt_text(input)
    if not prompt then return nil end
    if not sender or sender.id == session then return marker(turn) .. "]\n" .. prompt end
    local name = tostring(sender.id)
    if sender.kind == "session" then
        local current = describe(name)
        local title = current and bounds.text(current.title, 512)
        if title and title ~= "" then name = title end
    end
    if #name > 60 then name = name:sub(1, 57) .. "..." end
    return marker(turn) .. " from " .. name .. "]\n" .. prompt
end

-- typed_for is whether the prompt the agent submitted is the message Bee typed
-- for the turn: it carries that turn's sender line.
local function typed_for(submitted: string, turn: string): boolean
    local start = marker(turn)
    local at = submitted:find(start, 1, true)
    local after = at and submitted:sub(at + #start, at + #start)
    return after == "]" or after == " "
end

-- claimed is the active turn's current claim, recovered after an owner restart.
local function claimed(active: Object, operation_key: string): (string?, string?)
    local recovered, recovery_error = journal.invoke("turn_recover", {turn = active.turn, operation_key = operation_key})
    local claim = object(recovered)
    local value = claim and bounds.text(claim.claim, 128)
    if recovery_error or not value then return nil, recovery_error or "the turn's claim is unavailable" end
    return value, nil
end

-- launch_prompt hands a window that starts its agent the message waiting for
-- it: the reserved message, or the next queued one, which it reserves. The
-- agent takes it as its launch prompt, so nothing is typed into a terminal
-- that is still starting. A session with nothing waiting has no prompt.
function M.launch_prompt(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    local session = ref(request.session)
    if not session or bounds.fields(request, {"session"}) then return fail("INVALID", "launch_prompt needs one session ref") end
    local raw, read_error = journal.invoke("session_describe", {session = session})
    local stored = object(raw)
    local route = stored and object(stored.route)
    if read_error or not stored or not route then return unavailable(read_error or "session is unavailable", nil) end
    if route.delivery ~= "hook" then return fail("INVALID", "only a window session starts a terminal") end
    local definition = ref(route.definition)
    if not definition or not security.can("bee.sessions.attach", definition) then return fail("DENIED", "a launch prompt requires a host grant") end
    if stored.state ~= "active" then return succeed({}) end
    local active = object(stored.active_turn)
    local turn: string? = nil
    local claim: string? = nil
    if active then
        if active.phase ~= "reserved" then return succeed({}) end
        local current, claim_error = claimed(active, "launch-recover:" .. tostring(route.native_attempt_id))
        if not current then return unavailable(claim_error or "the waiting message's claim is unavailable", nil) end
        turn, claim = tostring(active.turn), current
    else
        local reserved, reserve_error = journal.invoke("turn_reserve", {session = session,
            operation_key = "launch:" .. tostring(route.native_attempt_id) .. ":" .. tostring(stored.head_sequence)})
        local next_turn = object(reserved)
        if reserve_error or not next_turn then return unavailable(reserve_error or "the next message could not be reserved", nil) end
        if not next_turn.turn then return succeed({}) end
        turn, claim = tostring(next_turn.turn), tostring(next_turn.claim)
    end
    local pulled, pull_error = journal.invoke("turn_pull", {turn = turn, claim = claim})
    local input = object(pulled)
    local text = input and message_text(assert(turn), input.input, object(input.sender), session)
    if pull_error or not input or not text then return unavailable(pull_error or "the waiting message is unreadable", nil) end
    return succeed({prompt = text})
end

-- idle_check tells a window whether it may stop its agent: no turn is in
-- flight, nothing waits, and the placement proves the agent alive with no
-- work of its own. A placement that cannot count that work keeps it running.
function M.idle_check(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    local session = ref(request.session)
    if not session or bounds.fields(request, {"session"}) then return fail("INVALID", "idle_check needs one session ref") end
    local raw, read_error = journal.invoke("session_describe", {session = session})
    local stored = object(raw)
    local route = stored and object(stored.route)
    if read_error or not stored or not route then return unavailable(read_error or "session is unavailable", nil) end
    if route.delivery ~= "hook" then return fail("INVALID", "only a window session runs a terminal") end
    local definition = ref(route.definition)
    if not definition or not security.can("bee.sessions.attach", definition) then return fail("DENIED", "an idle check requires a host grant") end
    if stored.state ~= "active" or stored.active_turn ~= nil or bounds.integer(stored.queued) ~= 0 then return succeed({stop = false}) end
    local attempt = bounds.id(route.native_attempt_id)
    if not attempt then return succeed({stop = false}) end
    return succeed({stop = cancellation.quiet(route.placement_methods, attempt, route)})
end

-- deliver types the session's next queued message into its terminal once
-- that terminal's agent has ended a turn, which proves its input takes typed
-- messages. Until then the message waits: a terminal that is gone or
-- suspended is resumed, and a starting terminal takes the waiting message as
-- its launch prompt (launch_prompt). A message the terminal cannot take
-- settles as failed with the reason.
function M.deliver(session: string, key_seed: string): string?
    local raw, read_error = journal.invoke("session_describe", {session = session})
    local stored = object(raw)
    local route = stored and object(stored.route)
    if read_error or not stored or not route then return read_error or "the session is unavailable" end
    if route.delivery ~= "hook" then return nil end
    -- resume makes sure the session's terminal runs; one already running is
    -- left as it is.
    local function resume(): string?
        local resumed, resume_error = funcs.call(RESUME, {session = session})
        local reply = object(resumed)
        if resume_error or not reply or reply.ok ~= true then
            local fault = reply and object(reply.error)
            return tostring(resume_error or (fault and fault.message) or "the session's terminal could not resume")
        end
        return nil
    end
    if stored.state == "suspended" then return resume() end
    if stored.state ~= "active" then return nil end
    local active = object(stored.active_turn)
    -- A reserved turn waits for a terminal; one that is gone, as after a
    -- restart, is resumed and takes it as its launch prompt.
    if active then
        if active.phase == "reserved" then return resume() end
        return nil
    end
    if stored.attempt_turn_ended ~= true then return resume() end
    local reserved, reserve_error = journal.invoke("turn_reserve", {session = session, operation_key = "deliver:" .. key_seed})
    local next_turn = object(reserved)
    if reserve_error or not next_turn then return reserve_error or "the next message could not be reserved" end
    if not next_turn.turn then
        -- Nothing waits: the window may stop an agent nobody uses.
        local _, idle_error = funcs.call(ACTIVITY, {session = session, state = "idle"})
        if idle_error then return tostring(idle_error) end
        return nil
    end
    local turn, claim = tostring(next_turn.turn), tostring(next_turn.claim)
    local pulled, pull_error = journal.invoke("turn_pull", {turn = turn, claim = claim})
    local input = object(pulled)
    local text = input and message_text(turn, input.input, object(input.sender), session)
    if pull_error or not input or not text then return pull_error or "the queued message is unreadable" end
    local typed, type_error = funcs.call(TYPE, {session = session, text = text})
    local reply = object(typed)
    if not type_error and reply and reply.ok == true then return nil end
    local fault = reply and object(reply.error)
    local reason = tostring(type_error or (fault and fault.message) or "no reply")
    -- Only accepted work settles, so the undelivered turn is accepted first,
    -- as a cancellation before any executor started is.
    local _, accept_error = journal.invoke("turn_accept", {turn = turn, claim = claim, input_digest = input.input_digest,
        checkpoint = {attempt_id = tostring(route.native_attempt_id or turn)}, operation_key = "deliver-accept:" .. key_seed})
    if accept_error then return accept_error end
    local _, settle_error = journal.invoke("work_settle", {turn = turn, claim = claim, operation_key = "deliver-failed:" .. key_seed,
        result = {state = "failed", error = {code = "UNDELIVERED", message = "The session's terminal could not take the message: " .. reason}}})
    return settle_error
end

function M.hook_boundary(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    local caller = identity()
    local session, event, event_key = ref(request.session), request.event, key(request.operation_key)
    local attempt = bounds.id(request.attempt_id)
    if not session or caller ~= session or not event_key or not attempt or bounds.fields(request, {"session", "binding_id", "event", "operation_key", "attempt_id", "permission", "input", "answer", "hook_payload"})
        or (event ~= "SessionStart" and event ~= "UserPromptSubmit" and event ~= "PreToolUse" and event ~= "PostToolUse" and event ~= "Stop" and event ~= "StopFailure" and event ~= "PermissionRequest") then return fail("INVALID", "hook boundary identity is invalid", event_key) end
    if request.input ~= nil and (event ~= "UserPromptSubmit" or bounds.text(request.input, 65536) == nil) then return fail("INVALID", "native prompt is invalid", event_key) end
    if request.answer ~= nil and (event ~= "Stop" or bounds.text(request.answer, 65536) == nil) then return fail("INVALID", "the agent's reply is invalid", event_key) end
    if not security.can("bee.sessions.hook_boundary", session) then return fail("DENIED", "hook boundary requires the authenticated gateway", event_key) end
    local raw, err = journal.invoke("session_describe", {session = session})
    local stored = object(raw)
    local route = stored and object(stored.route)
    if err or not route then return unavailable(err or "interactive route unavailable", event_key) end
    if route.delivery ~= "hook" then
        if event == "Stop" or event == "StopFailure" then return succeed({}) end
        local binding = bounds.id(request.binding_id)
        if not binding then return fail("INVALID", "managed hook has no binding", event_key) end
        local target = event == "PermissionRequest" and "bee.harness.binding:permission_hook" or "bee.harness.binding:extension_hook"
        local raw, failure = funcs.call(target, {binding_id = binding, event_id = event_key, payload = request.hook_payload})
        local reply = bounds.object(raw)
        if failure or not reply or reply.ok ~= true then
            local fault = reply and bounds.object(reply.error)
            return unavailable(tostring(failure or (fault and fault.message) or "managed hook unavailable"), event_key)
        end
        return succeed(reply.value)
    end
    if route.native_attempt_id ~= attempt then return fail("STALE", "hook belongs to an earlier native attachment", event_key) end
    local extension_response: Object? = nil
    local points = {SessionStart = "session.start", UserPromptSubmit = "prompt.submit", PreToolUse = "tool.before", PostToolUse = "tool.after"}
    local point = points[tostring(event)]
    if point then
        local payload = bounds.object(request.hook_payload) or {}
        local tool_input: unknown = payload.tool_input
        local tool_output: unknown = payload.tool_response
        if type(tool_input) == "string" then tool_input = json.decode(tool_input) end
        local active_turn = bounds.object(stored.active_turn)
        local response, failure = funcs.call("bee.threads.hooks:dispatch", {session_ref = session, thread_id = stored.thread_ref,
            workspace_id = stored.workspace, point = point, occurrence_id = event_key, turn_ref = active_turn and active_turn.turn,
            tool_name = payload.tool_name, tool_call_id = payload.tool_use_id, input = tool_input, output = tool_output, text = request.input})
        local reply = bounds.object(response)
        if failure or not reply or reply.ok ~= true then
            local fault = reply and bounds.object(reply.error)
            return unavailable(tostring(failure or (fault and fault.message) or "hook dispatcher unavailable"), event_key)
        end
        extension_response = assert(bounds.object(reply.value))
        if extension_response.denied == true then
            if event == "UserPromptSubmit" and active_turn and active_turn.phase == "reserved" then
                local current, claim_error = claimed(active_turn, "hook-deny:" .. event_key)
                if not current then return unavailable(claim_error or "denied turn recovery unavailable", event_key) end
                local pulled, pull_error = journal.invoke("turn_pull", {turn = active_turn.turn, claim = current})
                local input = bounds.object(pulled)
                if pull_error or not input then return unavailable(pull_error or "denied turn input unavailable", event_key) end
                local _, accept_error = journal.invoke("turn_accept", {turn = active_turn.turn, claim = current, input_digest = input.input_digest,
                    checkpoint = {attempt_id = attempt}, operation_key = "hook-deny-accept:" .. event_key})
                if accept_error then return unavailable(accept_error, event_key) end
                local _, settle_error = journal.invoke("work_settle", {turn = active_turn.turn, claim = current, operation_key = "hook-deny-settle:" .. event_key,
                    result = {state = "rejected", error = {code = "HOOK_DENIED", message = extension_response.reason}}})
                if settle_error then return unavailable(settle_error, event_key) end
            end
            return succeed({extension_response = extension_response, hook_driver = route.provider})
        end
        if event ~= "UserPromptSubmit" then return succeed({extension_response = extension_response, hook_driver = route.provider}) end
    end
    if event == "PermissionRequest" then
        local permission = bounds.object(request.permission)
        local active = bounds.object(stored.active_turn)
        if not permission then return fail("INVALID", "permission hook omitted its request", event_key) end
        local fields: Object = {session = session, definition = route.definition, plan_digest = route.plan_digest,
            driver_binding_ref = route.driver_binding_ref, profile_id = route.profile_id, effective_profile = route.effective_profile,
            attempt_id = attempt, thread_id = stored.thread_ref, action_id = permission.action_id, binding_id = permission.binding_id,
            turn = active and active.turn, claim = active and active.claim, event_id = event_key, payload = permission.payload,
            saved_profile_id = route.saved_profile_id, saved_profile_revision = route.saved_profile_revision, transport = permission.transport}
        local response, response_error = funcs.call("bee.harness.permission.external.binding:answer_hook", fields)
        if response_error then return unavailable(tostring(response_error), event_key) end
        local reply = bounds.object(response)
        if not reply or type(reply.ok) ~= "boolean" then return unavailable("invalid permission hook reply", event_key) end
        if reply.ok ~= true then
            local fault = bounds.object(reply.error)
            return fail("PERMISSION_REFUSED", fault and bounds.text(fault.message, 4096) or "permission hook refused", event_key)
        end
        return succeed(reply.value)
    end
    local event_digest, digest_error = hash.sha256(event_key)
    if not event_digest then return unavailable(tostring(digest_error), event_key) end
    local boundary_key = event_digest
    local active = object(stored.active_turn)
    if event ~= "UserPromptSubmit" then
        if not active or active.phase ~= "accepted" then return succeed({}) end
        local claim, claim_error = claimed(active, "hook-recover:" .. boundary_key)
        if not claim then return unavailable(claim_error or "interactive recovery unavailable", event_key) end
        local pulled, pull_error = journal.invoke("turn_pull", {turn = active.turn, claim = claim})
        local turn = object(pulled)
        local checkpoint = turn and object(turn.checkpoint)
        if pull_error or not checkpoint then return unavailable(pull_error or "interactive checkpoint unavailable", event_key) end
        if checkpoint.attempt_id ~= attempt then return succeed({}) end
        local settled, settle_error = journal.invoke("work_settle", {turn = active.turn, claim = claim,
            operation_key = "hook-stop:" .. boundary_key, result = event == "Stop" and {state = "succeeded", schema = "bee:Text@1", value = {text = reply_of(request.answer)}}
                or {state = "failed", error = {code = "INTERACTIVE_FAILED", message = "Interactive turn failed"}}})
        if settle_error or not settled then return unavailable(settle_error or "interactive turn settlement unavailable", event_key) end
        local problem = M.deliver(session, "after:" .. boundary_key)
        if problem then return unavailable(problem, event_key) end
        return succeed({})
    end
    -- A prompt the agent submits is either the message Bee typed for the
    -- reserved turn, which accepts that turn, or the person's own prompt,
    -- which becomes the session's work when no turn is in flight.
    local turn_ref: string? = nil
    local claim: string? = nil
    if active and active.phase == "reserved" then
        local current, claim_error = claimed(active, "hook-recover:" .. boundary_key)
        if not current then return unavailable(claim_error or "interactive recovery unavailable", event_key) end
        local pulled, pull_error = journal.invoke("turn_pull", {turn = active.turn, claim = current})
        local typed = object(pulled)
        if pull_error or not typed then return unavailable(pull_error or "interactive turn input unavailable", event_key) end
        if type(request.input) ~= "string" or not typed_for(request.input, tostring(active.turn)) then return succeed({extension_response = extension_response, hook_driver = extension_response and route.provider or nil}) end
        turn_ref, claim = tostring(active.turn), current
    elseif not active and request.input ~= nil then
        local sent, send_error = journal.invoke("work_send", {session = session, operation_key = "hook-native:" .. boundary_key,
            input = request.input, output_schema = "bee:Text@1"})
        local native_work = object(sent)
        if send_error or not native_work then return unavailable(send_error or "native prompt journal unavailable", event_key) end
        local reserved, reserve_error = journal.invoke("turn_reserve", {session = session, work = native_work.work,
            operation_key = "hook-native-start:" .. boundary_key})
        local native = object(reserved)
        if reserve_error or not native then return unavailable(reserve_error or "native prompt turn unavailable", event_key) end
        if not native.turn then return succeed({extension_response = extension_response, hook_driver = extension_response and route.provider or nil}) end
        turn_ref, claim = tostring(native.turn), tostring(native.claim)
    else
        return succeed({extension_response = extension_response, hook_driver = extension_response and route.provider or nil})
    end
    local pulled, pull_error = journal.invoke("turn_pull", {turn = turn_ref, claim = claim})
    local input = object(pulled)
    if pull_error or not input then return unavailable(pull_error or "interactive turn input unavailable", event_key) end
    if input.phase == "settled" then return succeed({extension_response = extension_response, hook_driver = extension_response and route.provider or nil}) end
    local accepted, accept_error = journal.invoke("turn_accept", {turn = turn_ref, claim = claim, input_digest = input.input_digest,
        checkpoint = {attempt_id = route.native_attempt_id, hook_event = event_key}, operation_key = "hook-accept:" .. boundary_key})
    if accept_error or not accepted then return unavailable(accept_error or "interactive turn accept unavailable", event_key) end
    return succeed({extension_response = extension_response, hook_driver = extension_response and route.provider or nil})
end
return M
