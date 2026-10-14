local sql = require("sql")
local json = require("json")
local registry = require("registry")
local funcs = require("funcs")
local security = require("security")
local uuid = require("uuid")
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local database = require("database")
local transaction = require("transaction")
local traits = require("traits")
local application = require("application")
local capabilities = require("capabilities")
local supervisor = require("supervisor")
local events = require("events")
local channel = require("channel")
local time = require("time")
local M = {}
type Object = {[string]: unknown}
type Request = {session_ref: string, thread_id: string, workspace_id: string, point: string, occurrence_id: string,
    turn_ref: string?, tool_name: string?, tool_call_id: string?, input: unknown?, output: unknown?, text: string?}
type Result = {input: unknown?, output: unknown?, text: string?, additional_context: string, denied: boolean, reason: string?, changed: boolean, original_refs: {string}}
type Invocation = {id: string, selection: traits.Selection, replay: Object?, pending: boolean, waiting: boolean}
local function contains(items: {string}?, point: string): boolean
    for _, item in ipairs(items or {}) do if item == point then return true end end
    return false
end
local function session_driver(tx: sql.Transaction, request: Request): (string?, string?)
    local rows, err = tx:query("SELECT route_json,state FROM bee_sessions WHERE session_ref=? AND thread_id=? AND workspace_id=?",
        {request.session_ref, request.thread_id, request.workspace_id})
    if not rows or err then return nil, "read hook session" end
    if #rows ~= 1 or rows[1].state == "closed" then return nil, "hook session is unavailable" end
    local route = type(rows[1].route_json) == "string" and bounds.object(json.decode(rows[1].route_json)) or nil
    return route and bounds.id(route.provider) or nil, nil
end
local function selected(tx: sql.Transaction, request: Request, id: string, revision: integer?): (traits.Selection?, string?)
    local selection, err = traits.read(tx, request.session_ref, id)
    if err then return nil, err end
    if not selection or not selection.selected or selection.workspace_id ~= request.workspace_id
        or selection.thread_id ~= request.thread_id or (revision and selection.revision ~= revision)
        or not contains(selection.declaration.hooks, request.point) then return nil, nil end
    err = traits.consent(tx, selection)
    if err then
        local stopped = traits.stop(tx, selection)
        return nil, stopped
    end
    return selection, nil
end
local function hook_target(selection: traits.Selection): (string?, string?)
    local origin, err = application.origin(assert(selection.declaration.application_ref), selection.workspace_id)
    if err then return nil, err end
    local entries: {Object}? = nil
    local failure: string? = nil
    if origin then
        local overlay = registry.overlay(origin.overlay_owner)
        if not overlay then return nil, "approved application overlay is unavailable" end
        local found, problem = overlay:find({[".kind"] = "function.lua", ["meta.type"] = "bee.session.hook",
            ["meta.application_ref"] = selection.declaration.application_ref})
        entries, failure = found, problem and tostring(problem) or nil
    else
        entries = {}
        for _, entry in ipairs(application.host_entries("bee.session.hook", "function.lua")) do
            local meta = bounds.object(entry.meta)
            if meta and meta.application_ref == selection.declaration.application_ref then entries[#entries + 1] = entry end
        end
    end
    if not entries or failure then return nil, "hook discovery failed" end
    if #entries ~= 1 then return nil, "the approved app must ship exactly one hook function" end
    local meta = bounds.object(entries[1].meta)
    if not meta or meta.application_revision ~= selection.declaration.application_revision then return nil, "hook ownership differs from the approved app revision" end
    return bounds.id(entries[1].id), nil
end
local function begin(db: sql.DB, request: Request, trait: string): (Invocation?, string?)
    local invocation: Invocation? = nil
    local stored = transaction.write(db, function(tx: sql.Transaction): transaction.Result
        local selection, err = selected(tx, request, trait, nil)
        if err then return transaction.storage_failure(err) end
        if not selection then return transaction.success({}, false) end
        local key = assert(hash.sha256(assert(canonical.encode({request.session_ref, request.point, request.occurrence_id, trait, selection.revision}))))
        local rows, read_error = tx:query("SELECT * FROM bee_session_hook_invocations WHERE occurrence_key=?", {key})
        if not rows or read_error then return transaction.storage_failure("read hook invocation") end
        if #rows > 0 then
            local row = rows[1]
            local replay = type(row.reply_json) == "string" and bounds.object(json.decode(row.reply_json)) or nil
            invocation = {id = assert(bounds.id(row.invocation_id)), selection = selection, replay = replay, pending = false, waiting = row.state == "pending"}
            return transaction.success({}, true)
        end
        local id = assert(uuid.v7())
        local _, insert_error = tx:execute([[INSERT INTO bee_session_hook_invocations(invocation_id,occurrence_key,session_ref,trait_id,selection_revision,point,state) VALUES (?,?,?,?,?,?,'pending')]],
            {id, key, request.session_ref, trait, selection.revision, request.point})
        if insert_error then return transaction.storage_failure("start hook invocation") end
        invocation = {id = id, selection = selection, replay = nil, pending = true, waiting = false}
        return transaction.success({}, false)
    end)
    if not stored.ok then return nil, stored.message end
    return invocation, nil
end
local function await_terminal(db: sql.DB, request: Request, invocation: Invocation, wait_ms: integer): (Object?, string?)
    local system = "bee.session.hook/" .. invocation.id
    local subscription, failure = events.subscribe(system, "completed")
    if not subscription then return nil, "subscribe to hook decision: " .. tostring(failure) end
    local budget = time.after(tostring(wait_ms) .. "ms")
    events.send(system, "waiting", invocation.id)
    local expired = false
    while true do
        local pending = false
        local reply: Object? = nil
        local checked = transaction.read(db, function(tx: sql.Transaction): transaction.Result
            local live, err = selected(tx, request, invocation.selection.trait_id, invocation.selection.revision)
            if err then return transaction.storage_failure(err) end
            if not live then return transaction.success({}, false) end
            local rows, read_error = tx:query("SELECT state,reply_json FROM bee_session_hook_invocations WHERE invocation_id=?", {invocation.id})
            if not rows or read_error or #rows ~= 1 then return transaction.storage_failure("read pending hook decision") end
            pending = rows[1].state == "pending"
            if rows[1].state == "completed" then
                reply = type(rows[1].reply_json) == "string" and bounds.object(json.decode(rows[1].reply_json)) or nil
                if not reply then return transaction.storage_failure("completed hook decision is corrupt") end
            end
            return transaction.success({}, true)
        end)
        if not checked.ok or not pending or expired then
            subscription:close()
            return reply, not checked.ok and checked.message or (pending and "pending hook invocation has no terminal decision" or nil)
        end
        local signal = channel.select({subscription:channel():case_receive(), budget:case_receive()})
        if not signal.ok then subscription:close(); return nil, "hook decision subscription closed" end
        expired = signal.channel == budget
    end
end
local function decode(raw: unknown, request: Request, capability: capabilities.Capability, prior: Result, driver: string): (Object?, string?)
    local encoded, err = canonical.encode(raw, supervisor.MAX_REPLY_BYTES)
    if not encoded then return nil, "invalid or oversized hook reply: " .. tostring(err) end
    local reply = bounds.object(json.decode(encoded))
    local kind = reply and bounds.member(reply.kind, {"pass", "add_context", "change", "deny"})
    if not reply or not kind or not capabilities.allows(capability, kind) then return nil, "invalid or unsupported hook result" end
    if kind == "pass" then
        if bounds.fields(reply, {"kind"}) then return nil, "invalid pass fields" end
    elseif kind == "add_context" then
        local text = bounds.text(reply.text, supervisor.MAX_REPLY_BYTES)
        if not text or bounds.fields(reply, {"kind", "text"}) then return nil, "invalid context fields" end
        if #prior.additional_context + #text + 1 > supervisor.MAX_CONTEXT_BYTES then return nil, "hook context exceeds chain budget" end
    elseif kind == "deny" then
        local reason = bounds.text(reply.reason, 4096)
        if not reason or #reason == 0 or bounds.fields(reply, {"kind", "reason"}) then return nil, "invalid denial reason" end
    elseif request.point == "tool.before" then
        local input = bounds.object(reply.input)
        if not input or bounds.fields(reply, {"kind", "input"}) then return nil, "change requires tool input" end
        if driver == "wippy" and not canonical.encode(input, 8192) then return nil, "tool input exceeds native driver bound" end
        if driver == "agy" then
            for key in pairs(bounds.object(prior.input) or {}) do
                if input[key] == nil then return nil, "Agy overwrite cannot remove an existing input field" end
            end
        end
        if driver == "codex" and type(input.command) ~= "string" then return nil, "Codex changes require a shell command input" end
    elseif request.point == "tool.after" then
        if reply.output == nil or bounds.fields(reply, {"kind", "output"}) then return nil, "change requires tool output" end
        if driver == "wippy" and not canonical.encode(reply.output, 3000) then return nil, "tool output exceeds native driver bound" end
    else
        if not bounds.text(reply.text, supervisor.MAX_REPLY_BYTES) or bounds.fields(reply, {"kind", "text"}) then return nil, "change requires prompt text" end
    end
    return reply, nil
end
local function finish(db: sql.DB, request: Request, invocation: Invocation, reply: Object?, diagnostic: string?): (Object?, string?)
    local accepted: Object? = nil
    local stored = transaction.write(db, function(tx: sql.Transaction): transaction.Result
        local rows, err = tx:query("SELECT state FROM bee_session_hook_invocations WHERE invocation_id=?", {invocation.id})
        if not rows or err then return transaction.storage_failure("read hook fence") end
        if #rows ~= 1 or rows[1].state ~= "pending" then return transaction.success({}, true) end
        local live, live_error = selected(tx, request, invocation.selection.trait_id, invocation.selection.revision)
        if live_error then return transaction.storage_failure(live_error) end
        if not live then reply, diagnostic = nil, "trait consent or activation changed during invocation" end
        if reply and request.point == "tool.after" and reply.kind == "change" then
            local original, invalid = canonical.encode(request.output, supervisor.MAX_TURN_BYTES)
            if not original then reply, diagnostic = nil, "original output exceeds retention bound: " .. tostring(invalid)
            else
                local ref = "bh:" .. invocation.id
                local _, retention_error = tx:execute("INSERT INTO bee_session_hook_originals(record_ref,invocation_id,session_ref,trait_id,grant_id,original_json) VALUES (?,?,?,?,?,?)",
                    {ref, invocation.id, request.session_ref, invocation.selection.trait_id, invocation.selection.grant_id, original})
                if retention_error then return transaction.storage_failure("retain original hook output") end
                reply.original_ref = ref
            end
        end
        local _, update_error = tx:execute("UPDATE bee_session_hook_invocations SET state=?,reply_json=?,diagnostic=? WHERE invocation_id=? AND state='pending'",
            {reply and "completed" or "diagnostic", reply and assert(canonical.encode(reply)) or sql.NULL, diagnostic or sql.NULL, invocation.id})
        if update_error then return transaction.storage_failure("finish hook invocation") end
        accepted = reply
        return transaction.success({}, false)
    end)
    if not stored.ok then return nil, stored.message end
    events.send("bee.session.hook/" .. invocation.id, "completed", invocation.id)
    return accepted, nil
end
local function apply(result: Result, point: string, reply: Object)
    if reply.kind == "add_context" then
        local text = assert(bounds.text(reply.text))
        result.additional_context = result.additional_context == "" and text or (result.additional_context .. "\n" .. text)
    elseif reply.kind == "change" then
        result.changed = true
        if point == "tool.before" then result.input = reply.input
        elseif point == "tool.after" then result.output = reply.output
        else result.text = assert(bounds.text(reply.text)) end
        local original = bounds.id(reply.original_ref)
        if original then result.original_refs[#result.original_refs + 1] = original end
    elseif reply.kind == "deny" then result.denied, result.reason = true, assert(bounds.text(reply.reason)) end
end
local function run(db: sql.DB, request: Request): (Result?, string?)
    local driver: string? = nil
    local ids: {string} = {}
    local found = transaction.read(db, function(tx: sql.Transaction): transaction.Result
        local err: string?
        driver, err = session_driver(tx, request)
        if err then return transaction.failure("DENIED", err) end
        local rows, failure = tx:query("SELECT trait_id FROM bee_session_traits WHERE session_ref=? AND selected=1 ORDER BY trait_id", {request.session_ref})
        if not rows or failure then return transaction.storage_failure("read hook selections") end
        for _, row in ipairs(rows) do
            local id = assert(bounds.id(row.trait_id))
            local selection, invalid = traits.read(tx, request.session_ref, id)
            if invalid then return transaction.storage_failure(invalid) end
            if selection and contains(selection.declaration.hooks, request.point) then ids[#ids + 1] = id end
        end
        return transaction.success({}, false)
    end)
    if not found.ok then return nil, found.message end
    local result: Result = {input = request.input, output = request.output, text = request.text, additional_context = "", denied = false, changed = false, original_refs = {}}
    local capability = capabilities.at(driver or "unknown", request.point)
    if not capability or not capability.supported then
        if #ids > 0 then return nil, "UNSUPPORTED_CAPABILITY: " .. (capability and capability.reason or "unknown hook point") end
        return result, nil
    end
    local budget = supervisor.budget(driver or "unknown", request.point)
    local started = supervisor.now()
    local encoded, turn_error = canonical.encode(request, supervisor.MAX_TURN_BYTES)
    local count = 0
    for _, id in ipairs(ids) do
        local invocation, err = begin(db, request, id)
        if err then return nil, err end
        if invocation then
            local reply = invocation.replay
            if invocation.waiting then
                reply, err = await_terminal(db, request, invocation, budget.chain_ms)
                if err then return nil, err end
            end
            if invocation.pending then
                count = count + 1
                local diagnostic: string? = nil
                local target, discovery_error = hook_target(invocation.selection)
                if not encoded then diagnostic = "hook turn exceeds its bound: " .. tostring(turn_error)
                elseif not target then diagnostic = discovery_error or "hook function unavailable"
                elseif count > supervisor.MAX_INVOCATIONS or supervisor.remaining(started, budget.chain_ms) == 0 then diagnostic = "chain budget exceeded"
                else
                    local turn: Object = {invocation_id = invocation.id, occurrence_id = request.occurrence_id, session_ref = request.session_ref,
                        thread_id = request.thread_id, workspace_id = request.workspace_id, trait_id = id, turn_ref = request.turn_ref,
                        tool_name = request.tool_name, tool_call_id = request.tool_call_id, input = result.input, output = result.output,
                        text = result.text, additional_context = result.additional_context, original_refs = result.original_refs}
                    local raw, invoke_error = supervisor.invoke({target = target, id = invocation.id, point = request.point,
                        turn = turn, application_ref = assert(invocation.selection.declaration.application_ref),
                        application_revision = assert(invocation.selection.declaration.application_revision), driver = driver or "unknown",
                        remaining_ms = supervisor.remaining(started, budget.chain_ms)})
                    if invoke_error then diagnostic = invoke_error else reply, diagnostic = decode(raw, request, capability, result, driver or "unknown") end
                end
                reply, err = finish(db, request, invocation, reply, diagnostic)
                if err then return nil, err end
            end
            if reply then apply(result, request.point, reply) end
            if result.denied then break end
        end
    end
    return result, nil
end
function M.dispatch(request: Request): (Result?, string?)
    local actor = security.actor()
    local meta = actor and bounds.object(actor:meta())
    if not actor or not meta or meta.workspace_id ~= request.workspace_id or actor:id():match("^bee%.hive%.member%.")
        or not (security.can("bee.sessions.hook_boundary", request.session_ref) or security.can("bee.threads.carrier", request.thread_id)) then
        return nil, "hook dispatch requires the authenticated execution owner"
    end
    if not capabilities.at("wippy", request.point) or not bounds.id(request.occurrence_id) then return nil, "invalid hook occurrence" end
    local db, err = database.open()
    if not db then return nil, err end
    local ok, result, failure = pcall(run, db, request)
    db:release()
    if not ok then return nil, tostring(result) end
    return result, failure
end
function M.handle(raw: unknown): {ok: boolean, value?: unknown, error?: Object}
    local input = bounds.object(raw)
    local thread = input and bounds.id(input.thread_id)
    local workspace = input and bounds.id(input.workspace_id)
    local point = input and bounds.id(input.point)
    local occurrence = input and bounds.id(input.occurrence_id)
    if not input or not thread or not workspace or not point or not occurrence
        or bounds.fields(input, {"session_ref", "action_id", "thread_id", "workspace_id", "point", "occurrence_id", "turn_ref", "tool_name", "tool_call_id", "input", "output", "text"}) then
        return {ok = false, error = {code = "INVALID", message = "invalid hook execution boundary"}}
    end
    local session = bounds.id(input.session_ref)
    if not session then
        local action = bounds.id(input.action_id)
        local actor = security.actor()
        if not action or not actor or actor:meta().workspace_id ~= workspace or not security.can("bee.threads.carrier", thread)
            or actor:id():match("^bee%.hive%.member%.") then return {ok = false, error = {code = "DENIED", message = "hook action requires the execution owner"}} end
        local db, err = database.open()
        if not db then return {ok = false, error = {code = "UNAVAILABLE", message = err}} end
        local rows, failure = db:query([[SELECT DISTINCT s.session_ref FROM bee_sessions s LEFT JOIN bee_session_turns t ON t.session_ref=s.session_ref
            WHERE s.thread_id=? AND s.workspace_id=? AND (s.session_ref=? OR t.turn_ref=? OR t.work_ref=?) LIMIT 2]], {thread, workspace, action, action, action})
        db:release()
        if not rows or failure then return {ok = false, error = {code = "UNAVAILABLE", message = "read action hook session"}} end
        if #rows == 0 then return {ok = true, value = {input = input.input, output = input.output, text = input.text,
            additional_context = "", denied = false, changed = false, original_refs = {}}} end
        if #rows ~= 1 then return {ok = false, error = {code = "DENIED", message = "hook action has ambiguous session ownership"}} end
        session = assert(bounds.id(rows[1].session_ref))
    end
    local result, failure = M.dispatch({session_ref = session, thread_id = thread, workspace_id = workspace, point = point,
        occurrence_id = occurrence, input = input.input, output = input.output, text = bounds.text(input.text, supervisor.MAX_TURN_BYTES),
        turn_ref = bounds.id(input.turn_ref), tool_name = bounds.id(input.tool_name), tool_call_id = bounds.id(input.tool_call_id)})
    if not result then return {ok = false, error = {code = "HOOK_BOUNDARY", message = failure}} end
    return {ok = true, value = result}
end
return M
