local sql = require("sql")
local json = require("json")
local bounds = require("bounds")
local canonical = require("canonical")
local grants = require("grants")
local clock = require("clock")
local trait_access = require("trait_access")
local agent_trait = require("agent_trait")
local reader = require("reader")
local transaction = require("transaction")
local M = {}
type Selection = {session_ref: string, trait_id: string, thread_id: string, workspace_id: string, declaration: agent_trait.Declaration, grant_id: string, selected: boolean, revision: integer}
local function execute(tx: sql.Transaction, statement: string, arguments: {unknown}): string?
    local _, err = tx:execute(statement, arguments)
    return err and tostring(err) or nil
end
function M.read(tx: sql.Transaction, session: string, trait: string): (Selection?, string?)
    local rows, err = tx:query("SELECT * FROM bee_session_traits WHERE session_ref = ? AND trait_id = ?", {session, trait})
    if not rows or err then return nil, "read session trait" end
    if #rows == 0 then return nil, nil end
    local row = rows[1]
    local declared, invalid = agent_trait.declaration(type(row.declaration_json) == "string" and json.decode(row.declaration_json) or nil)
    if not declared then return nil, invalid end
    return {session_ref = assert(bounds.id(row.session_ref)), trait_id = assert(bounds.id(row.trait_id)), thread_id = assert(bounds.id(row.thread_id)),
        workspace_id = assert(bounds.id(row.workspace_id)), declaration = declared, grant_id = assert(bounds.id(row.grant_id)),
        selected = row.selected == 1, revision = assert(bounds.integer(row.revision))}, nil
end
function M.consent(tx: sql.Transaction, selection: Selection): string?
    local grant, err = grants.read(tx, selection.grant_id)
    if not grant or err or grants.state(grant, clock.milliseconds()) ~= "active" then return err or "trait consent is no longer active" end
    local proposal = bounds.object(grant.scope.parameters)
    local payload = proposal and bounds.object(proposal.payload)
    if grant.domain ~= "gateway_access" or grant.provenance.kind ~= "decision" or grant.workspace_id ~= selection.workspace_id
        or not payload or payload.session_ref ~= selection.session_ref or payload.thread_id ~= selection.thread_id then return "trait consent belongs to another scope" end
    local approved = false
    for _, raw in ipairs(bounds.array(payload.declarations, 16) or {}) do
        local declaration = agent_trait.declaration(raw)
        if declaration and canonical.encode(declaration) == canonical.encode(selection.declaration) then approved = true end
    end
    if not approved then return "trait declarations differ from person consent" end
    local live, invalid = trait_access.review(selection.declaration)
    if not live then return invalid end
    local sessions, session_error = tx:query("SELECT state FROM bee_sessions WHERE session_ref = ? AND thread_id = ? AND workspace_id = ?", {selection.session_ref, selection.thread_id, selection.workspace_id})
    if not sessions or session_error then return "read trait session" end
    if #sessions ~= 1 then return "trait session is missing" end
    return nil
end
function M.stop(tx: sql.Transaction, selection: Selection): string?
    local head, err = reader.head(tx, selection.thread_id)
    if not head then return err or "trait thread is missing" end
    err = execute(tx, "UPDATE bee_session_trait_intervals SET end_sequence = ? WHERE session_ref = ? AND trait_id = ? AND end_sequence IS NULL",
        {head.head_sequence, selection.session_ref, selection.trait_id})
    if err then return err end
    err = execute(tx, "UPDATE bee_session_traits SET selected = 0, revision = revision + 1 WHERE session_ref = ? AND trait_id = ? AND selected = 1", {selection.session_ref, selection.trait_id})
    if err then return err end
    local rows, read_error = tx:query("SELECT subscription_id FROM bee_thread_subscriptions WHERE json_extract(filter_json, '$.session_ref') = ? AND json_extract(filter_json, '$.trait_id') = ?", {selection.session_ref, selection.trait_id})
    if not rows or read_error then return "read trait subscriptions" end
    for _, row in ipairs(rows) do
        local id = assert(bounds.id(row.subscription_id))
        err = transaction.close_subscription(tx, id, transaction.now())
        if err then return err end
        err = transaction.retire_pages(tx, id)
        if err then return err end
    end
    return nil
end
function M.start(tx: sql.Transaction, selection: Selection): string?
    local err = M.consent(tx, selection)
    if err then return err end
    if #(selection.declaration.hooks or {}) > 0 then return "hooks not yet supported: " .. selection.trait_id end
    local sessions, session_error = tx:query("SELECT state FROM bee_sessions WHERE session_ref=?", {selection.session_ref})
    if not sessions or session_error then return "read trait session lifecycle" end
    if #sessions ~= 1 or sessions[1].state == "closed" then return "trait session has ended" end
    if selection.selected then return nil end
    local head, head_error = reader.head(tx, selection.thread_id)
    if not head then return head_error or "trait thread is missing" end
    err = execute(tx, "UPDATE bee_session_traits SET selected = 1, revision = revision + 1 WHERE session_ref = ? AND trait_id = ?", {selection.session_ref, selection.trait_id})
    if err then return err end
    return execute(tx, "INSERT INTO bee_session_trait_intervals(session_ref, trait_id, generation, start_sequence, declaration_json) VALUES (?, ?, ?, ?, ?)",
        {selection.session_ref, selection.trait_id, selection.revision + 1, head.head_sequence, assert(canonical.encode(selection.declaration))})
end
function M.approve(tx: sql.Transaction, grant_id: string): string?
    local grant, err = grants.read(tx, grant_id)
    if not grant then return err or "trait grant is missing" end
    local proposal = bounds.object(grant.scope.parameters)
    local payload = proposal and bounds.object(proposal.payload)
    local declarations = payload and bounds.array(payload.declarations, 16) or {}
    if not declarations then return "invalid trait declarations" end
    if #declarations == 0 then return nil end
    local session = payload and bounds.id(payload.session_ref)
    local thread = payload and bounds.id(payload.thread_id)
    if not session or not thread then return "trait grant has no session" end
    for _, raw in ipairs(declarations) do
        local declared, invalid = agent_trait.declaration(raw)
        if not declared then return invalid end
        local existing, read_error = M.read(tx, session, declared.id)
        if read_error then return read_error end
        if existing then
            err = M.stop(tx, existing)
            if err then return err end
        end
        err = execute(tx, [[INSERT INTO bee_session_traits(session_ref,trait_id,thread_id,workspace_id,declaration_json,grant_id,selected,revision)
            VALUES (?,?,?,?,?,?,0,1) ON CONFLICT(session_ref,trait_id) DO UPDATE SET declaration_json=excluded.declaration_json,grant_id=excluded.grant_id]],
            {session, declared.id, thread, grant.workspace_id, assert(canonical.encode(declared)), grant_id})
        if err then return err end
        local selection = assert(M.read(tx, session, declared.id))
        err = M.start(tx, selection)
        if err then return err end
    end
    return nil
end
function M.selection(tx: sql.Transaction, session: string, thread: string, workspace: string, declarations: {agent_trait.Declaration}): ({string}?, {string}?, string?)
    local allowed: {string}, active: {string} = {}, {}
    for _, declared in ipairs(declarations) do
        if agent_trait.extension(declared) then
            local stored, err = M.read(tx, session, declared.id)
            if err then return nil, nil, err end
            if stored and stored.thread_id == thread and stored.workspace_id == workspace then
                err = M.consent(tx, stored)
                if err then
                    if stored.selected then
                        local stopped = M.stop(tx, stored)
                        if stopped then return nil, nil, stopped end
                    end
                elseif canonical.encode(stored.declaration) == canonical.encode(declared) then
                    allowed[#allowed + 1] = declared.id
                    if stored.selected then active[#active + 1] = declared.id end
                end
            end
        end
    end
    return allowed, active, nil
end
function M.select(tx: sql.Transaction, session: string, thread: string, workspace: string, declarations: {agent_trait.Declaration}, active: {string}): string?
    local wanted: {[string]: boolean} = {}
    for _, id in ipairs(active) do wanted[id] = true end
    for _, declared in ipairs(declarations) do
        if agent_trait.extension(declared) then
            local stored, err = M.read(tx, session, declared.id)
            if err then return err end
            if wanted[declared.id] then
                if not stored or stored.thread_id ~= thread or stored.workspace_id ~= workspace then return "trait requires person approval" end
                err = M.start(tx, stored)
            elseif stored and stored.selected then err = M.stop(tx, stored) end
            if err then return err end
        end
    end
    return nil
end
return M
