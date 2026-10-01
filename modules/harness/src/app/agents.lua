-- MIT. The Agent window's view of the sessions contract: the launchable
-- catalog, one open session and the work given to it. Every call goes through
-- the sessions client, so admission, executors and placement stay behind the
-- contract. Calls are synchronous; the window runs them off its event loop.
local sessions = require("sessions")
local json = require("json")
local funcs = require("funcs")
local thread_record = require("thread_record")
local sessions_protocol = require("sessions_protocol")
local bounds = require("bounds")
local caller = require("caller")
local M = {}
type Snapshot = sessions_protocol.SessionSnapshot
type Workspace = {label: string, folder: string}
type Ask = (string, {[string]: unknown}) -> caller.Reply

M.MAX_PAGES = 16
M.MAX_TURNS = 64

type Fault = {code: string, message: string, retry: string, operation_key: string?}
type Entry = {ref: string, kind: "definition" | "profile", revision: integer?, title: string,
    status: string, ready: boolean, reason: string}
type EntrySortKey = {ref: string, title: string, ready: boolean}
type Listing = {items: {Entry}, unavailable: integer, notes: {string}}
type TurnState = "queued" | "working" | "ready" | "failed" | "blocked" | "uncertain"
type Turn = {work: sessions.Work, input: string, state: TurnState, text: string, cancel_key: string?, segments: {[string]: string}?}
type Unsent = {text: string, key: string}
type Conversation = {session: sessions.Session, title: string, lifecycle: string, activity: string, queued: integer,
    turns: {Turn}, unsent: Unsent?, notice: string, thread_cursor: integer?}

local function describe(fault: Fault?): string
    if not fault then return "sessions contract returned no reason" end
    return fault.code .. ": " .. fault.message
end
M.describe = describe

-- Ready entries first, then title order. include_unavailable adds the
-- candidates the catalog could not confirm, each with its reason.
function M.list(client: sessions.Client, include_unavailable: boolean): (Listing?, string?)
    local listing: Listing = {items = {}, unavailable = 0, notes = {}}
    local cursor: string? = nil
    for _ = 1, M.MAX_PAGES do
        local page, fault = client:catalog({include_unavailable = include_unavailable, cursor = cursor})
        if not page then return nil, describe(fault) end
        for _, candidate in ipairs(page.items) do
            if candidate.kind ~= "executor" then
                local ready = candidate.status == "ready"
                local reason = candidate.reasons[1] or (ready and "" or candidate.status)
                listing.items[#listing.items + 1] = {ref = candidate.ref, kind = candidate.kind, revision = candidate.revision,
                    title = candidate.title, status = candidate.status, ready = ready, reason = reason}
            end
        end
        listing.unavailable = page.unavailable_count
        for _, diagnostic in ipairs(page.diagnostics) do listing.notes[#listing.notes + 1] = describe(diagnostic) end
        if not page.next then break end
        cursor = page.next
    end
    table.sort(listing.items, function(left: EntrySortKey, right: EntrySortKey): boolean
        if left.ready ~= right.ready then return left.ready end
        if left.title ~= right.title then return left.title < right.title end
        return left.ref < right.ref
    end)
    return listing, nil
end

local function conversation(session: sessions.Session): Conversation
    local snapshot = session.snapshot
    local turns: {Turn} = {}
    return {session = session, title = snapshot.title, lifecycle = snapshot.lifecycle, activity = snapshot.activity,
        queued = snapshot.queue_count, turns = turns, unsent = nil, notice = "", thread_cursor = 0}
end

-- The key identifies one open operation: retrying the same key returns the
-- same session, never a second one.
function M.open(client: sessions.Client, definition: string, profile: {id: string, revision: integer}?,
    key: string, presentation: sessions_protocol.Presentation?): (Conversation?, string?)
    local session, fault = client:open({definition = definition, profile = profile, presentation = presentation, operation_key = key})
    if not session then return nil, describe(fault) end
    return conversation(session), nil
end

-- Sends text as one unit of work. A failed send keeps its key, so submitting
-- the same text again resolves the earlier attempt instead of duplicating it.
function M.submit(conv: Conversation, text: string, new_key: () -> string): boolean
    local unsent = conv.unsent
    if not unsent or unsent.text ~= text then unsent = {text = text, key = new_key()} end
    conv.unsent = unsent
    local work, fault = conv.session:send({input = text, operation_key = unsent.key})
    if not work then
        conv.notice = describe(fault)
        return false
    end
    conv.unsent, conv.notice = nil, ""
    conv.turns[#conv.turns + 1] = {work = work, input = text, state = "queued", text = ""}
    if #conv.turns > M.MAX_TURNS then table.remove(conv.turns, 1) end
    return true
end

-- Seals intake and lets accepted work finish. The key makes a retry resolve
-- the same close.
function M.close(conv: Conversation, key: string): boolean
    local operation, fault = conv.session:close({operation_key = key})
    if not operation then
        conv.notice = describe(fault)
        return false
    end
    conv.notice = ""
    return true
end

local function render(value: unknown): string
    if type(value) == "string" then return value end
    local encoded = json.encode(value)
    return encoded or "(unreadable result)"
end

local function settle(turn: Turn, observed: unknown)
    local await = observed
    if await.tag == "ready" then
        local result = await.result
        if result.outcome == "succeeded" then
            turn.state, turn.text = "ready", render(result.value)
        else
            local fault = result.error
            turn.state, turn.text = "failed", tostring(result.outcome) .. ": " .. describe(fault)
        end
    elseif await.tag == "blocked" then
        local blocker = await.blocker
        turn.state, turn.text = "blocked", tostring(blocker.message)
    elseif await.tag == "uncertain" then
        local evidence = await.evidence
        turn.state, turn.text = "uncertain", tostring(evidence.summary)
    end
end

local function observe_thread(conv: Conversation)
    local thread = conv.session.snapshot.thread_ref
    if not thread then return end
    local reply = caller.new(funcs.call):invoke("bee.threads.service:read_after", {thread_id = thread,
        cursor = conv.thread_cursor or 0, limit = 64})
    if not reply or not reply.ok then return end
    local page = bounds.object(reply.value)
    local rows = page and bounds.array(page.records, 64)
    local cursor = page and bounds.count(page.scanned_through)
    if not rows or not cursor then return end
    for _, raw in ipairs(rows) do
        local envelope = thread_record.decode(raw)
        if envelope and envelope.kind == "observation" and envelope.body.type == "extension" then
            local extension = envelope.body.data
            if extension.event_name == "bee.sessions.event" then
                local decoded = json.decode(extension.payload_json)
                local event = bounds.object(decoded)
                local detail = event and bounds.object(event.data)
                local observation = detail and bounds.object(detail.observation)
                local data = observation and bounds.object(observation.data)
                if event and event.kind == "turn.observation" and observation and data then
                    for _, turn in ipairs(conv.turns) do
                        if detail and event.subject == turn.work:ref() and (turn.state == "queued" or turn.state == "working") then
                            if observation.type == "text" and type(data.text) == "string" and #data.text <= 65536 then
                                local segment = bounds.id(data.segment_id) or "answer"
                                turn.segments = turn.segments or {}
                                local pieces = turn.segments
                                pieces[segment] = data.operation == "append" and ((pieces[segment] or "") .. data.text) or data.text
                                local keys: {string} = {}
                                for key in pairs(pieces) do keys[#keys + 1] = key end
                                table.sort(keys)
                                local values: {string} = {}
                                for _, key in ipairs(keys) do values[#values + 1] = pieces[key] end
                                turn.text = table.concat(values, "\n"):sub(-65536)
                            end
                        end
                    end
                end
            end
        end
    end
    conv.thread_cursor = cursor
end

-- Reads the session snapshot and observes each unsettled turn without waiting.
function M.refresh(conv: Conversation): boolean
    local current, fault = conv.session:get()
    if not current then
        conv.notice = describe(fault)
        return false
    end
    local snapshot = current.snapshot
    conv.session = current
    conv.title, conv.lifecycle, conv.activity, conv.queued = snapshot.title, snapshot.lifecycle, snapshot.activity, snapshot.queue_count
    conv.notice = ""
    for _, turn in ipairs(conv.turns) do
        if turn.state == "queued" or turn.state == "working" or turn.state == "blocked" or turn.state == "uncertain" then
            local observed, await_fault = turn.work:await({timeout_ms = 0})
            if not observed then
                conv.notice = describe(await_fault)
            elseif observed.tag == "pending" then
                local state = turn.work:state()
                turn.state = state and state.phase == "queued" and "queued" or "working"
            else
                settle(turn, observed)
            end
        end
    end
    observe_thread(conv)
    return true
end

function M.remember(current: Conversation, saved: Conversation): Conversation
    return {session = current.session, title = current.title, lifecycle = current.lifecycle, activity = current.activity,
        queued = current.queued, turns = saved.turns, unsent = saved.unsent, notice = current.notice, thread_cursor = saved.thread_cursor}
end

function M.resume(client: sessions.Client, ref: string): (Conversation?, string?)
    local session, fault = client:get(ref)
    if not session then return nil, describe(fault) end
    local conv = conversation(session)
    local turns = conv.turns
    local cursor: integer? = nil
    for _ = 1, M.MAX_PAGES do
        local page, history_fault = session:history({cursor = cursor})
        if not page then conv.notice = describe(history_fault); break end
        for _, item in ipairs(page.items) do
            local work, work_fault = client:work(item.work)
            if not work then return nil, describe(work_fault) end
            local turn: Turn = {work = work, input = render(item.input), state = "queued", text = ""}
            turns[#turns + 1] = turn
            if #turns > M.MAX_TURNS then table.remove(turns, 1) end
        end
        cursor = page.next
        if not cursor then break end
    end
    M.refresh(conv)
    return conv, nil
end

function M.home(ref: string): string?
    return ref:match("^bs:[^:]+:([^:]+):")
end
function M.workspace(id: string, ask: Ask): Workspace?
    local reply = ask("bee.workspace.catalog:read", {workspace_id = id})
    if not reply.ok then return nil end
    local value = bounds.object(reply.value)
    local row = value and bounds.object(value.workspace)
    if not row or row.workspace_id ~= id then return nil end
    local label = bounds.line(row.label, 240)
    local path = bounds.subpath(row.subpath)
    if not label or not path then return nil end
    return {label = label ~= "" and label or "Workspace", folder = path ~= "" and path or "Workspace root"}
end

function M.directory(client: sessions.Client, workspace: string?): ({Snapshot}?, string?)
    local rows: {Snapshot} = {}
    local cursor: string? = nil
    for _ = 1, M.MAX_PAGES do
        local page, fault = client:list({cursor = cursor})
        if not page then return nil, describe(fault) end
        for _, item in ipairs(page.items) do
            local home = M.home(item.session)
            if not workspace or home == workspace then rows[#rows + 1] = item end
        end
        if not page.next then return rows, nil end
        cursor = page.next
    end
    return rows, "More sessions are available; narrow the workspace filter"
end

function M.stop(conv: Conversation, new_key: () -> string): boolean
    local chosen: Turn? = nil
    for _, turn in ipairs(conv.turns) do
        if turn.state == "working" or turn.state == "blocked" or turn.state == "uncertain" then chosen = turn; break end
        if not chosen and turn.state == "queued" then chosen = turn end
    end
    if not chosen then conv.notice = "No current work to stop"; return false end
    chosen.cancel_key = chosen.cancel_key or new_key()
    local operation, fault = chosen.work:cancel({operation_key = chosen.cancel_key, reason = "Stopped from Sessions"})
    if not operation then conv.notice = describe(fault); return false end
    conv.notice = "Stop requested; waiting for the recorded outcome"
    return true
end

function M.pending(conv: Conversation): boolean
    for _, turn in ipairs(conv.turns) do
        if turn.state == "queued" or turn.state == "working" or turn.state == "blocked" then return true end
    end
    return false
end

return M
