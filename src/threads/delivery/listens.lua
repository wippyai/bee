local sql = require("sql")
local json = require("json")
local security = require("security")
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local reader = require("reader")
local access = require("access")
local traits = require("traits")
local journal = require("journal")
local record_types = require("record_types")
local trait_access = require("trait_access")
local M = {}
type Event = {id: string, kind: string, session_ref: string, thread_id: string, sequence: integer, record_ref: record_types.Ref, turn_ref: string?, payload: unknown, usage: unknown?}
type Interval = {start: integer, finish: integer?}
function M.discover(tx: sql.Transaction, actor: string, trait: string): ({traits.Selection}?, string?)
    if access.forwarded(actor) then return nil, "peers cannot act as local listeners" end
    local identity = security.actor()
    local meta = identity and bounds.object(identity:meta())
    local declared, invalid = trait_access.load(trait)
    if not declared then return nil, invalid end
    if not meta or meta.definition_id ~= declared.application_ref or meta.definition_revision ~= declared.application_revision
        or not bounds.id(meta.workspace_id) then return nil, "listener identity does not own this trait" end
    local rows, err = tx:query("SELECT session_ref FROM bee_session_traits WHERE selected=1 AND trait_id=? AND workspace_id=? ORDER BY session_ref LIMIT 129", {trait, meta.workspace_id})
    if not rows or err then return nil, "read approved listen sessions" end
    if #rows > 128 then return nil, "listen discovery exceeds 128 sessions; subscribe by session" end
    local selections: {traits.Selection} = {}
    for _, row in ipairs(rows) do
        local stored, err = traits.read(tx, assert(bounds.id(row.session_ref)), trait)
        if not stored then return nil, err or "listen selection is missing" end
        local head, member, selected = M.authorize(tx, stored.thread_id, actor, stored.session_ref, trait)
        if head and member and selected then selections[#selections + 1] = selected end
    end
    return selections, nil
end
function M.authorize(tx: sql.Transaction, thread: string, actor: string, session: string, trait: string): (reader.Head?, reader.Member?, traits.Selection?, string?)
    if access.forwarded(actor) then return nil, nil, nil, "peers cannot act as local listeners" end
    local identity = security.actor()
    local meta = identity and bounds.object(identity:meta())
    local selection, err = traits.read(tx, session, trait)
    if not selection or err or not selection.selected or selection.thread_id ~= thread then return nil, nil, nil, err or "trait is not active in this session" end
    if not meta or meta.workspace_id ~= selection.workspace_id or meta.definition_id ~= selection.declaration.application_ref
        or meta.definition_revision ~= selection.declaration.application_revision then return nil, nil, nil, "listener identity differs from the approved app and workspace" end
    local aliases, alias_error = tx:query("SELECT stable FROM bee_thread_app_alias WHERE instance=? AND active=1 AND workspace_id=? AND definition_id=?", {actor, selection.workspace_id, selection.declaration.application_ref})
    if not aliases or alias_error then return nil, nil, nil, "read listener app attestation" end
    local stable = #aliases == 1 and bounds.id(aliases[1].stable) or nil
    if not stable then return nil, nil, nil, "listener app is not admitted" end
    err = traits.consent(tx, selection)
    if err then return nil, nil, nil, err end
    local head, head_error = reader.head(tx, thread)
    if not head then return nil, nil, nil, head_error or "listener thread is missing" end
    local principal = "listen:" .. assert(hash.sha256(stable .. "\0" .. session .. "\0" .. trait))
    return head, {actor = principal, role = "observer", active = true, revision = selection.revision}, selection, nil
end
function M.intervals(tx: sql.Transaction, selection: traits.Selection): ({Interval}?, string?)
    local rows, err = tx:query("SELECT start_sequence,end_sequence FROM bee_session_trait_intervals WHERE session_ref=? AND trait_id=? AND declaration_json=? ORDER BY generation",
        {selection.session_ref, selection.trait_id, assert(canonical.encode(selection.declaration))})
    if not rows or err then return nil, "read listener activation intervals" end
    local intervals: {Interval} = {}
    for _, row in ipairs(rows) do
        local start = bounds.integer(row.start_sequence)
        local finish = row.end_sequence == nil and nil or bounds.integer(row.end_sequence)
        if not start or (row.end_sequence ~= nil and not finish) then return nil, "listener activation interval is corrupt" end
        intervals[#intervals + 1] = {start = start, finish = finish}
    end
    return intervals, nil
end
local function visible(intervals: {Interval}, sequence: integer): boolean
    for _, interval in ipairs(intervals) do
        if sequence > interval.start and (interval.finish == nil or sequence <= interval.finish) then return true end
    end
    return false
end
local function observation_kind(data: {[string]: unknown}): string?
    if data.type == "session.state" then
        if data.state == "started" then return "session.started" end
        if data.state == "ended" then return "session.ended" end
    elseif data.type == "turn.signal" and data.phase == "submitted" then return "prompt.submitted"
    elseif data.type == "tool.call" then return "tool.before"
    elseif data.type == "tool.result" then return "tool.after" end
    return nil
end
function M.event(tx: sql.Transaction, selection: traits.Selection, intervals: {Interval}, record: record_types.Record): (Event?, string?)
    if not visible(intervals, record.sequence) or access.forwarded(record.producer_id) then return nil, nil end
    local session: string?, kind: string?, turn: string? = nil, nil, record.turn_id
    local payload: unknown = {}
    if record.kind == "observation" then
        local data = record.body.data
        if data.type == "extension" and data.event_name == "bee.sessions.event" then
            if record.source ~= "bee" then return nil, nil end
            local decoded = bounds.object(json.decode(data.payload_json))
            if not decoded then return nil, "session event is corrupt" end
            session = bounds.id(decoded.session_ref)
            local detail = bounds.object(decoded.data) or {}
            turn = bounds.id(detail.turn)
            payload = detail
            if decoded.kind == "session.created" then kind = "session.started"
            elseif decoded.kind == "session.state_changed" and detail.to == "closed" then kind = "session.ended"
            elseif decoded.kind == "work.queued" then kind = "prompt.submitted"
            elseif decoded.kind == "work.settled" then kind = "turn.completed"
            elseif decoded.kind == "turn.observation" then
                local normalized = bounds.object(detail.observation)
                local observed = normalized and bounds.object(normalized.data)
                if observed then kind = observation_kind(observed); payload = observed end
            end
            if session == selection.session_ref and (kind == "turn.completed" or kind == "prompt.submitted") then
                local work_ref = bounds.id(decoded.subject)
                local work: journal.Work? = nil
                local err: string? = nil
                if work_ref then work, err = journal.work(tx, work_ref, selection.workspace_id) end
                if err then return nil, err end
                if work then
                    detail.input = json.decode(work.input_json)
                    if kind == "turn.completed" then detail.result = work.result_json and json.decode(work.result_json) or nil end
                end
            end
        else
            session = record.action_id
            local object = bounds.object(data)
            if object then kind = observation_kind(object); payload = object end
        end
    end
    if session ~= selection.session_ref or not kind or not bounds.member(kind, selection.declaration.listens or {}) then return nil, nil end
    return {id = record.record_id, kind = kind, session_ref = selection.session_ref, thread_id = record.thread_id, sequence = record.sequence,
        record_ref = {thread_id = record.thread_id, record_id = record.record_id}, turn_ref = turn, payload = payload, usage = kind == "turn.completed" and bounds.object(payload) and assert(bounds.object(payload)).usage or nil}, nil
end
return M
