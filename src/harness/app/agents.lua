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
local names = require("names")
local M = {}
type Snapshot = sessions_protocol.SessionSnapshot
type Workspace = {label: string, folder: string}
type Ask = (string, {[string]: unknown}) -> caller.Reply

M.MAX_PAGES = 16
M.MAX_HISTORY_ITEMS = 64

type Fault = {code: string, message: string, retry: string, operation_key: string?}
type Entry = {ref: string, kind: "definition" | "profile", revision: integer?, title: string,
    status: string, ready: boolean, needs_setup: boolean?, reason: string, driver: string?}
type EntrySortKey = {ref: string, title: string, ready: boolean, driver: string?}
type Listing = {items: {Entry}, unavailable: integer, notes: {string}}
type TurnState = "queued" | "starting" | "working" | "ready" | "failed" | "blocked" | "uncertain" | "budget_exceeded"
type Turn = {work: sessions.Work, input: string, state: TurnState, text: string, progress: string?, cancel_key: string?, segments: {[string]: string}?, tools: {[string]: string}?, diagnostics: string?}
type Unsent = {text: string, key: string}
type Conversation = {node: string?, read_only: boolean?, peer_scope: string?, session: sessions.Session, title: string, lifecycle: string, activity: string, queued: integer,
    activity_evidence: sessions_protocol.ActivityEvidence?, turns: {Turn}, details: boolean?, unsent: Unsent?, notice: string, thread_cursor: integer?}

local function describe(fault: Fault?): string
    if not fault then return "sessions contract returned no reason" end
    return fault.code .. ": " .. fault.message
end
M.describe = describe

-- Ready entries first, then title order. include_unavailable adds the
-- candidates the catalog could not confirm, each with its reason.
function M.list(client: sessions.Client, include_unavailable: boolean, query: string?, sort: "name" | "driver"?): (Listing?, string?)
    local listing: Listing = {items = {}, unavailable = 0, notes = {}}
    local cursor: string? = nil
    for _ = 1, M.MAX_PAGES do
        local page, fault = client:catalog({include_unavailable = true, cursor = cursor, query = query ~= "" and query or nil, sort = sort})
        if not page then return nil, describe(fault) end
        for _, candidate in ipairs(page.items) do
            local person_launchable = false
            for _, feature in ipairs(candidate.features) do if feature == "presentation:start_menu" then person_launchable = true end end
            if person_launchable then
                local ready = candidate.status == "ready"
                local needs_setup = false
                for _, feature in ipairs(candidate.features) do if feature == "configuration:needs_setup" then needs_setup = true end end
                local reason = candidate.reasons[1] or (ready and "" or candidate.status)
                local provider = ""
                for _, feature in ipairs(candidate.features) do provider = feature:match("^driver:(.+)$") or provider end
                if not needs_setup then
                    if not ready and reason:find("bee.permission_answers=", 1, true) then
                        reason = reason:gsub("bee.permission_answers=", "Permission answers: ")
                    elseif not ready and reason:find("owner_safe:", 1, true) then
                        reason = "Login needed · " .. reason
                    elseif provider ~= "" then
                        if candidate.status == "missing" then reason = provider .. " was not found in PATH. Install it, then refresh."
                        elseif candidate.status == "unconfigured" then reason = "Run " .. provider .. " to sign in, then refresh."
                        elseif reason:find("bee.", 1, true) then reason = "This agent cannot run with the current setup. Check its folder and permissions." end
                    elseif reason:find("bee.", 1, true) then reason = "This agent's setup is unavailable. Check installation, folder and permissions." end
                end
                if not ready then listing.unavailable = listing.unavailable + 1 end
                if ready or include_unavailable then
                listing.items[#listing.items + 1] = {ref = candidate.ref, kind = candidate.kind, revision = candidate.revision,
                    title = candidate.title, status = candidate.status, ready = ready, needs_setup = needs_setup, reason = reason, driver = provider ~= "" and provider or nil}
                end
            end
        end
        for _, diagnostic in ipairs(page.diagnostics) do listing.notes[#listing.notes + 1] = describe(diagnostic) end
        if not page.next then break end
        cursor = page.next
    end
    table.sort(listing.items, function(left: EntrySortKey, right: EntrySortKey): boolean
        if left.ready ~= right.ready then return left.ready end
        if sort == "driver" and left.driver ~= right.driver then return (left.driver or "") < (right.driver or "") end
        if left.title ~= right.title then return left.title < right.title end
        return left.ref < right.ref
    end)
    return listing, nil
end

function M.visible_profiles(listing: Listing, include_unavailable: boolean, query: string): Listing
    local shown: Listing = {items = {}, unavailable = listing.unavailable, notes = listing.notes}
    local search = query:lower()
    for _, entry in ipairs(listing.items) do
        if (entry.ready or include_unavailable) and (search == "" or entry.title:lower():find(search, 1, true) or
            (entry.driver or ""):lower():find(search, 1, true)) then shown.items[#shown.items + 1] = entry end
    end
    return shown
end

function M.profile_drivers(listing: Listing): {{definition_ref: string, title: string}}
    local choices: {{definition_ref: string, title: string}} = {}
    for _, entry in ipairs(listing.items) do
        if entry.kind == "definition" and (entry.status == "ready" or entry.status == "unconfigured") then
            choices[#choices + 1] = {definition_ref = entry.ref, title = entry.title}
        end
    end
    return choices
end

local function conversation(session: sessions.Session): Conversation
    local snapshot = session.snapshot
    local turns: {Turn} = {}
    return {session = session, title = snapshot.title, lifecycle = snapshot.lifecycle, activity = snapshot.activity,
        queued = snapshot.queue_count, activity_evidence = snapshot.activity_evidence,
        turns = turns, unsent = nil, notice = "", thread_cursor = 0}
end

-- The key identifies one open operation: retrying the same key returns the
-- same session, never a second one.
function M.open(client: sessions.Client, definition: string, profile: {id: string, revision: integer}?,
    key: string, workspace: string?): (Conversation?, string?)
    local session, fault = client:open({definition = definition, profile = profile, workspace = workspace, operation_key = key})
    if not session then return nil, describe(fault) end
    return conversation(session), nil
end

function M.reopen(client: sessions.Client, previous: sessions_protocol.SessionSnapshot, key: string): (Conversation?, string?)
    if not previous.definition then return nil, "This session has no agent definition" end
    return M.open(client, previous.definition, previous.saved_profile, key, previous.workspace)
end

-- Sends text as one unit of work. A failed send keeps its key, so submitting
-- the same text again resolves the earlier attempt instead of duplicating it.
function M.submit(conv: Conversation, text: string, new_key: () -> string): boolean
    if conv.read_only then conv.notice = "Read-only · messaging is not allowed by this bee"; return false end
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
    if #conv.turns > M.MAX_HISTORY_ITEMS then table.remove(conv.turns, 1) end
    return true
end

-- Seals intake and lets accepted work finish. The key makes a retry resolve
-- the same close.
function M.close(conv: Conversation, key: string): boolean
    if conv.node and conv.peer_scope ~= "open" then conv.notice = "Session control is not allowed by this bee"; return false end
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
    local object = bounds.object(value)
    if object and type(object.text) == "string" then return object.text end
    if object and type(object.message) == "string" then return object.message end
    if value == nil then return "Completed" end
    return "Completed · structured result"
end

local function settle(turn: Turn, observed: unknown)
    local await = observed
    if await.tag == "ready" then
        turn.progress = nil
        local result = await.result
        if result.outcome == "succeeded" then
            turn.state, turn.text = "ready", render(result.value)
        elseif result.outcome == "budget_exceeded" then
            turn.state, turn.text = "budget_exceeded", result.evidence.summary
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

function M.placement_progress(raw: unknown): ({state: TurnState, cause: string?}?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "placement observation must be an object" end
    if value.execution_state == "starting" then return {state = "starting"}, nil end
    if value.execution_state == "running" then return {state = "working"}, nil end
    if value.execution_state == "start_failed" then
        local cause = bounds.text(value.start_failure, 4096)
        if not cause then return nil, "failed startup observation omitted its cause" end
        return {state = "failed", cause = cause}, nil
    end
    return nil, "placement observation has no startup transition"
end
function M.preparation_progress(raw: unknown): ({state: "starting", detail: string}?, string?)
    local data = bounds.object(raw)
    if not data or bounds.fields(data, {"type", "segment_id", "operation", "channel", "text"})
        or data.type ~= "text" or data.segment_id ~= "executor-progress" or data.operation ~= "replace" or data.channel ~= "progress" then
        return nil, "executor preparation progress has invalid fields"
    end
    local detail = bounds.text(data.text, 4096)
    if not detail then return nil, "executor preparation progress has invalid detail" end
    return {state = "starting", detail = detail}, nil
end
local function observe_thread(conv: Conversation)
    if conv.node then return end
    local thread = conv.session.snapshot.thread_ref
    if not thread then return end
    local reply = caller.new(funcs.call):invoke("bee.threads.binding:read_after", {thread_id = thread,
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
                        if detail and event.subject == turn.work:ref() then
                            if observation.type == "text" and data.segment_id == "executor-stderr" and type(data.text) == "string" then
                                turn.diagnostics = ((turn.diagnostics or "") .. data.text):sub(-4096)
                            elseif observation.type == "extension" and data.event_name == "bee.placement.attempt" and data.event_revision == "1" and type(data.payload_json) == "string" then
                                local payload, parse_error = json.decode(data.payload_json)
                                if parse_error then conv.notice = "placement observation: " .. tostring(parse_error)
                                else
                                    local progress, progress_error = M.placement_progress(payload)
                                    if not progress then conv.notice = assert(progress_error)
                                    elseif turn.state == "queued" or turn.state == "starting" or turn.state == "working" then
                                        turn.state = progress.state
                                        if progress.state ~= "starting" then turn.progress = nil end
                                        if progress.cause then turn.text = progress.cause end
                                    end
                                end
                            elseif observation.type == "text" and data.channel == "progress" and data.segment_id == "executor-progress"
                                and (turn.state == "queued" or turn.state == "starting" or turn.state == "working") then
                                local progress, progress_error = M.preparation_progress(data)
                                if not progress then conv.notice = assert(progress_error)
                                else turn.state, turn.progress = progress.state, progress.detail end
                            elseif observation.type == "text" and (turn.state == "queued" or turn.state == "starting" or turn.state == "working")
                                and data.channel ~= "progress" and type(data.text) == "string" and #data.text <= 65536 then
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
                            elseif observation.type == "tool.call" and type(data.call_id) == "string" and type(data.tool_name) == "string" then
                                turn.tools = turn.tools or {}
                                turn.tools[data.call_id] = "Tool: " .. data.tool_name
                            elseif observation.type == "tool.result" and type(data.call_id) == "string" and type(data.outcome) == "string" then
                                turn.tools = turn.tools or {}
                                local previous = turn.tools[data.call_id] or "Tool"
                                turn.tools[data.call_id] = previous .. " · " .. data.outcome
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
    conv.activity_evidence = snapshot.activity_evidence
    conv.notice = ""
    for _, turn in ipairs(conv.turns) do
        if turn.state == "queued" or turn.state == "starting" or turn.state == "working" or turn.state == "blocked" or turn.state == "uncertain" then
            if conv.read_only then
                local state, fault = turn.work:state()
                if not state then conv.notice = describe(fault)
                elseif state.phase == "settled" then
                    settle(turn, {tag = "ready", result = state.result})
                elseif state.blocker then turn.state, turn.text = "blocked", state.blocker.message
                elseif state.uncertainty then turn.state, turn.text = "uncertain", state.uncertainty.summary
                else turn.state = state.phase == "queued" and "queued" or state.phase == "reserved" and "starting" or "working" end
            else
                local observed, await_fault = turn.work:await({timeout_ms = 0})
                if not observed then
                    conv.notice = describe(await_fault)
                elseif observed.tag == "pending" then
                    local state = turn.work:state()
                    if turn.state ~= "starting" then turn.state = state and state.phase == "queued" and "queued" or "working" end
                else
                    settle(turn, observed)
                end
            end
        end
    end
    observe_thread(conv)
    return true
end

function M.remember(current: Conversation, saved: Conversation): Conversation
    return {session = current.session, title = current.title, lifecycle = current.lifecycle, activity = current.activity,
        queued = current.queued, activity_evidence = current.activity_evidence, turns = saved.turns,
        unsent = saved.unsent, notice = current.notice, thread_cursor = saved.thread_cursor, node = current.node, read_only = current.read_only, peer_scope = current.peer_scope}
end

function M.resume(client: sessions.Client, ref: string, node: string?, scope: string?): (Conversation?, string?)
    local session, fault = client:get(ref)
    if not session then return nil, describe(fault) end
    local conv = conversation(session)
    conv.node, conv.read_only, conv.peer_scope = node, node ~= nil and scope == "list", scope
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
            if #turns > M.MAX_HISTORY_ITEMS then table.remove(turns, 1) end
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
    local reply = ask("bee.node.binding:read", {workspace_id = id})
    if not reply.ok then return nil end
    local value = bounds.object(reply.value)
    local row = value and bounds.object(value.workspace)
    if not row or row.workspace_id ~= id then return nil end
    local label = bounds.line(row.label, 240)
    local path = bounds.subpath(row.subpath)
    if not label or not path then return nil end
    return {label = label ~= "" and label or names.label(id), folder = path ~= "" and path or "Workspace root"}
end

-- directory lists the sessions in workspace (every permitted workspace when
-- nil), open sessions first; closed sessions only when include_closed.
function M.directory(client: sessions.Client, workspace: string?, include_closed: boolean?): ({Snapshot}?, string?)
    local rows: {Snapshot} = {}
    local cursor: string? = nil
    for _ = 1, M.MAX_PAGES do
        local page, fault = client:list({cursor = cursor})
        if not page then return nil, describe(fault) end
        for _, item in ipairs(page.items) do
            local home = M.home(item.session)
            if (not workspace or home == workspace) and (include_closed or item.lifecycle ~= "closed") then rows[#rows + 1] = item end
        end
        if not page.next then
            table.sort(rows, function(left: Snapshot, right: Snapshot): boolean
                if (left.lifecycle == "closed") ~= (right.lifecycle == "closed") then return left.lifecycle ~= "closed" end
                return left.execution.evidence_at > right.execution.evidence_at
            end)
            return rows, nil
        end
        cursor = page.next
    end
    return rows, "More sessions are available; narrow the workspace filter"
end

function M.stop(conv: Conversation, new_key: () -> string): boolean
    if conv.node and conv.peer_scope ~= "open" then conv.notice = "Session control is not allowed by this bee"; return false end
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
        if turn.state == "queued" or turn.state == "starting" or turn.state == "working" or turn.state == "blocked" then return true end
    end
    return false
end

return M
