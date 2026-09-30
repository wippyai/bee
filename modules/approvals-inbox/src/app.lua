-- MIT. The approvals inbox application: the local viewer's requests from
-- the approval owner, explicit decisions through the owner under the
-- viewed revision, conflicts shown as the owner committed them, unknown
-- answers recovered by reading. Local state is the selection, the detail
-- toggle and one in-flight request; closing the app decides nothing.
local tty = require("tty")
local client = require("client")
local channel = require("channel")
local process = require("process")
local time = require("time")
local uuid = require("uuid")
local json = require("json")
local funcs = require("funcs")
local registry = require("registry")
local appearance = require("appearance")
local frame = require("frame")
local model = require("model")
local view = require("view")
local inbox = require("inbox")
local feeds = require("feeds")
local leases = require("leases")
local lease_form = require("lease_form")
local source_config = require("source_config")
local hive = require("hive")
local hive_types = require("hive_types")
local WORKSPACES = "bee.approvals.inbox:workspaces"
local POLL = "2s"
type FeedSource = {id: string, node_id: string, workspace_id: string, local_owner: boolean, feed: string}
local function unknown_answer(): model.Reply
    return model.unknown_reply()
end
local function admitted_workspaces(): unknown
    local entry = registry.get(WORKSPACES)
    if not entry or type(entry.data) ~= "table" then return nil end
    return (entry.data :: {[string]: unknown}).workspaces
end
local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
    local broker = launch.broker_pid
    local input = assert(tty.events())
    local menu = frame.menu()
    local lifecycle = assert(process.events())
    local states = assert(process.listen("bee.appearance.state", {message = true}))
    local answers = assert(process.listen("bee.application.query.result", {message = true}))
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local preferences = appearance.defaults()
    local local_node = hive_types.pid_parts(tostring(process.pid()))
    if not local_node then error("inbox native node identity is unavailable") end
    local mesh, mesh_error = hive.open()
    if not mesh then error(mesh_error or "inbox Hive listener unavailable") end
    local source_entry = registry.get("bee.approvals.inbox:sources")
    local declared: unknown = nil
    if source_entry and type(source_entry.data) == "table" then declared = source_entry.data.sources end
    local local_workspaces = inbox.workspaces(launch.workspace_id, admitted_workspaces())
    local configured, configure_error = source_config.configure(local_node, local_workspaces, declared)
    if not configured then error(configure_error or "inbox source configuration is invalid") end
    local routed = feeds.new(configured,
        function(source: FeedSource, target: string, request: unknown): (unknown, string?)
            if source.local_owner then return funcs.new():call(target, request) end
            if type(request) ~= "table" then return nil, "invalid owner request" end
            local answer = mesh:call({node_id = source.node_id, service_id = "bee.approvals.binding"},
                {operation_ref = target}, request :: {[string]: unknown}, {timeout = "5s"})
            if not answer.ok then
                -- Transport failure cannot say whether an owner mutation committed.
                if target == "bee.approvals.binding:decide" or target == "bee.approvals.binding:withdraw" then
                    return nil, "owner outcome unknown"
                end
                return {ok = false, error = answer.error, value = nil, replayed = false}, nil
            end
            return answer.value, nil
        end)
    local owner = routed
    local state: model.State = model.new(configured.workspaces)
    local slice: leases.Slice = leases.new()
    local request_form: lease_form.State? = nil
    local form_frame: {rows: {string}, hits: {frame.Hit}} = {rows = {}, hits = {}}
    if launch.resume_state ~= "" and not model.restore(state, launch.resume_state) then error("Invalid inbox checkpoint") end
    local rows: {model.Row} = {}
    local offset = 0
    local hits: {frame.Hit} = {}
    local status = ""
    local announced = false
    local last_checkpoint = ""
    local running, dirty = true, true
    local updates = channel.new(1)
    local busy = false
    local function perform(operation: () -> ())
        if busy then status = "Sync in progress"; dirty = true; return end
        busy = true
        coroutine.spawn(function()
            local ok, failure = pcall(operation)
            busy = false
            if not running then return end
            if not ok then status = "Owner query failed: " .. tostring(failure)
            elseif status == "Sync in progress" then status = "" end
            dirty = true
            updates:send(true)
        end)
    end
    -- One dialog at a time: what it asks and what accepting it does.
    local dialog: {request_id: string, kind: string, confirmation: model.Confirmation?, view: model.ApprovalView?}? = nil
    local ticker = assert(time.ticker(POLL))
    local ticks = ticker:channel()
    local function refresh()
        for _, workspace in ipairs(state.workspaces) do
            if not running then return end
            local pages = 0
            local more = true
            local name: string = workspace
            while more and pages < 8 do
                local intent = model.inbox_intent(state, name)
                local answer: model.Reply = owner:invoke(intent.target, intent.request) or unknown_answer()
                more = model.apply_inbox(state, name, answer)
                pages = pages + 1
            end
        end
        rows = model.rows(state)
        if slice.leases_view then
            for _, workspace in ipairs(state.workspaces) do
                local intent = leases.list_intent(workspace, workspace)
                local raw = owner:lease(workspace, intent.request)
                if raw ~= nil then
                    local failure = leases.apply_list(slice, workspace, workspace, raw)
                    if failure then leases.say(slice, failure) end
                end
            end
        end
        dirty = true
    end
    local function open_selected()
        local intent = model.read_intent(state)
        if not intent then return end
        local reply: model.Reply = owner:invoke(intent.target, intent.request) or unknown_answer()
        model.apply_read(state, tostring(intent.request.approval_id), reply)
        rows = model.rows(state)
        dirty = true
    end
    -- An answer that never arrived is recovered from the owner's record.
    local function recover()
        local intent = model.recovery_intent(state)
        if not intent then return end
        local reply: model.Reply = owner:invoke(intent.target, intent.request) or unknown_answer()
        model.apply_recovery(state, reply)
        rows = model.rows(state)
        dirty = true
    end
    local function act(kind: string)
        local request_id = uuid.v7()
        local intent: model.Intent? = nil
        local refused: string? = nil
        if kind == "withdraw" then intent, refused = model.withdraw_intent(state, request_id)
        else intent, refused = model.decision_intent(state, request_id, kind == "approve" and "approved" or "denied") end
        if not intent then status = refused or ""; dirty = true; return end
        status = ""
        dirty = true
        local reply = owner:invoke(intent.target, intent.request)
        model.apply_answer(state, request_id, reply)
        if not reply then recover() end
        rows = model.rows(state)
        dirty = true
    end
    local function lease_answer(kind: string, intent: leases.Intent?, refused: string?)
        if not intent then status = refused or ""; dirty = true; return end
        local raw = owner:lease(intent.source, intent.request)
        leases.say(slice, raw == nil and "Governance did not answer; refresh to see what committed" or leases.notice(kind, raw))
        refresh()
    end
    local function act_batch(decision: string)
        local intent, refused = leases.batch_intent(slice, state.rows, decision)
        if not intent then status = refused or ""; dirty = true; return end
        local reply = owner:invoke(intent.target, intent.request)
        leases.say(slice, leases.apply_batch(slice, reply, function(view: model.ApprovalView)
            model.apply_read(state, view.approval_id, {kind = "success", value = view, replayed = false})
        end))
        rows = model.rows(state)
        dirty = true
    end
    local function ask_lease(kind: string)
        if busy then status = "Sync in progress"; dirty = true; return end
        if dialog or state.pending then return end
        local detail = state.detail
        local selected = model.selected_row(state)
        if not detail or not selected or detail.approval_id ~= selected.approval_id then status = "Open a request first"; dirty = true; return end
        local request_id, err
        if kind == "lease_propose" then
            if detail.state ~= "pending" or detail.proposal.ref ~= leases.ACTIVATION then status = "Open a pending activation request to lease its application"; dirty = true; return end
            request_form = lease_form.new(detail)
            dirty = true
            return
        else
            if detail.state ~= "decided" or detail.decision ~= "approved" or detail.proposal.ref ~= leases.PROPOSAL then status = "Open an approved lease request to grant it"; dirty = true; return end
            request_id, err = client.query(launch, {kind = "confirm", title = "Grant this lease?",
                message = model.text(selected.target .. " for " .. selected.requester_id, 512), accept = "Grant"})
        end
        if not request_id then status = tostring(err); dirty = true; return end
        dialog = {request_id = request_id, kind = kind, confirmation = nil, view = detail}
        dirty = true
    end
    local function ask_batch(decision: string)
        if busy then status = "Sync in progress"; dirty = true; return end
        if dialog or state.pending then return end
        local marked = leases.marked(slice, state.rows)
        if #marked == 0 then status = "Mark pending requests with M first"; dirty = true; return end
        local approve = decision == "approved"
        local request_id, err = client.query(launch, {kind = "confirm",
            title = (approve and "Approve " or "Deny ") .. tostring(#marked) .. " requests?",
            message = model.text(marked[1].effect .. " on " .. marked[1].target .. " for " .. marked[1].requester_id, 512),
            accept = approve and "Approve all" or "Deny all"})
        if not request_id then status = tostring(err); dirty = true; return end
        dialog = {request_id = request_id, kind = approve and "batch_approve" or "batch_deny", confirmation = nil, view = nil}
        dirty = true
    end
    local function ask_revoke()
        if busy then status = "Sync in progress"; dirty = true; return end
        if dialog then return end
        local row = leases.selected(slice)
        if not row or not leases.revocable(row) then status = "Select a lease that can be revoked"; dirty = true; return end
        local request_id, err = client.query(launch, {kind = "confirm", title = "Revoke this lease?",
            message = model.text(row.target .. " used " .. tostring(row.applies_used), 512), accept = "Revoke"})
        if not request_id then status = tostring(err); dirty = true; return end
        dialog = {request_id = request_id, kind = "revoke", confirmation = nil, view = nil}
        dirty = true
    end
    -- Every decision passes through the shell's confirmation; nothing acts
    -- on a row selection or a key alone.
    local function ask(kind: string)
        if dialog or state.pending or busy then return end
        local selected = model.selected_row(state)
        local confirmation = model.confirmation(state)
        if not selected or not confirmation then status = "Open a pending request before deciding"; dirty = true; return end
        if kind == "approve" and leases.is_review(state.detail) and not slice.review_complete then
            status = "Scroll to the end of the lease terms before approving"; dirty = true; return
        end
        local title = kind == "approve" and "Approve this request?" or (kind == "deny" and "Deny this request?" or "Withdraw this request?")
        local message = model.text(selected.effect .. " on " .. selected.target .. " for " .. selected.requester_id, 512)
        local accept = kind == "approve" and "Approve" or (kind == "deny" and "Deny" or "Withdraw")
        local request_id, err = client.query(launch, {kind = "confirm", title = title, message = message, accept = accept})
        if not request_id then status = tostring(err); dirty = true; return end
        dialog = {request_id = request_id, kind = kind, confirmation = confirmation}
        dirty = true
    end
    if broker then process.send(broker, "bee.appearance.request", {version = 1, request_id = uuid.v7(), op = "state"}) end
    perform(function()
        refresh()
        if state.selected and state.rows[state.selected :: string] then open_selected() elseif state.selected then model.select(state, nil) end
    end)
    while running do
        if dirty then
            local open_form = request_form
            if open_form then
                form_frame = lease_form.draw(width, height, preferences, open_form)
                frame.render(form_frame, menu, preferences)
                assert(output:present(form_frame.rows, {cursor = {x = 1, y = 1, visible = false}}))
            else
                local drawn = view.draw(width, height, preferences, state, rows, offset, status, slice)
                frame.render(drawn, menu, preferences)
                hits = drawn.hits
                offset = drawn.offset
                assert(output:present(drawn.rows, {cursor = {x = 1, y = 1, visible = false}}))
            end
            if not announced then client.ready(launch); announced = true end
            local checkpoint = model.checkpoint(state)
            if checkpoint ~= last_checkpoint then
                local sent = client.checkpoint(launch, checkpoint)
                if sent then last_checkpoint = checkpoint end
            end
            dirty = false
        end
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), states:case_receive(), answers:case_receive(), ticks:case_receive(), updates:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then running = false end
        elseif event.channel == updates then
            dirty = true
        elseif event.channel == ticks then
            if not busy then
                if state.pending then perform(recover) else perform(refresh) end
            end
        elseif event.channel == states then
            local message = event.value
            if broker and message:from() == broker then
                local payload: unknown = message:payload():data()
                local next_preferences = appearance.decode(payload)
                if next_preferences and type(payload) == "table" and payload.version == 1 then preferences = next_preferences; dirty = true end
            end
        elseif event.channel == answers then
            local message = event.value
            local result = client.query_result(launch, tostring(message:from()), message:payload():data())
            if result and dialog and result.request_id == dialog.request_id then
                local asked = dialog
                dialog = nil
                if result.action ~= "accept" then status = "Cancelled"; dirty = true
                elseif asked.kind == "batch_approve" or asked.kind == "batch_deny" then
                    perform(function() act_batch(asked.kind == "batch_approve" and "approved" or "denied") end)
                elseif asked.kind == "revoke" then
                    perform(function() lease_answer("lease_revoke", leases.revoke_intent(slice, uuid.v7())) end)
                elseif asked.kind == "lease_grant" and asked.view then
                    local view = asked.view
                    perform(function() lease_answer("lease_grant", leases.grant_intent(view, uuid.v7())) end)
                elseif not asked.confirmation or not model.confirmation_matches(state, asked.confirmation) then
                    status = "Request changed; open it and confirm again"; dirty = true
                else perform(function()
                    if model.confirmation_matches(state, asked.confirmation) then act(asked.kind)
                    else status = "Request changed; open it and confirm again"; dirty = true end
                end) end
            end
        else
            local data, handled = frame.route(menu, event.value, request_form ~= nil)
            if handled then dirty = true end
            if data then
                if data.type == "close" then running = false
                elseif data.type == "resize" then width, height = data.width, data.height; dirty = true
                elseif request_form and (data.type == "key" or data.type == "mouse") then
                    local open_form = request_form
                    local outcome = lease_form.input(open_form, data, form_frame)
                    if outcome == "cancel" then request_form = nil; status = "Cancelled"
                    elseif outcome == "submit" then
                        local spec = lease_form.submit(open_form)
                        if spec then
                            local view = open_form.view
                            request_form = nil
                            perform(function() lease_answer("lease_propose", leases.propose_intent(view, spec, uuid.v7())) end)
                        end
                    end
                    dirty = true
                elseif data.type == "key" and data.action ~= "release" then
                    local key = data.key_type
                    local text = tostring(data.key or "")
                    status = ""
                    leases.say(slice, "")
                    if text == "v" then
                        leases.show_leases(slice, not slice.leases_view); offset = 0
                        perform(refresh); dirty = true
                    elseif slice.leases_view then
                        if key == "up" or text == "k" then leases.move(slice, -1); dirty = true
                        elseif key == "down" or text == "j" then leases.move(slice, 1); dirty = true
                        elseif text == "x" then ask_revoke()
                        elseif text == "r" then perform(refresh)
                        elseif key == "esc" or key == "escape" then leases.show_leases(slice, false); dirty = true end
                    elseif leases.is_review(state.detail) and state.selected ~= nil and (key == "up" or key == "down" or key == "pgup" or key == "pgdown" or text == "j" or text == "k") then
                        leases.review_scroll(slice, (key == "up" or text == "k") and -1 or (key == "pgup" and -8 or (key == "pgdown" and 8 or 1)))
                        dirty = true
                    elseif key == "up" or text == "k" then model.move(state, -1); dirty = true
                    elseif key == "down" or text == "j" then model.move(state, 1); dirty = true
                    elseif key == "pgup" then model.move(state, -8); dirty = true
                    elseif key == "pgdown" then model.move(state, 8); dirty = true
                    elseif text == "m" then
                        local selected = model.selected_row(state)
                        local refused = selected and leases.toggle_mark(slice, state.rows, selected.approval_id) or "Select a request first"
                        status = refused or ""; dirty = true
                    elseif text == "b" then ask_batch("approved")
                    elseif text == "n" then ask_batch("denied")
                    elseif text == "l" then ask_lease("lease_propose")
                    elseif text == "g" then ask_lease("lease_grant")
                    elseif key == "enter" or text == "o" then perform(open_selected)
                    elseif text == "a" then ask("approve")
                    elseif text == "d" then ask("deny")
                    elseif text == "w" then ask("withdraw")
                    elseif text == "r" then perform(function() if state.pending then recover() else refresh() end end)
                    elseif text == "t" then model.toggle_technical(state); dirty = true
                    elseif key == "esc" or key == "escape" then
                        if leases.is_review(state.detail) then model.select(state, nil); dirty = true else running = false end
                    end
                elseif data.type == "mouse" and data.action == "press" and data.button == "left" then
                    local hit = frame.hit(hits, math.floor(tonumber(data.x) or 1), math.floor(tonumber(data.y) or 1))
                    if hit then
                        status = ""
                        if hit.kind == "lease_row" then
                            local row = leases.rows(slice)[hit.index]
                            if row then leases.select(slice, row); dirty = true end
                        elseif hit.kind == "revoke" then ask_revoke()
                        elseif hit.kind == "requests" or hit.kind == "leases" then
                            leases.show_leases(slice, hit.kind == "leases"); offset = 0; perform(refresh); dirty = true
                        elseif hit.kind == "mark" then
                            local selected = model.selected_row(state)
                            local refused = selected and leases.toggle_mark(slice, state.rows, selected.approval_id) or "Select a request first"
                            status = refused or ""; dirty = true
                        elseif hit.kind == "batch_approve" then ask_batch("approved")
                        elseif hit.kind == "batch_deny" then ask_batch("denied")
                        elseif hit.kind == "lease" then ask_lease("lease_propose")
                        elseif hit.kind == "grant" then ask_lease("lease_grant")
                        elseif hit.kind == "row" then
                            local row = rows[hit.index]
                            if row then model.select(state, row.approval_id); dirty = true end
                        elseif hit.kind == "open" then perform(open_selected)
                        elseif hit.kind == "approve" or hit.kind == "deny" or hit.kind == "withdraw" then ask(hit.kind)
                        elseif hit.kind == "refresh" then perform(function() if state.pending then recover() else refresh() end end)
                        elseif hit.kind == "technical" then model.toggle_technical(state); dirty = true end
                    end
                elseif data.type == "mouse" and data.action == "wheel" then
                    local step = (data.button == "wheel_up" or data.button == "up") and -1 or 1
                    if leases.is_review(state.detail) then leases.review_scroll(slice, step) else model.move(state, step) end
                    dirty = true
                end
            end
        end
    end
    ticker:stop()
    mesh:close()
    process.unlisten(states)
    process.unlisten(answers)
    output:close()
    tty.stop()
end
return {main = main}
