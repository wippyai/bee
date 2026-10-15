-- MIT. Durable session creation, attachment, observation and transitions.
local sql = require("sql")
local access = require("access")
local journal = require("journal")
local transaction = require("transaction")
local reader = require("reader")
local part_work_records = require("part_work_records")
local M = {}
type Result = part_work_records.Result
type Row = part_work_records.Row
type Session = part_work_records.Session
local failure = part_work_records.failure
local object = part_work_records.object
local has_only = part_work_records.has_only
local text = part_work_records.text
local key = part_work_records.key
local ref = part_work_records.ref
local integer = part_work_records.integer
local now_ms = part_work_records.now_ms
local encode = part_work_records.encode
local digest = part_work_records.digest
local allocate_id = part_work_records.allocate_id
local qualified = part_work_records.qualified
local authenticated = part_work_records.authenticated
local target_workspace = part_work_records.target_workspace
local mutation_workspace = part_work_records.mutation_workspace
local append_event = part_work_records.append_event
local node_and_operation = part_work_records.node_and_operation
local operation_context = part_work_records.operation_context
local finish_operation = part_work_records.finish_operation
local missing_request = part_work_records.missing_request
local decode_json = part_work_records.decode_json
local current_epoch = part_work_records.current_epoch
local MAX_SESSION_SCAN = 64
function M.session_create(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor)
    if denied then return denied end
    local caller = assert(caller)
    local workspace = assert(workspace)
    local input = object(request)
    if not input or not has_only(input, {operation_key = true, title = true, route = true, thread_id = true}) then return missing_request() end
    local operation_key = key(input.operation_key)
    local title = input.title == nil and "Session" or text(input.title, 512)
    local route_json, route_error = encode(input.route or {})
    if not operation_key or not title or not route_json or type(input.route or {}) ~= "table" then
        return failure("INVALID_ARGUMENT", route_error or "operation_key, title or route is invalid")
    end
    local route_digest = digest(route_json)
    if not route_digest then return failure("INTERNAL", "measure pinned session route") end
    local existing_thread = input.thread_id == nil and nil or text(input.thread_id, 160)
    if input.thread_id ~= nil and not existing_thread then return missing_request() end
    local arguments = {title = title, route_digest = route_digest, thread_id = existing_thread}
    return transaction.write(db, function(tx: sql.Transaction): Result
        local request_digest, replay, context_error = operation_context(tx, caller, workspace, operation_key, "session_create", arguments)
        if context_error then return failure("INTERNAL", context_error) end
        if replay then return replay end
        local node, op_ref, reference_error = node_and_operation(nil, workspace)
        if not node or not op_ref then return failure("UNAVAILABLE", reference_error or "cannot allocate operation reference") end
        local session_id, session_id_error = allocate_id()
        local thread_id, thread_id_error = allocate_id()
        if existing_thread then thread_id = existing_thread end
        if not session_id or not thread_id then return failure("INTERNAL", session_id_error or thread_id_error or "allocate session identity") end
        local session_ref = qualified("bs", node, workspace, session_id)
        local stored_route: Row = {}
        for name, value in pairs(object(input.route) or {}) do stored_route[name] = value end
        stored_route.session_ref = session_ref
        stored_route.thread_id = thread_id
        stored_route.owner_id = caller
        stored_route.workspace_id = workspace
        stored_route.action_id = session_ref
        local stored_route_json, stored_route_error = encode(stored_route)
        if not stored_route_json then return failure("INVALID_ARGUMENT", stored_route_error or "session route is invalid") end
        local now = transaction.now()
        if existing_thread then
            local head, head_error = journal.interactive_thread(tx, existing_thread)
            if head_error then return transaction.storage_failure(head_error) end
            if not head or head.workspace_id ~= workspace then return failure("DENIED", "interactive session requires its workspace thread") end
            local member, member_error = reader.member(tx, existing_thread, caller)
            if member_error then return transaction.storage_failure(member_error) end
            if not member or not member.active then
                local stable, alias_error = reader.app_live_stable(tx, caller)
                if alias_error then return transaction.storage_failure(alias_error) end
                if stable then member, member_error = reader.app_family_member(tx, existing_thread, stable) end
                if member_error then return transaction.storage_failure(member_error) end
            end
            if not member or not member.active or (member.role ~= "owner" and member.role ~= "participant") then
                return failure("DENIED", "interactive session requires active participant membership in its workspace thread")
            end
        else
            local head_error = transaction.insert_head(tx, {thread_id = thread_id, owner_actor = caller, title = title,
                created_at = now, workspace_id = workspace})
            if head_error then return failure("INTERNAL", head_error) end
            local member_error = transaction.insert_member(tx, thread_id, caller, "owner", 1)
            if member_error then return failure("INTERNAL", member_error) end
        end
        local peer_error = transaction.insert_member(tx, thread_id, session_ref, "participant", 1)
        if peer_error then return failure("INTERNAL", peer_error) end
        local session_error = journal.insert_session(tx, session_ref, thread_id, workspace, caller, title, now, stored_route_json)
        if session_error then return failure("INTERNAL", session_error) end
        local session: Session = {session_ref = session_ref, thread_id = thread_id, workspace_id = workspace,
            owner_actor = caller, title = title, state = "active", revision = 1, created_at = now, updated_at = now,
            route_json = stored_route_json, context_json = "{}"}
        local record_id, sequence, event_error = append_event(tx, session, caller, op_ref, "session.created", session_ref, 1,
            {title = title, route_digest = route_digest})
        if not record_id or not sequence then return failure("INTERNAL", event_error or "append session creation event") end
        local receipt = {session = session_ref, operation = op_ref, state = "active", revision = 1, committed_at = now, sequence = sequence}
        return finish_operation(tx, caller, workspace, operation_key, op_ref, "session_create", request_digest, session_ref, receipt, now)
    end)
end

function M.session_attach(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor, true)
    if denied then return denied end
    local caller = assert(caller)
    local input = object(request)
    if not input or not has_only(input, {session = true, attempt_id = true, operation_key = true}) then return missing_request() end
    local session_ref, attempt, operation_key = ref(input.session), text(input.attempt_id, 160), key(input.operation_key)
    if not session_ref or not attempt or not operation_key then return missing_request() end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local session, session_error = journal.session(tx, session_ref, target_workspace(session_ref, workspace))
        if session_error then return transaction.storage_failure(session_error) end
        if not session or session.owner_actor ~= caller then return failure("DENIED", "interactive attachment belongs to its admitted owner") end
        local arguments = {session = session_ref, attempt_id = attempt}
        local request_digest, replay, context_error = operation_context(tx, caller, session.workspace_id, operation_key, "session_attach", arguments)
        if context_error then return failure("INTERNAL", context_error) end
        if replay then return replay end
        local route_value, route_error = decode_json(session.route_json)
        local route = object(route_value)
        if route_error or not route or route.delivery ~= "hook" then return failure("CONFLICT", "only interactive sessions attach a native window") end
        if session.state ~= "active" and session.state ~= "suspended" then return failure("CONFLICT", "sealed sessions cannot attach a window") end
        route.native_attempt_id = attempt
        local route_json, encode_error = encode(route)
        if not route_json then return failure("INTERNAL", encode_error or "encode attached route") end
        local node, op_ref, reference_error = node_and_operation(nil, session.workspace_id)
        if not node or not op_ref then return failure("UNAVAILABLE", reference_error or "allocate attachment operation") end
        local now = transaction.now()
        local _, sequence, event_error = append_event(tx, session, caller, op_ref, "session.attached", session_ref, session.revision + 1, {attempt_id = attempt})
        if not sequence then return failure("INTERNAL", event_error or "append attachment") end
        local update_error = journal.attach_session(tx, route_json, now, session_ref)
        if update_error then return failure("INTERNAL", update_error) end
        return finish_operation(tx, caller, session.workspace_id, operation_key, op_ref, "session_attach", request_digest, session_ref, {session = session_ref, operation = op_ref, attempt_id = attempt}, now)
    end)
end

local function consumption(tx: sql.Transaction, session: string): (Row?, string?)
    local row, err = journal.consumption(tx, session)
    if not row then return nil, err or "session consumption is missing" end
    local started, steps, tools, tokens = integer(row.budget_started_at_ms), integer(row.provider_steps), integer(row.tool_calls), integer(row.tokens)
    if not started or not steps or not tools or not tokens then return nil, "session consumption is corrupt" end
    return {provider_steps = steps, tool_calls = tools, tokens = tokens, wall_time_ms = started > 0 and math.max(0, now_ms() - started) or 0}, nil
end

-- The node's scheduler acts for every workspace: it describes and closes a
-- session by its address once the session's work settles.
function M.session_describe(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor, true)
    if denied then return denied end
    assert(caller)
    local input = object(request)
    local session_ref = input and has_only(input, {session = true}) and ref(input.session) or nil
    if not session_ref then return missing_request() end
    return transaction.read(db, function(tx: sql.Transaction): Result
        local session, query_error = journal.session(tx, session_ref, target_workspace(session_ref, workspace))
        if query_error then return transaction.storage_failure(query_error) end
        if not session then return failure("NOT_FOUND", "session does not exist") end
        local rows, count_error = journal.work_counts(tx, session_ref)
        if count_error or not rows then return transaction.storage_failure("count session work") end
        local queued, reserved, accepted, settled, uncertain = 0, 0, 0, 0, 0
        for _, row in ipairs(rows) do
            local phase = text(row.phase, 32)
            local count = integer(row.count)
            if not phase or not count then return failure("INTERNAL", "session work count is corrupt") end
            local uncertain_count = integer(row.uncertain)
            if not uncertain_count then return failure("INTERNAL", "session uncertainty count is corrupt") end
            uncertain = uncertain + uncertain_count
            if phase == "queued" then queued = count
            elseif phase == "reserved" then reserved = count
            elseif phase == "accepted" then accepted = count
            elseif phase == "settled" then settled = count
            else return failure("INTERNAL", "session work phase is corrupt") end
        end
        local head, head_error = journal.head(tx, session.thread_id)
        if head_error then return transaction.storage_failure(head_error) end
        if not head then return failure("INTERNAL", "session journal head is missing") end
        local head_sequence = integer(head.head_sequence)
        if head_sequence == nil then return failure("INTERNAL", "session journal sequence is corrupt") end
        local epoch, epoch_error = current_epoch(tx)
        if not epoch then return failure("UNAVAILABLE", epoch_error or "owner epoch is unavailable") end
        local recovery_row, recovery_error = journal.unreconciled_turns(tx, session_ref, epoch)
        if recovery_error then return transaction.storage_failure(recovery_error) end
        local recovery_blocked = recovery_row and integer(recovery_row.count) or 0
        if not recovery_blocked then return failure("INTERNAL", "unreconciled turn count is corrupt") end
        local route_value, route_error = decode_json(session.route_json)
        local route = object(route_value)
        if route_error or not route then return failure("INTERNAL", "session route is corrupt") end
        local supervision = object(route.supervision)
        local quiet_period = supervision and integer(supervision.quiet_period_ms) or 60000
        if not quiet_period or quiet_period < 1 then return failure("INTERNAL", "session quiet period is corrupt") end
        local last_rows, last_error = journal.last_result(tx, session_ref)
        if last_error or not last_rows then return transaction.storage_failure("read last session result") end
        local last_result: Row? = nil
        if #last_rows == 1 then
            local last = last_rows[1]
            local decoded, decode_error = decode_json(tostring(last.result_json or ""))
            local result = object(decoded)
            if decode_error or not result then return failure("INTERNAL", "last session result is corrupt") end
            local value = object(result.value)
            local fault = object(result.error)
            local summary = value and text(value.text, 65536) or fault and text(fault.message, 16384) or tostring(result.state)
            last_result = {work = last.work_ref, outcome = result.state, summary = (summary or ""):sub(1, 4096), at = last.created_at}
        end
        local first, first_error = journal.first_work(tx, session_ref)
        if first_error then return transaction.storage_failure(first_error) end
        local title = session.title
        if first then
            local decoded, decode_error = decode_json(tostring(first.input_json or ""))
            if decode_error then return failure("INTERNAL", "first session work is corrupt") end
            local input = object(decoded)
            local prompt = type(decoded) == "string" and decoded or input and text(input.text, 16384)
            if prompt then
                local line = prompt:match("[^\r\n]+")
                if line then title = tostring(session.title) .. " · " .. line:gsub("%c", " "):sub(1, 160) end
            end
        end
        local active_turn, turn_error = journal.session_activity(tx, session_ref)
        if turn_error then return transaction.storage_failure(turn_error) end
        local activity = "idle"
        if queued > 0 or reserved + accepted > 0 then activity = "working" end
        if uncertain > 0 or recovery_blocked > 0 then activity = "blocked" end
        local activity_evidence: Row? = nil
        if activity == "working" and active_turn and active_turn.phase == "accepted"
            and integer(active_turn.owner_epoch) == epoch then
            local last_progress_at = integer(active_turn.last_progress_at_ms)
            if last_progress_at == nil or last_progress_at < 1 then
                activity = "blocked"
            else
                local progress_at: integer = last_progress_at
                local quiet_for = math.max(0, now_ms() - progress_at)
                if quiet_for >= quiet_period then
                    activity = "stalled"
                    activity_evidence = {kind = "quiet", turn = active_turn.turn_ref,
                        last_progress_at_ms = last_progress_at, quiet_period_ms = quiet_period, quiet_for_ms = quiet_for}
                end
            end
        end
        local used, usage_error = consumption(tx, session_ref)
        if not used then return failure("INTERNAL", usage_error or "session consumption is unavailable") end
        local execution_running = accepted > 0 and recovery_blocked == 0
        local native_attempt = text(route.native_attempt_id, 160)
        local attempt_turn_ended = false
        if native_attempt then
            local ended, ended_error = journal.attempt_turn_ended(tx, session_ref, native_attempt)
            if ended == nil then return transaction.storage_failure(ended_error or "read attempt turns") end
            attempt_turn_ended = ended
        end
        return transaction.success({session = session.session_ref, thread_ref = session.thread_id, workspace = session.workspace_id,
            active_turn = active_turn and {turn = active_turn.turn_ref, claim = active_turn.claim_token, work = active_turn.work_ref,
                owner_epoch = active_turn.owner_epoch, phase = active_turn.phase, last_progress_at_ms = active_turn.last_progress_at_ms} or nil,
            last_result = last_result, title = title, state = session.state, route = route,
            revision = session.revision, created_at = session.created_at, updated_at = session.updated_at,
            queued = queued, active = reserved + accepted, execution_running = execution_running, attempt_turn_ended = attempt_turn_ended,
            settled = settled, uncertain = uncertain, recovery_blocked = recovery_blocked,
            activity = activity, activity_evidence = activity_evidence, budget_consumption = used,
            head_sequence = head_sequence}, false)
    end)
end

function M.node_summary(db: sql.DB, _: string, request: unknown): Result
    local input = object(request)
    if not input or next(input) ~= nil then return failure("INVALID_ARGUMENT", "node summary accepts an empty object") end
    if not access.may_summarize_sessions() then return failure("DENIED", "caller may not summarize node sessions") end
    return transaction.read(db, function(tx: sql.Transaction): Result
        local epoch, epoch_error = current_epoch(tx)
        if not epoch then return failure("UNAVAILABLE", epoch_error or "thread owner epoch is unavailable") end
        local rows, count_error = journal.executing_sessions(tx, epoch)
        if count_error or not rows or #rows ~= 1 then return transaction.storage_failure("count node sessions") end
        local count = integer(rows[1].count)
        if not count or count < 0 then return failure("INTERNAL", "node session count is corrupt") end
        return transaction.success({running_sessions = count}, false)
    end)
end

function M.session_scan(db: sql.DB, actor: string, request: unknown): Result
    local _, workspace, denied = authenticated(actor)
    if denied then return denied end
    local workspace = assert(workspace)
    local input = object(request)
    if not input or not has_only(input, {cursor = true, limit = true, workspace = true}) then return missing_request() end
    local cursor = input.cursor == nil and nil or ref(input.cursor)
    local limit: integer? = input.limit == nil and MAX_SESSION_SCAN or integer(input.limit)
    if (input.cursor ~= nil and not cursor) or not limit or limit < 1 or limit > MAX_SESSION_SCAN then
        return failure("INVALID_ARGUMENT", "session cursor or scan limit is invalid")
    end
    local selected_workspace = input.workspace == nil and nil or text(input.workspace, 32)
    if input.workspace ~= nil and (not selected_workspace or (selected_workspace ~= workspace and not access.may_list_workspace(selected_workspace))) then return failure("DENIED", "workspace visibility requires a host grant") end
    local page_limit = limit
    return transaction.read(db, function(tx: sql.Transaction): Result
        local homes, homes_error = journal.workspaces(tx)
        if homes_error or not homes then return transaction.storage_failure("read session workspaces") end
        local homes_to_scan: {string} = {}
        for _, row in ipairs(homes) do
            local home = text(row.workspace_id, 32)
            if home and (selected_workspace == nil or home == selected_workspace)
                and (home == workspace or access.may_list_workspace(home)) then
                homes_to_scan[#homes_to_scan + 1] = home
            end
        end
        if #homes_to_scan == 0 then return transaction.success({items = {}}, false) end
        local rows, query_error = journal.scan_sessions(tx, homes_to_scan, cursor, page_limit + 1)
        if query_error or not rows then return transaction.storage_failure("scan sessions") end
        local items: {string} = {}
        local count = #rows
        local has_more = count > page_limit
        if has_more then count = page_limit end
        for index = 1, count do
            local session_ref = ref(rows[index].session_ref)
            if not session_ref then return failure("INTERNAL", "session reference is corrupt") end
            local home = text(rows[index].workspace_id, 32)
            if home == workspace or (home and access.may_list_workspace(home)) then items[#items + 1] = session_ref end
        end
        local last_scanned = count > 0 and ref(rows[count].session_ref) or nil
        return transaction.success({items = items, next = has_more and last_scanned or nil}, false)
    end)
end

function M.session_transition(db: sql.DB, actor: string, request: unknown): Result
    local caller, home, denied = authenticated(actor, true)
    if denied then return denied end
    local caller = assert(caller)
    local input = object(request)
    if not input or not has_only(input, {session = true, state = true, operation_key = true, expected_revision = true}) then return missing_request() end
    local session_ref, operation_key = ref(input.session), key(input.operation_key)
    local target = text(input.state, 32)
    local expected_revision = input.expected_revision == nil and nil or integer(input.expected_revision)
    if input.expected_revision ~= nil and (not expected_revision or expected_revision < 1) then return failure("INVALID_ARGUMENT", "expected_revision must be a positive integer") end
    if not session_ref or not operation_key or (target ~= "active" and target ~= "suspended" and target ~= "closing" and target ~= "closed") then
        return failure("INVALID_ARGUMENT", "session, operation_key or lifecycle state is invalid")
    end
    local arguments = {session = session_ref, state = target}
    if expected_revision then arguments.expected_revision = expected_revision end
    local workspace: string? = nil
    if home then workspace = mutation_workspace(session_ref, home, "close")
    else workspace = session_ref:match("^[a-z]+:[^:]+:([^:]+):[^:]+$") end
    if not workspace then return failure("DENIED", "session control requires a host workspace grant") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local request_digest, replay, context_error = operation_context(tx, caller, workspace, operation_key, "session_transition", arguments)
        if context_error then return failure("INTERNAL", context_error) end
        if replay then return replay end
        local session, query_error = journal.session(tx, session_ref, target_workspace(session_ref, workspace))
        if query_error then return transaction.storage_failure(query_error) end
        if not session then return failure("NOT_FOUND", "session does not exist") end
        if expected_revision and expected_revision ~= session.revision then return failure("CONFLICT", "session revision changed") end
        local allowed = (session.state == "active" and (target == "suspended" or target == "closing"))
            or (session.state == "suspended" and (target == "active" or target == "closing"))
            or (session.state == "closing" and target == "closed")
        if session.state == "closed" then return failure("CONFLICT", "closed sessions cannot change lifecycle") end
        if target == session.state then allowed = true end
        if target == "closed" then
            local unsettled, count_error = journal.unsettled_work(tx, session_ref)
            if count_error then return transaction.storage_failure(count_error) end
            if not unsettled or integer(unsettled.count) ~= 0 then return failure("BLOCKED", "session has unsettled work") end
            allowed = session.state == "closing" or session.state == "active" or session.state == "suspended"
        end
        if not allowed then return failure("CONFLICT", "session lifecycle transition is not allowed") end
        local node, op_ref, reference_error = node_and_operation(nil, workspace)
        if not node or not op_ref then return failure("UNAVAILABLE", reference_error or "cannot allocate operation reference") end
        local now = transaction.now()
        local revision = session.revision
        if target ~= session.state then revision = revision + 1 end
        if target ~= session.state then
            local update_error = journal.transition_session(tx, target, revision, now, session_ref, session.revision)
            if update_error then return failure("CONFLICT", update_error) end
        end
        local record_id, sequence = nil, nil
        if target ~= session.state then
            local event_error: string?
            record_id, sequence, event_error = append_event(tx, session, caller, op_ref, "session.state_changed", session_ref,
                revision, {from = session.state, to = target})
            if not record_id or not sequence then return failure("INTERNAL", event_error or "append lifecycle event") end
        end
        if target == "closed" and sequence then
            local _, interval_error = tx:execute("UPDATE bee_session_trait_intervals SET end_sequence=? WHERE session_ref=? AND end_sequence IS NULL", {sequence, session_ref})
            if interval_error then return failure("INTERNAL", "close session listen intervals") end
        end
        local receipt = {session = session_ref, operation = op_ref, state = target, revision = revision,
            committed_at = now, sequence = sequence}
        return finish_operation(tx, caller, workspace, operation_key, op_ref, "session_transition", request_digest, session_ref, receipt, now)
    end)
end

M.failure = failure
M.object = object
M.has_only = has_only
M.text = text
M.key = key
M.ref = ref
M.integer = integer
M.now_ms = now_ms
M.encode = encode
M.digest = digest
M.allocate_id = allocate_id
M.qualified = qualified
M.authenticated = authenticated
M.target_workspace = target_workspace
M.mutation_workspace = mutation_workspace
M.append_event = append_event
M.node_and_operation = node_and_operation
M.operation_context = operation_context
M.finish_operation = finish_operation
M.missing_request = missing_request
M.decode_json = decode_json
M.current_epoch = current_epoch
M.MAX_SESSION_SCAN = MAX_SESSION_SCAN
M.consumption = consumption
return M
