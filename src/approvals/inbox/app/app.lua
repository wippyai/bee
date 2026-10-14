-- MIT. The approvals inbox application: the local viewer's requests from
-- the approval owner, explicit decisions through the owner under the
-- viewed revision, conflicts shown as the owner committed them, unknown
-- answers recovered by reading. Local state is the selection, the detail
-- toggle and one in-flight request; closing the app decides nothing.
local tty = require("tty")
local client = require("client")
local node_client = require("node_client")
local confirmation_ui = require("confirmation_ui")
local channel = require("channel")
local process = require("process")
local time = require("time")
local cdc = require("cdc")
local uuid = require("uuid")
local funcs = require("funcs")
local registry = require("registry")
local appearance = require("appearance")
local frame = require("frame")
local model = require("model")
local windows = require("windows")
local grants = require("grants")
local canonical = require("canonical")
local bounds = require("bounds")
local clock = require("clock")
local view = require("view")
local inbox = require("inbox")
local feeds = require("feeds")
local leases = require("leases")
local lease_form = require("lease_form")
local question_form = require("question_form")
local allowance_form = require("allowance_form")
local source_config = require("source_config")
local protocol = require("protocol")
local system = require("system")
local WORKSPACES = "bee.approvals.inbox.app:workspaces"
local POLL = "2s"
type FeedSource = {id: string, node_id: string, workspace_id: string, local_owner: boolean, feed: string}
local function unknown_answer(): model.Reply
    return model.unknown_reply()
end
local function admitted_workspaces(): unknown
    local entry = registry.get(WORKSPACES)
    if not entry or type(entry.data) ~= "table" then return nil end
    return (entry.data).workspaces
end
local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
    local broker = launch.broker_pid
    local input = assert(tty.events())
    local menu = frame.menu()
    local lifecycle = assert(process.events())
    local states = assert(process.listen(appearance.TOPIC, {message = true}))
    local answers = assert(process.listen("bee.app.query.result", {message = true}))
    local navigations = assert(process.listen("bee.app.navigate", {message = true}))
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local preferences = launch.appearance
    local local_node = system.node.id()
    if not local_node then error("inbox native node identity is unavailable") end
    local source_entry = registry.get("bee.approvals.inbox.app:sources")
    local declared: unknown = nil
    if source_entry and type(source_entry.data) == "table" then declared = source_entry.data.sources end
    local local_workspaces = inbox.workspaces(launch.workspace_id, admitted_workspaces())
    local configured, configure_error = source_config.configure(local_node, local_workspaces, declared)
    if not configured then error(configure_error or "inbox source configuration is invalid") end
    local routed = feeds.new(configured,
        function(source: FeedSource, target: string, request: unknown): (unknown, string?)
            if source.local_owner then return funcs.new():call(target, request) end
            if type(request) ~= "table" then return nil, "invalid owner request" end
            local operation = target:match("^bee%.approvals%.binding:(.+)$")
            if not operation then return nil, "invalid owner operation" end
            local answer, call_error = protocol.call(source.node_id, "approvals." .. operation, request, "5s")
            if not answer then answer = {ok = false, value = nil, error = call_error} end
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
    local answer_form: question_form.State? = nil
    local request_form: lease_form.State? = nil
    local allowance_request: allowance_form.State? = nil
    local form_frame: {rows: {string}, hits: {frame.Hit}} = {rows = {}, hits = {}}
    if launch.resume_state ~= "" and not model.restore(state, launch.resume_state) then error("Invalid inbox checkpoint") end
    state.technical = false
    local rows: {model.Row} = {}
    local workspace_names: {[string]: model.Workspace} = {}
    local offset = 0
    local capacity = 0
    local hits: {frame.Hit} = {}
    local shown_review: model.Confirmation? = nil
    local review_progress: model.Confirmation? = nil
    local review_end = 0
    local status = ""
    local announced = false
    local last_checkpoint = ""
    local running, dirty = true, true
    local updates = channel.new(1)
    local busy, action_busy = false, false
    local function perform(operation: () -> (), action: boolean?)
        if action then
            if action_busy then return end
            action_busy = true
        else
            if busy then status = "Sync in progress"; dirty = true; return end
            busy = true
        end
        coroutine.spawn(function()
            local ok, failure = pcall(operation)
            if action then action_busy = false else busy = false end
            if not running then return end
            if not ok then status = "Owner query failed: " .. tostring(failure)
            elseif status == "Sync in progress" then status = "" end
            dirty = true
            updates:send(true)
        end)
    end
    -- One dialog at a time: what it asks and what accepting it does.
    local dialog: {request_id: string, kind: string, confirmation: model.Confirmation?, view: model.ApprovalView?, batch: leases.Intent?}? = nil
    local committed_stream = assert(cdc.stream("bee:changes", {tables = {
        "bee_approval_requests", "bee_approval_grants", "bee_approval_window_grants",
        "bee_governance_leases",
    }}))
    local committed = assert(committed_stream:channel())
    local remote = false
    for _, source in pairs(configured.sources) do if not source.local_owner then remote = true end end
    local ticker = remote and assert(time.ticker(POLL)) or nil
    local ticks = ticker and ticker:channel() or nil
    local refresh_pending = false
    local function refresh()
        for _, workspace in ipairs(local_workspaces) do
            local raw = funcs.call("bee.node.binding:read", {workspace_id = workspace})
            workspace_names[workspace] = model.workspace(raw, workspace)
        end
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
        if not state.selected and rows[1] then model.select(state, rows[1].approval_id) end
        state.requester_names = state.requester_names or {}
        local directory = node_client.call(local_node, "list", {})
        local instances = directory and bounds.array(directory.running, 256)
        local app_names: {[string]: string} = {}
        for _, raw in ipairs(instances or {}) do
            local item = bounds.object(raw)
            local id, title = item and bounds.id(item.id), item and bounds.line(item.title, 160)
            if id and title then app_names[id] = title end
        end
        for _, row in ipairs(rows) do
            local instance = row.requester_id:match("^bee%.application:[^:]+:(.+)$")
            if instance and app_names[instance] then state.requester_names[row.requester_id] = app_names[instance] end
            if row.view.requesting_session and not state.requester_names[row.requester_id] then
                local raw = funcs.call("bee.threads.sessions.binding:get", {session = row.view.requesting_session})
                local envelope = bounds.object(raw)
                local body = envelope and envelope.ok == true and bounds.object(envelope.value) or nil
                local snapshot = body and bounds.object(body.value)
                local title = snapshot and bounds.line(snapshot.title, 160)
                local profile = snapshot and bounds.object(snapshot.effective_profile)
                local requester = bounds.line(row.view.proposal.payload.requester_name, 160) or (profile and bounds.line(profile.name, 160))
                if title and title ~= "" then state.requester_names[row.requester_id] = requester and requester ~= title and (requester .. " · " .. title) or title end
            end
        end
        if answer_form then
            local current = state.rows[answer_form.view.approval_id]
            if not current or current.state ~= "pending" then
                status = "Question " .. (current and current.state or "closed")
                answer_form = nil
            end
        end
        if state.grants_view then
            local collected: {grants.Grant} = {}
            do
                local after: string? = nil
                repeat
                    local reply = owner:invoke("bee.approvals.binding:grant", {operation = "list", after_id = after})
                    if not reply then error("grant list outcome unknown") end
                    if reply.kind ~= "success" then error(reply.message) end
                    if type(reply.value) ~= "table" then error("INVALID_REPLY: grant list is not an object") end
                    local body = reply.value
                    if type(body.grants) ~= "table" or type(body.more) ~= "boolean" then error("INVALID_REPLY: grant list is malformed") end
                    for _, raw in ipairs(body.grants) do
                        local grant, grant_error = grants.decode(raw)
                        if not grant then error(grant_error) end
                        collected[#collected + 1] = grant
                    end
                    if body.more then
                        if type(body.next_id) ~= "string" or body.next_id == after then error("INVALID_REPLY: grant cursor did not advance") end
                        after = body.next_id
                    else after = nil end
                until not after
            end
            state.grants = collected
            state.grant_selected = math.floor(math.max(1, math.min(state.grant_selected, #collected)))
        end
        dirty = true
    end
    local function open_selected()
        local intent = model.read_intent(state)
        local selected = model.selected_row(state)
        if not intent or not selected then return end
        model.apply_read(state, selected.approval_id, {kind = "success", value = selected.view})
        offset = 0; shown_review = nil; review_progress = nil; review_end = 0
        rows = model.rows(state)
        dirty = true
    end
    -- An answer that never arrived is recovered from the owner's record.
    local function recover()
        local pending = state.pending
        if pending and pending.kind == "batch" then
            local views: {model.ApprovalView} = {}
            for _, item in ipairs(pending.items) do
                local reply = owner:invoke("bee.approvals.binding:read", {approval_id = item.approval_id})
                if not reply then state.notice = "Batch outcome unknown: owner did not answer"; return end
                if reply.kind ~= "success" then state.notice = reply.message; return end
                local view, err = model.decode_view(reply.value)
                if not view or view.approval_id ~= item.approval_id then state.notice = "INVALID_REPLY: " .. tostring(err or "batch identity differs"); return end
                model.apply_read(state, view.approval_id, reply)
                if view.state == "pending" then state.notice = "Batch outcome unknown: decision may remain in flight"; return end
                views[#views + 1] = view
            end
            model.apply_answer(state, pending.request_id, {kind = "success", value = {decisions = views}})
            rows = model.rows(state); dirty = true
            return
        end
        local intent = model.recovery_intent(state)
        if not intent then return end
        local reply: model.Reply = owner:invoke(intent.target, intent.request) or unknown_answer()
        model.apply_recovery(state, reply)
        rows = model.rows(state)
        dirty = true
    end
    local function act(kind: string, ttl_ms: integer?, gesture: string?)
        local request_id = uuid.v7()
        local intent: model.Intent? = nil
        local refused: string? = nil
        if kind == "withdraw" then intent, refused = model.withdraw_intent(state, request_id)
        else intent, refused = model.combined_intent(state, request_id, kind == "approve" and "approved" or "denied", ttl_ms) end
        if not intent then status = refused or ""; dirty = true; return end
        status = ""
        dirty = true
        if kind ~= "withdraw" and state.detail and state.detail.proposal.ref == "bee.approvals:confirmation" then
            intent.request.assurance = {kind = "explicit_gesture", gesture = gesture or "shortcut", presentation = "inbox"}
        end
        local reply = owner:invoke(intent.target, intent.request)
        model.apply_answer(state, request_id, reply)
        if state.pending then recover() end
        rows = model.rows(state)
        dirty = true
    end
    local function lease_answer(kind: string, intent: leases.Intent?, refused: string?)
        if not intent then status = refused or ""; dirty = true; return end
        local raw = owner:lease(intent.source, intent.request)
        leases.say(slice, raw == nil and "Governance did not answer; refresh to see what committed" or leases.notice(kind, raw))
        refresh()
    end
    local function ask_lease(kind: string)
        if busy then status = "Sync in progress"; dirty = true; return end
        if dialog or state.pending then return end
        local detail = state.detail
        local selected = model.selected_row(state)
        if not detail or not selected or detail.approval_id ~= selected.approval_id then status = "Open a request first"; dirty = true; return end
        if detail.state ~= "pending" or detail.proposal.ref ~= leases.ACTIVATION then status = "Open a pending activation request to lease its application"; dirty = true; return end
        request_form = lease_form.new(detail)
        dirty = true
    end
    local function reviewed(): boolean
        if state.detail and state.detail.state ~= "pending" then status = model.decision_line(state.detail); dirty = true; return false end
        if not shown_review or not model.confirmation_matches(state, shown_review) or state.technical or state.grants_view then
            status = state.detail and "Read every line before deciding · ↓ scroll" or "Open a pending request before deciding"
            dirty = true; return false
        end
        return true
    end
    local function allow_window(ttl_ms: integer)
        if dialog or state.pending or action_busy then return end
        if not reviewed() then return end
        if leases.is_review(state.detail) and not slice.review_complete then status = "Scroll to the end of the lease terms before approving"; dirty = true; return end
        if ttl_ms > model.window_cap(state) then status = "Duration exceeds the approval policy"; dirty = true; return end
        perform(function() act("approve", ttl_ms); state.longer = false end, true)
    end
    local function longer()
        if dialog or state.pending or action_busy then return end
        if not reviewed() then return end
        if not model.confirmation(state) then status = "Open a pending request before choosing a duration"; dirty = true; return end
        if leases.is_review(state.detail) and not slice.review_complete then status = "Scroll to the end of the lease terms before choosing a duration"; dirty = true; return end
        state.longer_choices = {}
        for _, choice in ipairs(windows.choices(model.window_cap(state), clock.milliseconds())) do
            if choice.ttl_ms ~= 1800000 then state.longer_choices[#state.longer_choices + 1] = choice end
        end
        state.longer = true; dirty = true
    end
    local function grant_history()
        local grant = state.grants[state.grant_selected]
        if not grant then return end
        perform(function()
            local who = state.requester_names and state.requester_names[grant.requester_id] or "App or agent"
            local lines = {"Access for " .. who, "State: " .. grant.state}
            if grant.until_ms then lines[#lines + 1] = "Ends " .. clock.stamp(grant.until_ms) end
            if grant.max_uses then lines[#lines + 1] = tostring(grant.used) .. " of " .. tostring(grant.max_uses) .. " uses" end
            if grant.approval_id then
                local source = owner:invoke("bee.approvals.binding:read", {approval_id = grant.approval_id})
                local request = source and source.kind == "success" and model.decode_view(source.value) or nil
                if request then
                    lines[#lines + 1] = model.prompt(request)
                    lines[#lines + 1] = "Lasts: " .. model.duration(request)
                    for _, line in ipairs(model.permission_lines(request)) do lines[#lines + 1] = line end
                end
            end
            lines[#lines + 1] = "History"
            local after = 0
            while true do
                local reply = owner:invoke("bee.approvals.binding:grant",{operation = "history",grant_id = grant.grant_id,after_revision = after})
                if not reply or reply.kind ~= "success" then status = reply and reply.message or "Grant history unavailable"; return end
                local body = bounds.object(reply.value)
                local history = body and bounds.array(body.history,64)
                if not body or not history then error("INVALID_REPLY: grant history is malformed") end
                for _, raw in ipairs(history) do
                    local row = assert(bounds.object(raw))
                    local events: {[string]: string} = {["grant.created"] = "Granted", ["grant.revoked"] = "Access removed", ["grant.migrated"] = "Saved", ["grant.superseded"] = "Replaced"}
                    local actor = tostring(row.actor_id):match("^bee%.application:") and "you" or "Bee"
                    lines[#lines + 1] = model.text(row.at,64) .. " · " .. (events[tostring(row.kind)] or "Updated") .. " by " .. actor
                end
                if body.more ~= true then break end
                local next_revision = bounds.integer(body.next_revision)
                if not next_revision or next_revision <= after then error("INVALID_REPLY: grant history cursor did not advance") end
                after = next_revision
            end
            state.grant_detail = lines
            offset = 0
        end)
    end
    local function revoke_window(gesture: "enter" | "space" | "click" | "shortcut"?)
        if busy or state.pending then return end
        local grant = state.grants[state.grant_selected]
        if not grant then return end
        local confirmed_gesture = gesture or "shortcut"
        perform(function()
            local review = confirmation_ui.new({workspace_id = grant.workspace_id, origin = {app_id = launch.definition_id, instance_id = launch.instance_id, attempt_id = launch.execution_id}})
            local target = {grant_id = grant.grant_id, revision = grant.revision, workspace_id = grant.workspace_id}
            local opened, err = confirmation_ui.open(review, "grant.revoke", target, "inline", "Revoke grant", "Revoke the selected grant")
            if not opened then status = err or "Confirmation is unavailable"; return end
            local accepted, accept_error = confirmation_ui.accept(review, target, confirmed_gesture)
            if not accepted then status = accept_error or "Confirmation failed"; return end
            local reply = owner:invoke("bee.approvals.binding:grant", {operation = "revoke", workspace_id = grant.workspace_id, grant_id = grant.grant_id,expected_revision = grant.revision})
            if not reply then status = "Revocation outcome unknown; refresh to read grants"
            elseif reply.kind ~= "success" then status = reply.message
            else status = "Revoked" end
            refresh()
        end)
    end
    local function ask(kind: string, gesture: string?)
        if dialog or state.pending or action_busy then return end
        if not reviewed() then return end
        local selected = model.selected_row(state)
        local confirmation = model.confirmation(state)
        if not selected or not confirmation then status = "Open a pending request before deciding"; dirty = true; return end
        if kind == "approve" and leases.is_review(state.detail) and not slice.review_complete then
            status = "Scroll to the end of the lease terms before approving"; dirty = true; return
        end
        if kind == "approve" and state.detail and state.detail.request_kind == "question" then
            answer_form = question_form.new(state.detail)
            dirty = true
            return
        end
        if kind == "approve" and state.detail and state.detail.proposal.ref == "bee.threads.sessions:allowance" then
            allowance_request = allowance_form.new(state.detail.source_workspace_id or state.detail.workspace_id, state.detail)
            dirty = true
            return
        end
        if kind == "approve" or kind == "deny" then
            local asked = shown_review
            perform(function()
                if asked and model.confirmation_matches(state, asked) then act(kind, nil, gesture); state.longer = false
                else status = "Request changed. Open it and read it again." end
            end, true)
            return
        end
        local title = "Withdraw this request?"
        local message = model.text(selected.effect .. " on " .. selected.target .. " for " .. selected.requester_id, 512)
        local accept = "Withdraw"
        local request_id, err = client.query(launch, {kind = "confirm", title = title, message = message, accept = accept,
            target = {approval_id = confirmation.approval_id, revision = confirmation.revision, proposal_digest = confirmation.proposal_digest}})
        if not request_id then status = tostring(err); dirty = true; return end
        dialog = {request_id = request_id, kind = kind, confirmation = confirmation}
        dirty = true
    end
    if #launch.arguments == 2 and (launch.arguments[1] == "--approval" or launch.arguments[1] == "--review") then model.select(state, launch.arguments[2]) end
    state.detail = nil
    perform(function()
        refresh()
        if state.selected and not state.rows[state.selected] then model.select(state, nil) end
        if launch.arguments[1] == "--review" then open_selected() end
    end)
    while running do
        if dirty then
            local open_form = request_form
            if answer_form then
                form_frame = question_form.draw(width, height, preferences, answer_form)
                frame.render(form_frame, menu, preferences)
                assert(output:present(form_frame.rows, {cursor = {x = 1, y = 1, visible = false}}))
            elseif allowance_request then
                form_frame = allowance_form.draw(width, height, preferences, allowance_request)
                frame.render(form_frame, menu, preferences)
                assert(output:present(form_frame.rows, {cursor = {x = 1, y = 1, visible = false}}))
            elseif open_form then
                form_frame = lease_form.draw(width, height, preferences, open_form)
                frame.render(form_frame, menu, preferences)
                assert(output:present(form_frame.rows, {cursor = {x = 1, y = 1, visible = false}}))
            else
                local drawn = view.draw(width, height, preferences, state, rows, offset, status, slice, workspace_names)
                frame.render(drawn, menu, preferences)
                hits = drawn.hits
                offset = drawn.offset
                capacity = drawn.capacity
                if state.detail and not shown_review then
                    while true do
                        local queued = channel.select({input:case_receive()}, true)
                        if queued.default or not queued.ok then break end
                        local data = queued.value
                        if data.type == "resize" then width, height = data.width, data.height; dirty = true
                        elseif data.type == "close" then running = false end
                    end
                    drawn = view.draw(width, height, preferences, state, rows, offset, status, slice, workspace_names)
                    frame.render(drawn, menu, preferences); hits = drawn.hits; offset = drawn.offset; capacity = drawn.capacity
                end
                assert(output:present(drawn.rows, {cursor = {x = 1, y = 1, visible = false}}))
                shown_review = nil
                local current = model.confirmation(state)
                if current and not state.technical and not state.grants_view then
                    if not review_progress or not model.confirmation_matches(state, review_progress) then
                        review_progress = current; review_end = 0
                    end
                    if drawn.review_first and drawn.review_last and drawn.review_total then
                        if drawn.review_first <= review_end + 1 then review_end = math.floor(math.max(review_end, drawn.review_last)) end
                        if review_end >= drawn.review_total and drawn.review_last >= drawn.review_total then shown_review = current end
                    elseif leases.is_review(state.detail) and slice.review_complete then shown_review = current end
                else review_progress = nil; review_end = 0 end
            end
            if not announced then client.ready(launch); announced = true end
            local checkpoint = model.checkpoint(state)
            if checkpoint ~= last_checkpoint then
                local sent = client.checkpoint(launch, checkpoint)
                if sent then last_checkpoint = checkpoint end
            end
            dirty = false
        end
        local cases = {input:case_receive(), lifecycle:case_receive(), states:case_receive(), answers:case_receive(),
            navigations:case_receive(), committed:case_receive(), updates:case_receive()}
        if ticks then cases[#cases + 1] = ticks:case_receive() end
        local event = channel.select(cases)
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then running = false end
        elseif event.channel == updates then
            dirty = true
            if refresh_pending and not busy and not action_busy then
                refresh_pending = false
                perform(function() if state.pending then recover() else refresh() end end)
            end
        elseif event.channel == committed then
            refresh_pending = true
            if not busy and not action_busy then
                refresh_pending = false
                perform(function() if state.pending then recover() else refresh() end end)
            end
        elseif ticks and event.channel == ticks then
            if not busy then
                if state.pending then perform(recover) else perform(refresh) end
            end
        elseif event.channel == states then
            local message = event.value
            if broker and message:from() == broker then
                local payload: unknown = message:payload():data()
                local next_preferences = type(payload) == "table" and appearance.decode(payload.appearance) or nil
                if next_preferences then preferences = next_preferences; dirty = true end
            end
        elseif event.channel == navigations then
            local args = client.navigation(launch, tostring(event.value:from()), event.value:payload():data())
            if args and #args == 2 and (args[1] == "--approval" or args[1] == "--review") then
                if state.selected ~= args[2] then
                    model.select(state, args[2]); state.detail = nil; shown_review = nil; review_progress = nil; review_end = 0; offset = 0
                end
                state.grants_view = false; dirty = true
                perform(function()
                    refresh()
                    if not state.rows[args[2]] then status = "Request is unavailable"
                    elseif args[1] == "--review" then open_selected() end
                end)
            end
        elseif event.channel == answers then
            local message = event.value
            local result = client.query_result(launch, tostring(message:from()), message:payload():data())
            if result and dialog and result.request_id == dialog.request_id then
                local asked = dialog
                dialog = nil
                if result.error ~= "" then status = result.error == "busy" and "Another question is open" or "Confirmation owner is unavailable"; dirty = true
                elseif result.action ~= "accept" then status = "Cancelled"; dirty = true
                elseif asked.kind == "revoke" then
                    revoke_window()
                elseif not asked.confirmation or not model.confirmation_matches(state, asked.confirmation) then
                    status = "Request changed; open it and confirm again"; dirty = true
                else perform(function()
                    if model.confirmation_matches(state, asked.confirmation) then act(asked.kind)
                    else status = "Request changed; open it and confirm again"; dirty = true end
                end) end
            end
        else
            local data, handled = frame.route(menu, event.value, request_form ~= nil or answer_form ~= nil)
            if handled then dirty = true end
            if data then
                if data.type == "close" then running = false
                elseif data.type == "resize" then width, height = data.width, data.height; dirty = true
                elseif answer_form and (data.type == "key" or data.type == "mouse" or data.type == "paste") then
                    local opened = answer_form
                    local outcome = question_form.input(opened, data, form_frame)
                    if outcome == "cancel" then answer_form = nil
                    elseif outcome == "submit" then
                        local response, problem = question_form.answer(opened)
                        if problem then opened.status = problem
                        elseif busy or state.pending then opened.status = "Sync in progress"
                        elseif not state.detail or state.detail.approval_id ~= opened.view.approval_id or state.detail.revision ~= opened.view.revision then
                            opened.status = "The question changed; reopen it"
                        else
                            local request_id = uuid.v7()
                            local intent, refused = model.decision_intent(state, request_id, "approved", nil, response)
                            if not intent then opened.status = refused or "Cannot answer this question"
                            else
                                perform(function()
                                    model.apply_answer(state, request_id, owner:invoke(intent.target, intent.request))
                                    if state.pending then recover() end
                                    answer_form = nil
                                    rows = model.rows(state)
                                end)
                            end
                        end
                    end
                    dirty = true
                elseif allowance_request and (data.type == "key" or data.type == "mouse") then
                    local opened_form = allowance_request
                    local outcome = allowance_form.input(opened_form, data, form_frame)
                    if outcome == "cancel" then allowance_request = nil
                    elseif outcome == "submit" then
                        local intent, err = allowance_form.intent(opened_form)
                        if intent then
                            perform(function()
                                local reply = owner:invoke(intent.target, intent.request)
                                if reply and reply.kind == "success" then allowance_request = nil; refresh()
                                else opened_form.status = reply and reply.message or "Decision outcome unknown; refresh" end
                            end)
                        else opened_form.status = err or "Invalid allowance" end
                    end
                    dirty = true
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
                elseif data.type == "key" and data.action == "press" then
                    local key = data.key_type
                    local text = (data.ctrl or data.alt) and "" or tostring(data.key or ""):lower()
                    status = ""
                    leases.say(slice, "")
                    if state.grants_view then
                        if state.grant_detail then
                            if key == "up" or text == "k" then offset = math.floor(math.max(0,offset - 1)); dirty = true
                            elseif key == "down" or text == "j" then offset = math.floor(math.min((state.grant_line_count or #state.grant_detail) - 1,offset + 1)); dirty = true
                            elseif text == "x" then revoke_window(); state.grant_detail = nil
                            elseif key == "esc" or key == "escape" or text == "u" then state.grant_detail = nil; offset = 0; dirty = true end
                        elseif key == "up" or text == "k" then state.grant_selected = math.floor(math.max(1, state.grant_selected - 1)); dirty = true
                        elseif key == "down" or text == "j" then state.grant_selected = math.floor(math.max(1, math.min(#state.grants, state.grant_selected + 1))); dirty = true
                        elseif text == "h" or key == "enter" then grant_history()
                        elseif text == "x" then revoke_window()
                        elseif text == "r" then perform(refresh)
                        elseif text == "u" or key == "esc" or key == "escape" then state.grants_view = false; dirty = true end
                    elseif state.longer and tonumber(text) then
                        local choice = state.longer_choices[math.floor(tonumber(text))]
                        if choice then allow_window(choice.ttl_ms) end
                    elseif text == "u" then
                        state.grants_view = true; perform(refresh); dirty = true
                    elseif text == "f" then allow_window(1800000)
                    elseif text == "l" and model.window_cap(state) > 0 then longer()
                    elseif text == "v" then
                        state.grants_view = true; perform(refresh); offset = 0
                        perform(refresh); dirty = true
                    elseif leases.is_review(state.detail) and not state.technical and state.selected ~= nil and (key == "up" or key == "down" or key == "pgup" or key == "pgdown" or text == "j" or text == "k") then
                        leases.review_scroll(slice, (key == "up" or text == "k") and -1 or (key == "pgup" and -8 or (key == "pgdown" and 8 or 1)))
                        dirty = true
                    elseif state.detail and (key == "up" or key == "down" or key == "pgup" or key == "pgdown" or text == "j" or text == "k") then
                        offset = math.floor(math.max(0, offset + ((key == "up" or text == "k") and -1 or (key == "pgup" and -math.max(1, capacity) or (key == "pgdown" and math.max(1, capacity) or 1)))))
                        dirty = true
                    elseif key == "up" or text == "k" then model.move(state, -1); dirty = true
                    elseif key == "down" or text == "j" then model.move(state, 1); dirty = true
                    elseif key == "pgup" then model.move(state, -math.floor(math.max(1, capacity))); dirty = true
                    elseif key == "pgdown" then model.move(state, math.floor(math.max(1, capacity))); dirty = true
                    elseif text == "l" or text == "e" then ask_lease("lease_propose")
                    elseif text == "s" or text == "b" then
                        local detail = state.detail
                        if detail and detail.requesting_session then
                            local _, err = client.navigate(launch, "bee.harness.app:app", {"--session", detail.requesting_session})
                            status = err or "Opening the requesting session"
                        else status = "This request has no source session" end
                        dirty = true
                    elseif key == "enter" or text == "o" then open_selected()
                    elseif text == "t" and state.detail then model.toggle_technical(state); offset = 0; shown_review = nil; dirty = true
                    elseif text == "a" then ask("approve")
                    elseif text == "d" then ask("deny")
                    elseif text == "w" then ask("withdraw")
                    elseif text == "r" then perform(function() if state.pending then recover() else refresh() end end)
                    elseif key == "esc" or key == "escape" then
                        if state.longer then state.longer = false; dirty = true
                        elseif state.technical then state.technical = false; offset = 0; dirty = true
                        elseif state.detail then state.detail = nil; offset = 0; shown_review = nil; dirty = true else running = false end
                    end
                elseif data.type == "mouse" and data.action == "press" and data.button == "left" then
                    local hit = frame.hit(hits, math.floor(tonumber(data.x) or 1), math.floor(tonumber(data.y) or 1))
                    if hit then
                        status = ""
                        if hit.kind == "window_row" then state.grant_selected = hit.index; dirty = true
                        elseif hit.kind == "window_revoke" then revoke_window("click")
                        elseif hit.kind == "windows" then state.grants_view = true; perform(refresh)
                        elseif hit.kind == "grant_history" then grant_history()
                        elseif hit.kind == "window_back" then state.grants_view = false; dirty = true
                        elseif hit.kind == "allow_30" then allow_window(1800000)
                        elseif hit.kind == "allow_longer" then longer()
                        elseif hit.kind == "window_choice" then
                            local choice = state.longer_choices[hit.index]
                            if choice then allow_window(choice.ttl_ms) end
                        elseif hit.kind == "revoke" then revoke_window("click")
                        elseif hit.kind == "requests" then state.grants_view = false; offset = 0; perform(refresh); dirty = true
                        elseif hit.kind == "leases" then state.grants_view = true; offset = 0; perform(refresh); dirty = true
                        elseif hit.kind == "lease" then ask_lease("lease_propose")
                        elseif hit.kind == "technical" then model.toggle_technical(state); offset = 0; shown_review = nil; dirty = true
                        elseif hit.kind == "row" then
                            local row = rows[hit.index]
                            if row then model.select(state, row.approval_id); dirty = true end
                        elseif hit.kind == "source" then
                            local detail = state.detail
                            if detail and detail.requesting_session then
                                local _, err = client.navigate(launch, "bee.harness.app:app", {"--session", detail.requesting_session})
                                status = err or "Opening requesting session"; dirty = true
                            end
                        elseif hit.kind == "back" then
                            if state.technical then state.technical = false else state.detail = nil end; offset = 0; shown_review = nil; dirty = true
                        elseif hit.kind == "open" then open_selected()
                        elseif hit.kind == "approve" or hit.kind == "deny" or hit.kind == "withdraw" then ask(hit.kind, "click")
                        elseif hit.kind == "refresh" then perform(function() if state.pending then recover() else refresh() end end)
                        end
                    end
                elseif data.type == "mouse" and data.action == "wheel" then
                    local step = (data.button == "wheel_up" or data.button == "up") and -1 or 1
                    if leases.is_review(state.detail) then leases.review_scroll(slice, step)
                    elseif state.detail then offset = math.floor(math.max(0, offset + step)) else model.move(state, step) end
                    dirty = true
                end
            end
        end
    end
    if ticker then ticker:stop() end
    committed_stream:close()
    process.unlisten(states)
    process.unlisten(answers); process.unlisten(navigations)
    output:close()
    tty.stop()
end
return {main = main}
