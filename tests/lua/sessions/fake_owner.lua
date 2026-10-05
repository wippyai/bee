-- MIT. A stateless bee.sessions owner: replies follow the request, and a ref's
-- last segment selects the observation the owner reports for it.
local principals = require("principals")
local bounds = require("bounds")
local sessions = require("sessions")
local protocol = require("protocol")
local M = {}
local STAMP = "2026-09-29T10:00:00.000Z"
type Reply = {[string]: unknown}

local function ok(value: unknown): Reply return {ok = true, value = value} end
local function refuse(code: string, message: string, key: unknown): Reply
    return {ok = false, error = {code = code, message = message, retry = "never", operation_key = key}}
end
local function tail(ref: unknown): string return tostring(ref):match("[^:]+$") or "" end
local function segment(key: unknown): string return (tostring(key):gsub("[^%w]", "_")) end
local function incarnation(session: unknown): integer return math.floor(tonumber(tostring(session):match("(%d)$")) or 1) end
local function object(value: unknown): {[string]: unknown} return assert(bounds.object(value)) end

local function closed(request: unknown, allowed: {string}): string?
    local seen: {[string]: boolean} = {}
    for _, name in ipairs(allowed) do seen[name] = true end
    for name in pairs(object(request)) do if not seen[name] then return "unknown field " .. tostring(name) end end
    return nil
end

local function snapshot(session: string): {[string]: unknown}
    return {session = session, revision = 1, incarnation = incarnation(session), title = "session", lifecycle = "active",
        activity = "idle", execution = {state = "quiescent", evidence_at = STAMP, stale = false},
        queue_count = 0, effective_limits = {turn = {wall_time_ms = 900000, provider_steps = 32, tool_calls = 64}}, continuity = {mode = "fresh"}, actions = {}}
end

local function succeeded(): {[string]: unknown}
    return {outcome = "succeeded", schema = "bee:Text@1", value = {text = "done"}, artifacts = {}, usage = {}}
end

local function observation(kind: string, subject: string, name: string): {[string]: unknown}
    local base: {[string]: unknown} = {subject_kind = kind, subject = subject, cursor = "c1"}
    local branch = tail(subject)
    if branch == "other" then base.subject = "bw:n:w:elsewhere" end
    if branch == "pending" then base.tag = "pending"; base.reason = "timeout"
    elseif branch == "blocked" then base.tag = "blocked"
        base.blocker = {kind = "authority", message = "needs approval", subject = "bw:n:w:blocked", actions = {}}
    elseif branch == "uncertain" then base.tag = "uncertain"; base.evidence = {summary = "unknown effects", artifacts = {}}
    else
        base.tag = "ready"
        if branch == "failed" then
            base.result = kind == "work" and {outcome = "failed", error = {code = "OUTPUT_INVALID", message = "invalid", retry = "never"},
                artifacts = {}} or nil
        elseif kind == "work" then base.result = succeeded()
        else base.result = {kind = "result", result = succeeded()} end
    end
    if branch == "malformed" then base.extra = true end
    return base
end

function M.open(request: unknown): Reply
    local problem = closed(request, {"spec", "operation_key"})
    if problem then return refuse("INVALID", problem, object(request).operation_key) end
    local key = object(request).operation_key
    local definition = tail(object(object(request).spec).definition)
    if definition == "lost" then error("owner unreachable") end
    if definition == "deny" then return refuse("DENIED", "not admitted", key) end
    if definition == "folder" then
        local folder = object(object(object(request).spec).workdir)
        if folder.root_ref ~= "bee.node:machine" or folder.path ~= "home/project" then return refuse("INVALID", "workdir was lost", key) end
    end
    local session = definition == "two" and "bs:n:w:s2" or "bs:n:w:s1"
    if definition == "malformed" then return ok({session = session}) end
    return ok({session = session, operation = "bo:n:w:" .. segment(key), snapshot = (function()
        local value = snapshot(session)
        value.presentation = object(object(request).spec).presentation or "headless"
        return value
    end)()})
end

function M.run(request: unknown): Reply
    local problem = closed(request, {"spec", "input", "output", "operation_key"})
    if problem then return refuse("INVALID", problem, object(request).operation_key) end
    local key = object(request).operation_key
    local spec = object(object(request).spec)
    local name = tail(spec.definition)
    if name == "window" and spec.presentation ~= "window" then return refuse("INVALID", "presentation was lost", key) end
    return ok({work = "bw:n:w:" .. name, session = "bs:n:w:r" .. name, operation = "bo:n:w:" .. segment(key),
        committed_at = STAMP, sequence = 1, kind = "request", state = "queued",
        output_schema = object(request).output or "bee:Text@1", sender = {kind = "principal", id = "principal:test"}})
end

function M.send(request: unknown): Reply
    local problem = closed(request, {"session", "input", "output", "expected_incarnation", "operation_key"})
    local input = object(request)
    if problem then return refuse("INVALID", problem, input.operation_key) end
    if (input.expected_incarnation or 1) ~= incarnation(input.session) then
        return refuse("STALE", "incarnation changed", input.operation_key)
    end
    local word = type(input.input) == "string" and (input.input):match("^%a+$") or "ready"
    return ok({work = "bw:n:w:" .. word, session = input.session, operation = "bo:n:w:" .. segment(input.operation_key),
        committed_at = STAMP, sequence = 2, kind = "request", state = "queued", output_schema = input.output or "bee:Text@1",
        sender = {kind = "session", id = "bs:n:w:lead"}})
end

function M.await(request: unknown): Reply
    local problem = closed(request, {"subject", "timeout_ms"})
    if problem then return refuse("INVALID", problem, nil) end
    local subject = tostring(object(request).subject)
    local kind = subject:sub(1, 2) == "bw" and "work" or subject:sub(1, 2) == "bo" and "operation" or "work"
    return ok(observation(kind, subject, tail(subject)))
end

function M.join(request: unknown): Reply
    local input = object(request)
    local problem = closed(request, {"works", "policy", "quorum", "timeout_ms", "operation_key"})
    if problem then return refuse("INVALID", problem, input.operation_key) end
    local children: {unknown} = {}
    local rank = {ready = 0, pending = 1, blocked = 2, uncertain = 3}
    local worst = "ready"
    for index, work in ipairs(principals.strings(input.works)) do
        local child = observation("work", work, tail(work))
        children[index] = child
        if rank[child.tag] > rank[worst] then worst = child.tag end
    end
    local joined: {[string]: unknown} = {subject_kind = "join", subject = "bj:n:w:" .. segment(input.operation_key),
        cursor = "c1", tag = worst, children = children}
    if worst == "ready" then
        local values: {unknown} = {}
        for index in ipairs(children) do values[index] = {text = "done"} end
        joined.result = {succeeded = true, winners = input.works, values = values}
    elseif worst == "pending" then joined.reason = "timeout"
    elseif worst == "blocked" then joined.blocker = {kind = "authority", message = "blocked", subject = "bw:n:w:blocked", actions = {}}
    else joined.evidence = {summary = "unknown", artifacts = {}} end
    return ok(joined)
end

function M.get(request: unknown): Reply
    local input = object(request)
    if input.session then return ok({kind = "session", value = snapshot(tostring(input.session))}) end
    if input.work then
        local name = tail(input.work)
        local state: {[string]: unknown} = {work = input.work, session = name == "two" and "bs:n:w:s2" or "bs:n:w:s1",
            sender = {kind = "session", id = "bs:n:w:lead"}, revision = 1, cancelling = false}
        if name == "ready" then state.phase = "settled"; state.result = succeeded() else state.phase = "accepted" end
        return ok({kind = "work", value = state})
    end
    return refuse("INVALID", "get needs a session or work", nil)
end

function M.cancel(request: unknown): Reply
    local input = object(request)
    local problem = closed(request, {"work", "reason", "expected_incarnation", "operation_key"})
    if problem then return refuse("INVALID", problem, input.operation_key) end
    if tail(input.work) == "two" and input.expected_incarnation ~= 2 then return refuse("STALE", "incarnation changed", input.operation_key) end
    return ok({operation = "bo:n:w:" .. segment(input.operation_key), subject = input.work, state = "requested", effect = "cancel"})
end

function M.close(request: unknown): Reply
    local input = object(request)
    local problem = closed(request, {"session", "expected_incarnation", "operation_key"})
    if problem then return refuse("INVALID", problem, input.operation_key) end
    return ok({operation = "bo:n:w:" .. segment(input.operation_key), subject = input.session, state = "requested", effect = "close"})
end

function M.list(request: unknown): Reply
    local problem = closed(request, {"filter", "cursor"})
    if problem then return refuse("INVALID", problem, nil) end
    return ok({items = {snapshot("bs:n:w:s1")}})
end

function M.catalog(request: unknown): Reply
    local problem = closed(request, {"kind", "include_unavailable", "cursor"})
    if problem then return refuse("INVALID", problem, nil) end
    return ok({items = {{ref = "research:quick", kind = "definition", title = "Quick", status = "ready", checked_at = STAMP,
        reasons = {}, features = {}, actions = {}}}, complete = true, unavailable_count = 0, diagnostics = {}})
end

function M.history(_: unknown): unknown return {ok = true, value = {items = {}}} end
type ClientScript = {
    catalog: ((sessions.CatalogOptions) -> (unknown, sessions.Fault?))?,
    list: ((sessions.ListOptions) -> (unknown, sessions.Fault?))?,
    open: ((sessions.OpenOptions) -> (sessions.Session?, sessions.Fault?))?,
}
type SessionScript = {
    send: ((sessions.SendOptions) -> (sessions.Work?, sessions.Fault?))?,
    get: (() -> (sessions.Session?, sessions.Fault?))?,
}
type WorkScript = {
    await: (() -> (protocol.WorkAwait?, sessions.Fault?))?,
    state: (() -> (protocol.WorkState?, sessions.Fault?))?,
    cancel: ((sessions.CancelOptions) -> (sessions.Operation?, sessions.Fault?))?,
}
function M.fixture_snapshot(ref: string, title: string, activity: string, queued: integer, lifecycle: string?, evidence: protocol.ActivityEvidence?): protocol.SessionSnapshot
    return assert(protocol.decode_snapshot({session = ref, title = title, revision = 1, incarnation = 1,
        lifecycle = lifecycle or "active", activity = activity, activity_evidence = evidence, queue_count = queued,
        execution = {state = "quiescent", evidence_at = STAMP, stale = false}, effective_limits = {},
        continuity = {mode = "fresh"}, actions = {}}))
end
function M.fixture_client(script: ClientScript): sessions.Client
    return {
        catalog = function(_: sessions.Client, options: sessions.CatalogOptions?): (protocol.CatalogPage?, sessions.Fault?)
            if not script.catalog then error("unexpected fixture catalog") end
            local raw, fault = script.catalog(options or {})
            if fault then return nil, fault end
            return assert(protocol.decode_catalog_page(raw)), nil
        end,
        list = function(_: sessions.Client, options: sessions.ListOptions?): (protocol.ListPage?, sessions.Fault?)
            if not script.list then error("unexpected fixture list") end
            local raw, fault = script.list(options or {})
            if fault then return nil, fault end
            return assert(protocol.decode_list_page(raw)), nil
        end,
        open = function(_: sessions.Client, options: sessions.OpenOptions): (sessions.Session?, sessions.Fault?)
            if not script.open then error("unexpected fixture open") end
            return script.open(options)
        end,
        call = function(_: sessions.Client, _: sessions.CallOptions): (sessions.Call?, sessions.Fault?) error("unexpected fixture call") end,
        send = function(_: sessions.Client, _: sessions.SendOptions): (sessions.Work?, sessions.Fault?) error("unexpected fixture send") end,
        cancel = function(_: sessions.Client, _: sessions.CancelOptions): (sessions.Operation?, sessions.Fault?) error("unexpected fixture cancel") end,
        close = function(_: sessions.Client, _: sessions.CloseOptions): (sessions.Operation?, sessions.Fault?) error("unexpected fixture close") end,
        await = function(_: sessions.Client, _: sessions.ClientAwaitOptions): (sessions.AnyAwait?, sessions.Fault?) error("unexpected fixture await") end,
        join = function(_: sessions.Client, _: sessions.JoinOptions): (sessions.JoinAwait?, sessions.Fault?) error("unexpected fixture join") end,
        get = function(_: sessions.Client, _: string): (sessions.Session?, sessions.Fault?) error("unexpected fixture get") end,
        work = function(_: sessions.Client, _: string): (sessions.Work?, sessions.Fault?) error("unexpected fixture work") end,
        history = function(_: sessions.Client, _: sessions.HistoryOptions): (protocol.HistoryPage?, sessions.Fault?) error("unexpected fixture history") end,
    }
end
function M.fixture_session(snapshot: protocol.SessionSnapshot, script: SessionScript): sessions.Session
    return {snapshot = snapshot, incarnation = snapshot.incarnation,
        ref = function(_: sessions.Session): string return snapshot.session end,
        send = function(_: sessions.Session, options: sessions.SendOptions): (sessions.Work?, sessions.Fault?)
            if not script.send then error("unexpected fixture send") end
            return script.send(options)
        end,
        get = function(_: sessions.Session): (sessions.Session?, sessions.Fault?)
            if not script.get then error("unexpected fixture get") end
            return script.get()
        end,
        await = function(_: sessions.Session, _: sessions.Work, _: sessions.AwaitOptions?): (protocol.WorkAwait?, sessions.Fault?) error("unexpected fixture session await") end,
        close = function(_: sessions.Session, _: sessions.CloseOptions): (sessions.Operation?, sessions.Fault?) error("unexpected fixture session close") end,
        history = function(_: sessions.Session, _: {cursor: integer?, limit: integer?}?): (protocol.HistoryPage?, sessions.Fault?) error("unexpected fixture session history") end,
    }
end
function M.fixture_work(ref: string, script: WorkScript): sessions.Work
    return {session = "bs:n:w:s1", incarnation = 1,
        ref = function(_: sessions.Work): string return ref end,
        await = function(_: sessions.Work, _: sessions.AwaitOptions?): (protocol.WorkAwait?, sessions.Fault?)
            if not script.await then error("unexpected fixture work await") end
            return script.await()
        end,
        state = function(_: sessions.Work): (protocol.WorkState?, sessions.Fault?)
            if not script.state then error("unexpected fixture work state") end
            return script.state()
        end,
        cancel = function(_: sessions.Work, options: sessions.CancelOptions): (sessions.Operation?, sessions.Fault?)
            if not script.cancel then error("unexpected fixture work cancel") end
            return script.cancel(options)
        end,
    }
end
return M
