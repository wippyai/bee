-- MIT. Modules is a responsive, permissioned Hub client. It only invokes the
-- public facade; package credentials, registry writes and execution authority
-- remain inside bee.hub.
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local uuid = require("uuid")
local funcs = require("funcs")
local client = require("client")
local appearance = require("appearance")
local frame = require("frame")
local model = require("model")
local view = require("view")
local contents = require("contents")

type Object = {[string]: unknown}
type Reply = {ok: boolean, code: string?, message: string?, value: unknown, replayed: boolean}
type Pending = {future: funcs.Future, response: channel.Channel, operation: string, generation: integer, apply: boolean}
type ReadPending = {future: funcs.Future, response: channel.Channel, operation: string, generation: integer, retired: boolean}
type RequestedRead = {intent: model.Intent, generation: integer}
type Editor = {field: string, buffer: string, name: string?}

local function reply(value: unknown): Reply
    if type(value) == "table" and type(value.ok) == "boolean" and type(value.replayed) == "boolean" then
        local raw = value :: Object
        local receipt = type(raw.value) == "table" and raw.value :: Object or nil
        local state = receipt and type(receipt.state) == "string" and receipt.state or ""
        local failed = state == "failed" or state == "recovery_required"
        return {ok = raw.ok == true and not failed, replayed = raw.replayed == true,
            code = failed and (type(raw.code) == "string" and raw.code ~= "OK" and raw.code or state:upper()) or (type(raw.code) == "string" and raw.code or nil),
            message = type(raw.message) == "string" and raw.message or nil, value = raw.value}
    end
    return {ok = false, replayed = false, code = "UNCERTAIN", message = "Hub reply was unavailable", value = nil}
end

local function completed(pending: Pending): Reply
    local result, err = pending.future:result()
    if err or not result then return {ok = false, replayed = false, code = "UNCERTAIN", message = tostring(err or "Hub call ended without a reply"), value = nil} end
    return reply(result:data())
end

local function editable(value: string): string
    return value:sub(1, 8192)
end

local function previous(value: string): string
    local start = #value
    while start > 1 do
        local byte = value:byte(start)
        if byte < 0x80 or byte >= 0xC0 then break end
        start = start - 1
    end
    return value:sub(1, math.floor(math.max(0, start - 1)))
end

local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
    local broker = launch.broker_pid
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local states = assert(process.listen("bee.appearance.state", {message = true}))
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local preferences = appearance.defaults()
    local state: model.State = model.new()
    local content = contents.new()
    local offset = 0
    local reading_readme = false
    local visible_rows = 1
    local hits: {frame.Hit} = {}
    local pending: {Pending} = {}
    local reading: ReadPending? = nil
    local requested: RequestedRead? = nil
    local generation = 0
    local apply_pending = false
    local publication_pending = false
    local editor: Editor? = nil
    local status = ""
    local announced, running, dirty = false, true, true

    local function changed()
        dirty = true
    end

    local function invalidate()
        generation = generation + 1
    end

    local function read_operation(intent: model.Intent): string
        return intent.operation == "status" and intent.expected_digest == nil and "history" or intent.operation
    end
    local function fold_read(operation: string, value: Reply)
        if operation == "state" or operation == "files" or operation == "read_file" then contents.apply(content, operation, value)
        elseif operation == "catalog" then model.apply_catalog(state, value)
        elseif operation == "installed" then
            status = ""
            model.apply_installed(state, value)
            if state.action == "update" and state.installed_read == "ready" then state.notice = "Installed settings loaded" end
        elseif operation == "details" then model.apply_details(state, value)
        elseif operation == "inspect" then model.apply_inspect(state, value)
        elseif operation == "plan" then model.apply_plan(state, value)
        elseif operation == "status" then model.apply_result(state, value)
        elseif operation == "history" then model.apply_history(state, value) end
    end

    local function start_read()
        if reading or not requested then return end
        local next = requested
        requested = nil
        local future, err = funcs.new():async(model.HUB, next.intent)
        if not future or err then
            if next.generation == generation then fold_read(read_operation(next.intent), {ok = false, replayed = false, code = "UNCERTAIN", message = tostring(err or "Hub dispatch unavailable"), value = nil}) end
            start_read()
            changed()
            return
        end
        local response = future:response()
        if not response then
            future:cancel()
            if next.generation == generation then fold_read(read_operation(next.intent), {ok = false, replayed = false, code = "UNAVAILABLE", message = "Hub response channel unavailable", value = nil}) end
            start_read()
            changed()
            return
        end
        reading = {future = future, response = response, operation = read_operation(next.intent), generation = next.generation, retired = false}
    end

    local function begin(intent: model.Intent): boolean
        if intent.operation ~= "apply" then
            generation = generation + 1
            requested = {intent = intent, generation = generation}
            if reading then
                -- Keep the stale read alive until its response is consumed. A
                -- future cancellation is delivered as this app's lifecycle
                -- cancellation, which would terminate the UI before a queued
                -- retry can start. The generation fence below still prevents
                -- the stale response from changing model state.
                if not reading.retired then reading.retired = true end
            else start_read() end
            return true
        end
        local future, err = funcs.new():async(model.HUB, intent)
        if not future or err then
            local failed: Reply = {ok = false, replayed = false, code = "UNCERTAIN", message = tostring(err or "Hub dispatch unavailable"), value = nil}
            if intent.operation == "apply" then model.apply_result(state, failed); apply_pending = false
            else state.notice = (failed.code or "UNAVAILABLE") .. ": " .. (failed.message or "Hub unavailable") end
            changed()
            return false
        end
        local response = future:response()
        if not response then
            future:cancel()
            model.apply_result(state, {ok = false, replayed = false, code = "UNCERTAIN", message = "Hub response channel unavailable", value = nil})
            apply_pending = false
            changed()
            return false
        end
        pending[#pending + 1] = {future = future, response = response, operation = intent.operation, generation = 0, apply = true}
        return true
    end

    local function catalog()
        model.show(state, "catalog")
        begin(model.catalog_intent(state))
        changed()
    end

    local function installed()
        model.show(state, "installed")
        begin(model.installed_intent(state))
        changed()
    end

    local function details()
        content.open = false
        local intent = model.details_intent(state)
        if not intent then status = "Select a package first"; changed(); return end
        model.show(state, "details")
        reading_readme = true
        model.show_requirements(state, false)
        begin(intent)
        changed()
    end

    local function requirements()
        content.open = false
        model.show_requirements(state, true)
        reading_readme, offset = false, 0
        local intent = model.inspect_intent(state)
        if intent then begin(intent)
        elseif state.action == "update" then status = "Read installed settings before inspecting this update"
        else status = "Choose a version first" end
        changed()
    end

    local function plan()
        local intent, problem = model.plan_intent(state)
        if not intent then status = problem or "Cannot prepare a plan"; changed(); return end
        model.show(state, "plan")
        offset = 0
        begin(intent)
        changed()
    end

    local function operation_history()
        invalidate()
        model.show(state, "operations")
        offset = 0
        begin(model.operation_history_intent(state))
        changed()
    end

    local function check_status()
        local intent = model.status_intent(state)
        if not intent then status = "No measured operation to check"; changed(); return end
        begin(intent)
        changed()
    end

    -- Reaching confirm only changes presentation state. Dispatching apply is
    -- a separate, explicit event and is never retried by this client.
    local function confirm()
        if apply_pending then status = "Apply is still pending; check status if the result is uncertain"; changed(); return end
        local intent, problem = model.confirm_intent(state)
        if not intent then status = problem or "Plan cannot be applied"; changed(); return end
        apply_pending = true
        status = "Applying measured plan…"
        begin(intent)
        changed()
    end

    local function publication_call(operation: "prepare" | "publish")
        if publication_pending then status = "Publication is still pending"; changed(); return end
        local intent: model.Intent? = nil
        local problem: string? = nil
        if operation == "prepare" then intent, problem = model.publication_prepare_intent(state, launch.workspace_id)
        else intent, problem = model.publication_publish_intent(state, launch.workspace_id) end
        if not intent or not intent.request then status = problem or "Authored version is not ready"; changed(); return end
        local future, err = funcs.new():async(model.PUBLICATION, intent.request)
        if not future or err then
            local failure: Reply = {ok = false, replayed = false, code = "UNCERTAIN",
                message = tostring(err or "publication dispatch unavailable"), value = nil}
            if operation == "prepare" then model.apply_publication_prepare(state, failure)
            else model.apply_publication_publish(state, failure) end
            changed()
            return
        end
        local response = future:response()
        if not response then
            future:cancel()
            local failure: Reply = {ok = false, replayed = false, code = "UNCERTAIN",
                message = "publication response channel unavailable", value = nil}
            if operation == "prepare" then model.apply_publication_prepare(state, failure)
            else model.apply_publication_publish(state, failure) end
            changed()
            return
        end
        publication_pending = true
        status = operation == "prepare" and "Preparing frozen authored version locally…"
            or "Publishing the locally applied authored version…"
        pending[#pending + 1] = {future = future, response = response, operation = "publication_" .. operation,
            generation = 0, apply = false}
        changed()
    end

    local function prepare_publication() publication_call("prepare") end
    local function publish_publication() publication_call("publish") end

    local function choose(name: string, show_details: boolean)
        local previous_phase = state.phase
        model.select(state, name)
        if not show_details then model.show(state, previous_phase) end
        offset = 0
        reading_readme = false
        invalidate()
        if show_details then details() else changed() end
    end

    local function choose_relative(delta: integer)
        local rows: {unknown} = state.phase == "catalog" and (state.catalog :: {unknown}) or (state.installed :: {unknown})
        if #rows == 0 then return end
        local current = 0
        for index, raw in ipairs(rows) do
            if type(raw) == "table" and (raw :: Object).component == state.selected then current = index; break end
        end
        local next = math.floor(math.max(1, math.min(#rows, current + delta)))
        local raw = rows[next]
        if type(raw) == "table" and type((raw :: Object).component) == "string" then
            local old_offset = offset
            choose((raw :: Object).component :: string, false)
            offset = math.floor(math.max(0, math.min(old_offset, next - 1)))
            if next > offset + visible_rows then offset = math.floor(math.max(0, next - visible_rows)) end
        end
    end

    local function operation_relative(delta: integer)
        if #state.operations == 0 then return end
        local current = 0
        for index, item in ipairs(state.operations) do
            if state.selected_operation and item.digest == state.selected_operation.digest then current = index; break end
        end
        local next = math.floor(math.max(1, math.min(#state.operations, current + delta)))
        model.select_operation(state, state.operations[next].digest)
        if next <= offset then offset = next - 1 end
        if next > offset + visible_rows then offset = math.floor(math.max(0, next - visible_rows)) end
        invalidate()
        changed()
    end

    local function cancel_confirmation()
        if state.recovery then operation_history()
        else model.show(state, "plan"); changed() end
    end

    local function version_relative(delta: integer)
        local detail = state.detail
        if not detail or #detail.versions == 0 then return end
        local current = 0
        for index, item in ipairs(detail.versions) do if item.version == state.selected_version then current = index; break end end
        local next = math.floor(math.max(1, math.min(#detail.versions, current + delta)))
        if next <= offset then offset = next - 1 end
        if next > offset + visible_rows then offset = math.floor(math.max(0, next - visible_rows)) end
        model.select_version(state, detail.versions[next].version)
        invalidate()
        changed()
    end

    local function finish_editor()
        local active = editor
        if not active then return end
        if active.field == "query" then
            model.set_query(state, active.buffer)
            invalidate()
            catalog()
        elseif active.field == "keyword" then
            model.set_keyword(state, active.buffer)
            invalidate()
            catalog()
        elseif active.field == "publication_component" or active.field == "publication_version"
            or active.field == "publication_snapshot_digest" then
            local field = active.field == "publication_component" and "component"
                or active.field == "publication_version" and "version" or "snapshot_digest"
            local problem = model.set_publication_field(state, field, active.buffer)
            if problem then status = problem; changed(); return end
            editor = nil
            status = "Authored version details saved"
            changed()
        elseif active.field == "parameter_name" then
            if active.buffer == "" then status = "Parameter name is required"; changed(); return end
            editor = {field = "parameter_value", buffer = "", name = active.buffer}
            status = "Parameter JSON value: "
            changed()
            return
        else
            local problem = model.set_parameter(state, active.name or "", active.buffer)
            if problem then status = problem; changed(); return end
            status = "Parameter saved"; invalidate(); if state.requirements_open then requirements() end
            changed()
        end
        editor = nil
    end

    local function begin_editor(field: string)
        if publication_pending and field:find("^publication_") then
            status = "Wait for the current Governance request to finish before editing this version"
            changed()
            return
        end
        if field == "query" then editor = {field = field, buffer = state.query}; status = "Search: " .. state.query
        elseif field == "keyword" then editor = {field = field, buffer = state.keyword}; status = "Keyword (empty is all): " .. state.keyword
        elseif field == "publication_component" then editor = {field = field, buffer = state.publication_component}; status = "Component (namespace/name): " .. state.publication_component
        elseif field == "publication_version" then editor = {field = field, buffer = state.publication_version}; status = "Explicit version: " .. state.publication_version
        elseif field == "publication_snapshot_digest" then editor = {field = field, buffer = state.publication_snapshot_digest}; status = "Frozen snapshot SHA-256: " .. state.publication_snapshot_digest
        else editor = {field = "parameter_name", buffer = ""}; status = "Parameter name (namespace:name): " end
        changed()
    end

    local function edit_requirement()
        local row = state.requirements[state.selected_requirement]
        if not row then status = "Select a requirement first"; changed(); return end
        editor = {field = "parameter_value", buffer = row.json, name = row.id}
        status = row.id .. " JSON: " .. row.json
        changed()
    end

    local function handle_hit(kind: string, key: string)
        status = ""
        if kind == "contents" then
            if state.selected and state.selected_version then
                model.show_requirements(state, false); reading_readme = false; offset = 0
                begin(contents.start(content, state.selected, state.selected_version)); changed()
            end
        elseif kind == "content_row" or kind == "content_back" or kind == "content_next" or kind == "content_previous" then
            local intent: contents.Intent? = nil
            if kind == "content_back" and content.mode == "entries" then
                content.open = false; reading_readme = true; invalidate()
            elseif kind == "content_back" then intent = contents.back(content)
            elseif kind == "content_next" then intent = contents.next(content)
            elseif kind == "content_previous" then intent = contents.previous(content)
            else intent = contents.activate(content, key ~= "" and key or nil) end
            if intent then begin(intent) end
            offset = 0; changed()
        elseif kind == "save_editor" then finish_editor()
        elseif kind == "cancel_editor" then editor = nil; status = "Cancelled"; changed()
        elseif kind == "missing" then
            local measured = state.plan
            if state.phase == "plan" and measured then
                for _, id in ipairs(measured.missing) do
                    if key == "" or key == id then
                        editor = {field = "parameter_value", buffer = "", name = id}
                        status = "Enter a JSON value for " .. id
                        changed()
                        break
                    end
                end
            end
        elseif kind == "search" then begin_editor("query")
        elseif kind == "keyword" then begin_editor("keyword")
        elseif kind == "catalog" then invalidate(); catalog()
        elseif kind == "operations" then operation_history()
        elseif kind == "operation" then
            local _, problem = model.select_operation(state, key)
            if problem then status = problem end
            invalidate(); changed()
        elseif kind == "operations_previous" then model.set_operation_page(state, state.operation_page - 1); operation_history()
        elseif kind == "operations_next" then model.set_operation_page(state, state.operation_page + 1); operation_history()
        elseif kind == "recover" then
            if apply_pending then status = "An apply is still pending"
            else
                local problem = model.recover(state)
                if problem then status = problem else offset = 0; invalidate() end
            end
            changed()
        elseif kind == "installed" then invalidate(); installed()
        elseif kind == "authoring" then
            content.open = false; model.show(state, "authoring"); offset = 0; changed()
        elseif kind == "author_component" then begin_editor("publication_component")
        elseif kind == "author_version" then begin_editor("publication_version")
        elseif kind == "author_snapshot" then begin_editor("publication_snapshot_digest")
        elseif kind == "prepare_publication" then prepare_publication()
        elseif kind == "publish_publication" then publish_publication()
        elseif kind == "requirements" then requirements()
        elseif kind == "reset_requirement" then
            local row = state.requirements[state.selected_requirement]
            if row and row.origin == "Selected" then
                model.remove_parameter(state, row.id)
                invalidate()
                requirements()
                status = "Override cleared"
            end
        elseif kind == "requirement" then
            for index, row in ipairs(state.requirements) do if row.id == key then model.select_requirement(state, index); break end end
            edit_requirement()
        elseif kind == "readme" then content.open = false; invalidate(); model.show_requirements(state, false); reading_readme = true; offset = 0; changed()
        elseif kind == "versions" then content.open = false; invalidate(); model.show_requirements(state, false); reading_readme = false; offset = 0; changed()
        elseif kind == "details" then details()
        elseif kind == "plan" then plan()
        elseif kind == "component" then choose(key, true)
        elseif kind == "version" then content.open = false; model.select_version(state, key); invalidate(); changed()
        elseif kind == "previous" then model.set_page(state, state.page - 1); invalidate(); catalog()
        elseif kind == "next" then model.set_page(state, state.page + 1); invalidate(); catalog()
        elseif kind == "refresh" then invalidate(); installed()
        elseif kind == "install" or kind == "update" or kind == "uninstall" then
            content.open = false; model.set_action(state, kind); model.show_requirements(state, false); reading_readme = false; offset = 0; invalidate()
            -- Updating an existing root must use its current typed values. Read
            -- the authoritative inventory on demand; the normal read generation
            -- fence prevents a late snapshot from replacing newer user edits.
            if kind == "update" then model.begin_update_hydration(state); begin(model.installed_intent(state)) end
            changed()
        elseif kind == "plan" or kind == "refresh_plan" then plan()
        elseif kind == "parameter" then begin_editor("parameter_name")
        elseif kind == "policy_none" then model.set_policy(state, "none"); invalidate(); changed()
        elseif kind == "policy_up" then model.set_policy(state, "up"); invalidate(); changed()
        elseif kind == "policy_block" then model.set_policy(state, "block"); invalidate(); changed()
        elseif kind == "policy_leave" then model.set_policy(state, "leave"); invalidate(); changed()
        elseif kind == "policy_down" then model.set_policy(state, "down"); invalidate(); changed()
        elseif kind == "review" then local problem = model.confirm(state); if problem then status = problem end; changed()
        elseif kind == "confirm" then confirm()
        elseif kind == "cancel" then cancel_confirmation()
        elseif kind == "status" then check_status() end
    end

    if broker then process.send(broker, "bee.appearance.request", {version = 1, request_id = uuid.v7(), op = "state"}) end
    catalog()
    while running do
        if dirty then
            local display_status = editor and status or (status ~= "" and status or state.notice)
            local drawn = view.draw(width, height, preferences, state, offset, display_status, reading_readme, editor, content)
            hits, offset = drawn.hits, drawn.offset
            model.set_operation_detail_offset(state, drawn.operation_detail_offset)
            visible_rows = math.floor(math.max(1, drawn.capacity))
            assert(output:present(drawn.rows, {cursor = {x = 1, y = 1, visible = false}}))
            if not announced then client.ready(launch); announced = true end
            dirty = false
        end
        local cases = {input:case_receive(), lifecycle:case_receive(), states:case_receive()}
        if reading then cases[#cases + 1] = reading.response:case_receive() end
        for _, item in ipairs(pending) do cases[#cases + 1] = item.response:case_receive() end
        local event = channel.select(cases)
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then running = false end
        elseif event.channel == states then
            local message = event.value
            if broker and message:from() == broker then
                local payload: unknown = message:payload():data()
                local next_preferences = appearance.decode(payload)
                if next_preferences and type(payload) == "table" and payload.version == 1 then preferences = next_preferences; changed() end
            end
        else
            local completed_read = reading
            if completed_read and event.channel == completed_read.response then
                reading = nil
                local value = completed({future = completed_read.future, response = completed_read.response, operation = completed_read.operation,
                    generation = completed_read.generation, apply = false})
                if not completed_read.retired and completed_read.generation == generation then fold_read(completed_read.operation, value) end
                start_read()
                changed()
            else
                local found: Pending? = nil
                for index, item in ipairs(pending) do
                    if event.channel == item.response then found = item; table.remove(pending, index); break end
                end
                if found then
                local value = completed(found)
                if found.apply then
                    apply_pending = false
                    status = ""
                    model.apply_result(state, value)
                elseif found.operation == "publication_prepare" or found.operation == "publication_publish" then
                    publication_pending = false
                    status = ""
                    if found.operation == "publication_prepare" then model.apply_publication_prepare(state, value)
                    else model.apply_publication_publish(state, value) end
                end
                changed()
                else
                local data = event.value
                if data.type == "close" then running = false
                elseif data.type == "resize" then width, height = data.width, data.height; changed()
                elseif data.type == "key" and data.action ~= "release" then
                    local key, letter = data.key_type, tostring(data.key or "")
                    if key == "space" then letter = " " end
                    if editor then
                        if key == "esc" or key == "escape" then editor = nil; status = "Cancelled"; changed()
                        elseif key == "enter" then finish_editor()
                        elseif key == "backspace" then editor.buffer = previous(editor.buffer); status = (editor.field == "parameter_value" and "Parameter JSON value: " or "Edit: ") .. editor.buffer; changed()
                        elseif (key == "runes" or #letter == 1) and #letter > 0 and not data.ctrl and not data.alt and not letter:find("%c") then editor.buffer = editable(editor.buffer .. letter); status = (editor.field == "parameter_value" and "Parameter JSON value: " or "Edit: ") .. editor.buffer; changed() end
                    else
                        status = ""
                        if state.phase == "details" and content.open and (key == "up" or key == "down" or key == "pgup" or key == "pgdown") then
                            local delta = (key == "up" or key == "pgup") and -1 or 1
                            if #content.rows > 0 then contents.move(content, delta)
                            else offset = math.floor(math.max(0, offset + delta * ((key == "pgup" or key == "pgdown") and 5 or 1))) end
                            changed()
                        elseif state.phase == "details" and content.open and key == "enter" then handle_hit("content_row", "")
                        elseif state.phase == "details" and content.open and (key == "backspace" or key == "esc" or key == "escape") then handle_hit("content_back", "")
                        elseif state.phase == "details" and content.open and letter == "n" then handle_hit("content_next", "")
                        elseif letter == "c" and state.phase == "details" then handle_hit("contents", "")
                        elseif key == "up" or letter == "k" then
                            if (state.phase == "details" and reading_readme) or state.phase == "plan" or state.phase == "confirm" then offset = math.floor(math.max(0, offset - 1)); changed()
                            elseif state.phase == "operations" then operation_relative(-1)
                            elseif state.phase == "details" and state.requirements_open then model.select_requirement(state, state.selected_requirement - 1); changed()
                            elseif state.phase == "details" then version_relative(-1) elseif state.phase == "catalog" or state.phase == "installed" then choose_relative(-1) end
                        elseif key == "down" or (letter == "j" and state.phase ~= "details") then
                            if (state.phase == "details" and reading_readme) or state.phase == "plan" or state.phase == "confirm" then offset = offset + 1; changed()
                            elseif state.phase == "operations" then operation_relative(1)
                            elseif state.phase == "details" and state.requirements_open then model.select_requirement(state, state.selected_requirement + 1); changed()
                            elseif state.phase == "details" then version_relative(1) elseif state.phase == "catalog" or state.phase == "installed" then choose_relative(1) end
                        elseif (key == "pgup" or key == "pgdown") and state.phase == "operations" then
                            model.set_operation_detail_offset(state, state.operation_detail_offset + (key == "pgup" and -3 or 3)); changed()
                        elseif key == "left" and state.phase == "operations" then handle_hit("operations_previous", "")
                        elseif key == "right" and state.phase == "operations" then handle_hit("operations_next", "")
                        elseif key == "left" and state.phase == "catalog" then model.set_page(state, state.page - 1); invalidate(); catalog()
                        elseif key == "right" and state.phase == "catalog" then model.set_page(state, state.page + 1); invalidate(); catalog()
                        elseif key == "left" and state.phase == "details" and state.detail then model.set_detail_page(state, state.detail.page - 1); invalidate(); details()
                        elseif key == "right" and state.phase == "details" and state.detail then model.set_detail_page(state, state.detail.page + 1); invalidate(); details()
                        elseif key == "enter" then
                            if state.phase == "details" and state.requirements_open then edit_requirement()
                            elseif state.phase == "catalog" or state.phase == "installed" then details()
                            elseif state.phase == "operations" then handle_hit("recover", "")
                            elseif state.phase == "plan" then handle_hit("review", "")
                            elseif state.phase == "confirm" then confirm() end
                        elseif letter == "o" or letter == "O" then operation_history()
                        elseif key == "delete" and state.phase == "details" and state.requirements_open then handle_hit("reset_requirement", "")
                        elseif letter == "e" and state.phase == "plan" then handle_hit("missing", "")
                        elseif letter == "e" and state.phase == "details" then requirements()
                        elseif letter == "h" and state.phase == "details" then handle_hit("readme", "")
                        elseif letter == "v" and state.phase == "details" then handle_hit("versions", "")
                        elseif letter == "/" then begin_editor("query")
                        elseif letter == "K" then begin_editor("keyword")
                        elseif letter == "j" and state.phase == "details" then begin_editor("parameter_name")
                        elseif letter == "a" then handle_hit("authoring", "")
                        elseif letter == "c" and state.phase == "authoring" then begin_editor("publication_component")
                        elseif letter == "v" and state.phase == "authoring" then begin_editor("publication_version")
                        elseif letter == "s" and state.phase == "authoring" then begin_editor("publication_snapshot_digest")
                        elseif letter == "i" and state.phase == "details" then handle_hit("install", "")
                        elseif letter == "u" and state.phase == "details" then handle_hit("update", "")
                        elseif letter == "x" and state.phase == "details" then handle_hit("uninstall", "")
                        elseif letter == "p" and state.phase == "details" then plan()
                        elseif letter == "p" and state.phase == "authoring" then prepare_publication()
                        elseif letter == "u" and state.phase == "authoring" then publish_publication()
                        elseif letter == "r" then if state.phase == "operations" then operation_history() elseif state.phase == "result" then check_status() elseif state.phase == "plan" then plan() elseif state.phase == "installed" then invalidate(); installed() else invalidate(); catalog() end
                        elseif key == "esc" or key == "escape" then
                            if state.phase == "confirm" then cancel_confirmation()
                            elseif state.phase == "details" then model.show(state, "catalog"); changed()
                            elseif state.phase == "result" then model.show(state, "catalog"); changed()
                            elseif state.phase == "authoring" then model.show(state, "catalog"); changed()
                            else running = false end
                        end
                    end
                elseif data.type == "mouse" and data.action == "press" and data.button == "left" then
                    local hit = frame.hit(hits, math.floor(tonumber(data.x) or 1), math.floor(tonumber(data.y) or 1))
                    if hit then handle_hit(hit.kind, hit.key) end
                elseif data.type == "mouse" and data.action == "wheel" then
                    if state.phase == "details" and content.open then
                        local delta = (data.button == "wheel_up" or data.button == "up") and -1 or 1
                        if #content.rows > 0 then contents.move(content, delta) else offset = math.floor(math.max(0, offset + delta * 3)) end
                        changed()
                    elseif (state.phase == "details" and reading_readme) or state.phase == "plan" or state.phase == "confirm" then offset = math.floor(math.max(0, offset + ((data.button == "wheel_up" or data.button == "up") and -3 or 3))); changed()
                    elseif state.phase == "operations" then operation_relative((data.button == "wheel_up" or data.button == "up") and -1 or 1)
                    elseif state.phase == "details" and state.requirements_open then model.select_requirement(state, state.selected_requirement + ((data.button == "wheel_up" or data.button == "up") and -1 or 1)); changed()
                    elseif state.phase == "details" then version_relative((data.button == "wheel_up" or data.button == "up") and -1 or 1)
                    elseif state.phase == "catalog" or state.phase == "installed" then choose_relative((data.button == "wheel_up" or data.button == "up") and -1 or 1) end
                end
                end
            end
        end
    end
    if reading then reading.future:cancel() end
    for _, item in ipairs(pending) do item.future:cancel() end
    process.unlisten(states)
    output:close()
    tty.stop()
end

return {main = main}
