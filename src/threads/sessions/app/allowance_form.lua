-- MIT
local forms = require("forms")
local frame = require("frame")
local appearance = require("appearance")
local tty = require("tty")
local funcs = require("funcs")
local bounds = require("bounds")
local json = require("json")
local clock = require("clock")
local system = require("system")
local M = {}
type Object = {[string]: unknown}
type State = {form: forms.Form, workspace: string, approval: Object?, rows: {Object}, status: string, known: string}
type Frame = {rows: {string}, hits: {frame.Hit}, controls: frame.Controls?}
type Intent = {target: string, request: Object}
function M.new(workspace: string, approval: Object?, known: {string}?): State
    local proposal = approval and bounds.object(approval.proposal)
    local payload = proposal and bounds.object(proposal.payload)
    local peer = payload and bounds.id(payload.peer) or ""
    local rows: {Object} = {}
    if not approval then
        local raw = funcs.call("bee.threads.sessions.binding:allowance", {operation = "list", workspace_id = workspace})
        local reply = bounds.object(raw)
        local value = reply and bounds.object(reply.value)
        local items = value and bounds.dense_list(value.items, 64, "allowances")
        for _, item in ipairs(items or {}) do
            local row = bounds.object(item)
            if row then rows[#rows + 1] = row end
        end
    end
    local choices: {forms.Option} = {{label = "Enter an identity", value = ""}}
    local seen: {[string]: boolean} = {}
    local local_node = system.node.id()
    local function offer(raw: unknown)
        local node = bounds.id(raw)
        if node and node ~= local_node and not seen[node] then
            seen[node] = true
            choices[#choices + 1] = {label = node, value = node}
        end
    end
    local directory_error = ""
    if known then
        for index, node in ipairs(known) do if index <= 16 then offer(node) end end
    else
        local members, problem = system.cluster.members()
        if problem then directory_error = "Known bees unavailable: " .. tostring(problem) end
        for index, member in ipairs(members or {}) do if index <= 16 then offer(member.id) end end
    end
    for _, row in ipairs(rows) do offer(row.peer) end
    return {workspace = workspace, approval = approval, rows = rows, status = directory_error, known = "", form = forms.form_new({
        forms.field_text("peer", "Bee", peer, {max_length = 160, hint = "Node identity; choose a known bee below or enter it here"}),
        forms.field_select("scope", "Access", {{label = "See agents (list only)", value = "list"},
            {label = "Message and await", value = "message"}, {label = "Open new sessions and control", value = "open"}}, "list"),
        forms.field_select("duration", "Duration", {{label = "1 hour", value = "3600000"}, {label = "24 hours", value = "86400000"},
            {label = "7 days", value = "604800000"}, {label = "Permanent", value = "permanent"}}, "3600000"),
        forms.field_select("action", "Action", {{label = "Allow", value = "grant"}, {label = "Revoke", value = "revoke"}}, "grant"),
        forms.field_select("known", "Known bee", choices, "", {disabled = approval ~= nil}),
    })}
end
local function choose_known(state: State)
    local chosen = forms.value(state.form.fields[5])
    if chosen ~= state.known then
        state.known = chosen
        if chosen ~= "" then forms.text_set(assert(state.form.fields[1].text), chosen) end
    end
end
function M.intent(state: State): (Intent?, string?)
    choose_known(state)
    if not forms.validate(state.form) then return nil, "Fix the marked fields" end
    local peer = forms.value(state.form.fields[1])
    if peer == "" or peer:find("[^A-Za-z0-9_.-]") then return nil, "Enter the bee's node identity" end
    local scope, duration, action = forms.value(state.form.fields[2]), forms.value(state.form.fields[3]), forms.value(state.form.fields[4])
    local milliseconds = duration ~= "permanent" and math.tointeger(tonumber(duration)) or nil
    local approved = state.approval
    if approved then
        local proposal = bounds.object(approved.proposal)
        local payload = proposal and bounds.object(proposal.payload)
        if not payload or peer ~= payload.peer then return nil, "The request belongs to another bee" end
        return {target = "bee.approvals.binding:decide", request = {approval_id = approved.approval_id, expected_revision = approved.revision,
            proposal_digest = approved.proposal_digest, decision = action == "revoke" and "denied" or "approved",
            response = action == "grant" and {text = assert(json.encode({scope = scope, duration_ms = milliseconds}))} or nil}}, nil
    end
    return {target = "bee.threads.sessions.binding:allowance", request = {operation = action, peer = peer, workspace_id = state.workspace,
        scope = scope, duration_ms = milliseconds}}, nil
end
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: State): Frame
    local painter = frame.new(width, height, preferences)
    frame.header(painter, "AGENT ALLOWANCES", "This bee · " .. state.workspace)
    local y = 3
    for _, row in ipairs(state.rows) do
        if y >= height - 12 then break end
        frame.line(painter, y, tostring(row.peer) .. " · " .. (row.allowed == true and tostring(row.scope) or "not allowed")
            .. (type(row.expires_ms) == "number" and (" · until " .. clock.stamp(math.floor(row.expires_ms))) or row.allowed == true and " · permanent" or ""), painter.theme.muted)
        y = y + 1
    end
    local sizes: {integer} = {}
    for index, field in ipairs(state.form.fields) do sizes[index] = forms.rows(field) end
    local rects = frame.stack({x = 2, y = y, width = math.floor(math.max(1, width - 2)), height = math.floor(math.max(1, height - y - 3))}, sizes, 0)
    for index, rect in ipairs(rects) do forms.draw(painter, rect, state.form, index) end
    frame.footer(painter, state.status, frame.hints({{key = "Tab", verb = "next"}, {key = "Ctrl+S", verb = "apply"}, {key = "Esc", verb = "back"}}), nil,
        {{kind = "submit", label = "Apply", enabled = true, primary = true}, {kind = "cancel", label = "Back", enabled = true}})
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
end
function M.input(state: State, event: tty.TTYEvent, drawn: Frame): string?
    if event.type == "key" and event.action == "press" then
        if event.key_type == "escape" or event.key_type == "esc" then return "cancel" end
        if event.ctrl and event.key == "s" then return "submit" end
        local peer_edit = state.form.focus == 1 and event.key_type ~= "tab"
        if forms.key(state.form, event) and peer_edit then
            forms.select_set(assert(state.form.fields[5].select), "")
            state.known = ""
        end
        choose_known(state)
    elseif event.type == "mouse" and event.action == "press" and event.button == "left" then
        local hit = frame.hit(drawn.hits, math.floor(tonumber(event.x) or 0), math.floor(tonumber(event.y) or 0))
        if hit and (hit.kind == "submit" or hit.kind == "cancel") then return hit.kind end
        if hit then forms.click(state.form, hit); choose_known(state) end
    end
    return nil
end
return M
