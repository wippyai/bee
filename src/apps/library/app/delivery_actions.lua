-- MIT. Library delivery review, installation and recovery actions.
local uuid = require("uuid")
local funcs = require("funcs")
local confirmation = require("confirmation")
local model = require("model")
local governed = require("governed")
local hub = require("hub")
local M = {}
local function new_key(): string
    local value, err = uuid.v4()
    if err or not value then error("allocate delivery idempotency key") end
    return value
end

type Object = {[string]: unknown}
type Gesture = "enter" | "space" | "click" | "shortcut"
type Callbacks = {running: () -> boolean, gesture: () -> Gesture}
function M.new(state: model.State, review: confirmation.State, wake: () -> (), callbacks: Callbacks)
    local gov, hubs = state.governed, state.hub
    local function invoke(request: unknown): governed.Reply?
        local raw, err = funcs.new():call(governed.CALL, request)
        if err then return governed.reply({ok = false, value = nil, error = {code = "UNAVAILABLE", message = tostring(err)}}) end
        return governed.reply(raw)
    end

    -- Governed reads and the install chain.
    local function refresh_activations()
        if governed.apply_activations(gov, invoke(governed.activations_request(gov))) then
            local latest = gov.intent or gov.activations[1]
            if latest then state.notice = governed.phase_notice(latest) end
        end
    end
    -- The bees that made versions are named once each; one that does not
    -- answer is asked again only when the person refreshes.
    local asked: {[string]: boolean} = {}
    local function refresh_names()
        local wanted: {string} = {}
        for _, node in ipairs(model.sources(state)) do
            if not asked[node] and gov.names[node] == nil then wanted[#wanted + 1] = node; asked[node] = true end
        end
        if #wanted == 0 then return end
        local raw, err = funcs.new():call(governed.NAMES, governed.names_request(wanted))
        if not err then governed.apply_names(gov, governed.reply(raw)) end
    end
    local function refresh_governed()
        local failures: {string} = {}
        local function note()
            if gov.notice ~= "" then failures[#failures + 1] = gov.notice end
        end
        governed.apply_available(gov, invoke(governed.available_request(gov))); note()
        governed.apply_list(gov, invoke(governed.list_request(gov))); note()
        governed.apply_activations(gov, invoke(governed.activations_request(gov))); note()
        refresh_names()
        state.notice = failures[1] or ""
    end
    -- remove_now takes an application off this bee, or back to the version
    -- before it, as the person. One attempt keeps its receipt key until the
    -- answer is known.
    local pending_revert: {app: string, key: string}? = nil
    local function remove_now(removal: model.Removal)
        local attempt = pending_revert
        if not attempt or attempt.app ~= removal.app then
            attempt = {app = removal.app, key = new_key()}
            pending_revert = attempt
        end
        local request = removal.kind == "back" and governed.revert_request(gov, removal.app, attempt.key, removal.intent_id)
            or governed.uninstall_request(gov, removal.app, attempt.key, removal.intent_id)
        local answer = invoke(request)
        if not answer then state.notice = "No answer yet; try Refresh"; return end
        pending_revert = nil
        if answer.ok then
            refresh_governed()
            state.notice = removal.kind == "back" and (removal.name .. " went back to " .. tostring(removal.baseline))
                or (removal.name .. " was removed")
            return
        end
        local fault = answer.error
        gov.fault = fault and (fault.code .. ": " .. fault.message) or "revert failed"
        if fault and fault.code == "BLOCKED" then
            state.notice = "Removing " .. removal.name .. " stopped; Technical says why"
        else
            state.notice = "That did not go through; Technical says why"
        end
    end
    -- share_now publishes the installed version of an application made on
    -- this bee to its hive, as the person.
    local function share_now(row: model.Row)
        if not model.can_share(row) or not row.app then state.notice = "Only an application made on this bee can be shared from here"; return end
        local raw, err = funcs.new():call(governed.SHARE, governed.share_request(gov, row.app, row.version))
        local answer = not err and governed.reply(raw) or nil
        if not answer then state.notice = "No answer yet; try again"; gov.fault = tostring(err or "no reply"); return end
        if answer.ok then
            state.notice = row.name .. " " .. row.version .. " is shared with your hive"
            return
        end
        local fault = answer.error
        gov.fault = fault and (fault.code .. ": " .. fault.message) or "share failed"
        state.notice = "Sharing " .. row.name .. " did not go through; Technical says why"
    end
    local function stage_now(item: governed.Available): boolean
        local staged = governed.staged_plan(gov, item)
        if staged then governed.select(gov, governed.key(staged)); return true end
        local pending_stage = gov.pending_stage
        local selected_key = governed.available_key(item)
        if pending_stage and pending_stage.available_key ~= selected_key then
            state.notice = "An earlier install did not finish; choose that version and try again"
            return false
        end
        if not pending_stage then
            pending_stage = {available_key = selected_key, idempotency_key = new_key()}
            gov.pending_stage = pending_stage
        end
        local answer = invoke(governed.stage_request(gov, item, pending_stage.idempotency_key))
        local applied = governed.apply_stage(gov, answer, item)
        if answer and (applied or not answer.ok) then gov.pending_stage = nil end
        if not applied then state.notice = gov.notice end
        return applied
    end
    local function read_selected_now(): boolean
        local item = governed.selected(gov)
        if not item then state.notice = "Choose a version first"; return false end
        if not governed.apply_plan(gov, invoke(governed.get_request(gov, item))) then state.notice = gov.notice; return false end
        governed.apply_changes(gov, invoke(governed.changes_request(gov, item)), item)
        return true
    end
    local function refuse(item: governed.Plan?): boolean
        local person, technical = governed.refusal(gov, item)
        if not person then return false end
        state.notice = person
        gov.fault = technical or person
        return true
    end
    local function review_transition(accepted: boolean): boolean
        local item = governed.selected(gov)
        if accepted and refuse(item) then return false end
        if not governed.accepts_review(item) or not item then
            state.notice = "This version has already been reviewed"; return false
        end
        local target = {plan_digest = item.plan_digest, revision = item.revision, artifact_digest = item.artifact_digest,
            preflight_digest = item.preflight_digest, source_workspace = item.source_workspace, source_node = item.source_node, version = item.version}
        local opened, err = confirmation.open(review, "library.review", target, "inline", "Review " .. item.version, "Review the displayed preflight and changes")
        if not opened then state.notice = err or "Confirmation is unavailable"; return false end
        local confirmed, confirm_error = confirmation.accept(review, target, callbacks.gesture(), accepted and "allow_once" or "deny")
        if not confirmed then state.notice = confirm_error or "Confirmation failed"; return false end
        local applied = governed.apply_plan(gov, invoke(governed.review_request(gov, item, accepted, new_key())))
        if not applied then state.notice = gov.notice end
        return applied
    end
    local function select_transition(): boolean
        local item = governed.selected(gov)
        if refuse(item) then return false end
        if not governed.can_select(item) or not item then
            state.notice = "Review this version before choosing it"; return false
        end
        local applied = governed.apply_plan(gov, invoke(governed.select_request(gov, item, new_key())))
        if not applied then state.notice = gov.notice end
        return applied
    end
    local function prepare_transition(follow_source: boolean?): boolean
        local item = governed.selected(gov)
        if refuse(item) then return false end
        if not governed.can_prepare(gov, item) or not item then
            state.notice = "Choose a reviewed version before asking for approval"; return false
        end
        local pending_prepare = gov.pending_prepare
        if pending_prepare and pending_prepare.plan_key ~= governed.key(item) then
            state.notice = "An earlier install did not finish; choose that version and try again"; return false
        end
        if not pending_prepare then
            pending_prepare = {plan_key = governed.key(item), intent_id = new_key(), receipt_key = new_key()}
            governed.set_pending_prepare(gov, item, pending_prepare.intent_id, pending_prepare.receipt_key)
        end
        wake()
        local answer = invoke(governed.prepare_request(gov, item, pending_prepare.intent_id, pending_prepare.receipt_key, follow_source))
        local applied = governed.apply_activation(gov, answer)
        if answer and (applied or not answer.ok) then gov.pending_prepare = nil end
        state.notice = gov.notice
        return applied
    end
    local function install_selected_now(follow_source: boolean?): boolean
        if not read_selected_now() then return false end
        local selected = governed.selected(gov)
        if governed.accepts_review(selected) and not review_transition(true) then return false end
        selected = governed.selected(gov)
        if selected and governed.can_select(selected) and not selected.selected and not select_transition() then return false end
        selected = governed.selected(gov)
        if selected and governed.can_prepare(gov, selected) then
            if prepare_transition(follow_source) then
                refresh_activations()
                state.notice = gov.notice
                return gov.notice == ""
            end
        else
            state.notice = state.notice ~= "" and state.notice or "This version can't be installed here right now"
        end
        return false
    end
    -- Install runs the whole local path: receive the version, read its checks,
    -- review it, choose it and ask for approval, which waits in Needs you.
    local function install_now(row: model.Row, follow_source: boolean?)
        local item: governed.Available? = nil
        for _, candidate in ipairs(gov.available) do
            if governed.available_key(candidate) == row.available_key then item = candidate end
        end
        if not item then state.notice = "That version is no longer shared; try Refresh"; return end
        governed.select_available(gov, governed.available_key(item))
        if not stage_now(item) then return end
        refresh_governed()
        local plan = governed.staged_plan(gov, item)
        if plan then governed.select(gov, governed.key(plan)) end
        install_selected_now(follow_source)
    end

    local function review_hub_now(request: Object)
        if not governed.apply_plan(gov, invoke(request)) then hubs.notice = gov.notice; return end
        local selected_key = governed.key(assert(gov.detail))
        if not governed.apply_list(gov, invoke(governed.list_request(gov))) then hubs.notice = gov.notice; return end
        governed.select(gov, selected_key)
        if not read_selected_now() then hubs.notice = state.notice; return end
        if gov.changes_error then hubs.notice, gov.fault = "Entry changes could not be read; Technical says why", gov.changes_error; return end
        hubs.notice = "Review these changes; Enter asks for approval in Needs you"
    end
    local function confirm_hub_now()
        if install_selected_now() then
            local intent = assert(gov.intent)
            hub.show(hubs, "catalog")
            model.show_tab(state, "installed")
            model.select(state, "g:act:" .. intent.intent_id)
            hubs.notice = ""
            state.notice = "Approval waits in Needs you"
        else hubs.notice = state.notice end
    end
    local function step_now()
        local intent_id = gov.intent and gov.intent.intent_id or gov.restored_intent_id
        if not intent_id then state.notice = "Use Recover to find the install first"; return end
        if not gov.intent and not governed.apply_activation(gov, invoke(governed.status_request(gov, intent_id))) then
            state.notice = gov.notice; return
        end
        -- Each next request follows an acknowledged owner transition. Unknown
        -- answers retain their exact receipt key and stop this person action.
        while callbacks.running() and governed.can_advance(gov) do
            local before = assert(gov.intent)
            local pending_step = gov.pending_step
            if pending_step and pending_step.intent_id ~= intent_id then
                state.notice = "An earlier step did not finish; check its status first"; return
            end
            if not pending_step then
                pending_step = {intent_id = intent_id, receipt_key = new_key()}
                governed.set_pending_step(gov, intent_id, pending_step.receipt_key)
            end
            wake()
            local answer = invoke(governed.step_request(gov, pending_step.intent_id, pending_step.receipt_key))
            local applied = governed.apply_activation(gov, answer)
            if answer and (applied or not answer.ok) then gov.pending_step = nil end
            state.notice = gov.notice
            if not applied then return end
            local observed = assert(gov.intent)
            gov.restored_intent_id = observed.intent_id
            if observed.phase == before.phase and observed.revision == before.revision then
                state.notice = "Nothing moved; check the status before continuing"; return
            end
        end
    end
    local function status_now()
        local intent_id = gov.intent and gov.intent.intent_id or gov.restored_intent_id
        if not intent_id then state.notice = "Nothing is known yet; use Recover to look it up"; return end
        local applied = governed.apply_activation(gov, invoke(governed.status_request(gov, intent_id)))
        if applied then gov.restored_intent_id = gov.intent and gov.intent.intent_id or nil end
        state.notice = gov.notice
    end
    local function recover_now()
        local item = governed.selected(gov)
        if not item then state.notice = "Choose the version whose install to look up"; return end
        local key = gov.pending_recover_key or new_key()
        governed.set_pending_recover(gov, key)
        local answer = invoke(governed.recover_request(gov, item, key))
        local applied = governed.apply_activation(gov, answer)
        if answer and (applied or not answer.ok) then gov.pending_recover_key = nil end
        if applied then gov.restored_intent_id = gov.intent and gov.intent.intent_id or nil end
        state.notice = gov.notice
    end
    -- open_version selects the plan a governed row stands for and reads it.
    local function open_version_now(row: model.Row)
        local plan: governed.Plan? = nil
        if row.available_key then
            for _, candidate in ipairs(gov.available) do
                if governed.available_key(candidate) == row.available_key then plan = governed.staged_plan(gov, candidate) end
            end
        elseif row.app then
            for _, candidate in ipairs(gov.plans) do
                if candidate.source_workspace == row.app and candidate.version == row.version then plan = candidate end
            end
        end
        if plan then
            governed.select(gov, governed.key(plan))
            read_selected_now()
        else
            governed.select(gov, nil)
            governed.forget_review(gov)
        end
    end

    return {invoke = invoke, refresh_activations = refresh_activations, refresh_governed = refresh_governed, remove_now = remove_now, share_now = share_now, review_transition = review_transition, select_transition = select_transition, prepare_transition = prepare_transition, install_now = install_now, review_hub_now = review_hub_now, confirm_hub_now = confirm_hub_now, step_now = step_now, status_now = status_now, recover_now = recover_now, open_version_now = open_version_now}
end
M.new_key = new_key
return M
