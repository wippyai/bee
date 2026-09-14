-- MIT. Resolve native harness continuation from committed owner state.
local bounds = require("bounds")
local checkpoint = require("checkpoint")
local record = require("record")
local hooks = require("hooks")
local json = require("json")
local M = {}
local PLACEMENT_METHODS = {"prepare", "start", "status", "stop", "reconcile", "cleanup", "evidence", "attach", "capabilities", "measure_executable", "close_stdin"}
type Request = {thread_id: string, action_id: string, attempt_id: string, owner_id: string, previous_attempt_id: string, session_ref: string,
    binding_ref: string, binding_digest: string, profile_id: string, profile_digest: string, placement_binding_ref: string, placement_binding_digest: string, placement_methods: {[string]: string}, reauthorize: boolean?}
type Call = (string, unknown) -> (unknown, string?)
local function value(call: Call, target: string, request: unknown): ({[string]: unknown}?, string?)
    local raw, err = call(target, request)
    if err then return nil, target .. ": " .. err end
    local reply = bounds.object(raw)
    if not reply or reply.ok ~= true then return nil, target .. " refused continuation lookup" end
    local result = bounds.object(reply.value)
    if not result then return nil, target .. " returned an invalid value" end
    return result, nil
end
local function target(request: Request, method: string): string?
    return request.placement_methods[method]
end
local function placement_error(request: Request): string?
    if not bounds.id(request.placement_binding_ref) then return "continuation has no placement binding" end
    if #request.placement_binding_digest ~= 64 or not request.placement_binding_digest:match("^[0-9a-f]+$") then return "continuation has an invalid placement binding digest" end
    for _, method in ipairs(PLACEMENT_METHODS) do
        if not bounds.id(request.placement_methods[method]) then return "continuation placement has no " .. method .. " method" end
    end
    return nil
end
function M.resolve(call: Call, request: Request): (string?, string?)
    if request.reauthorize == true then return nil, "reauthorization requires a saved window" end
    local missing_placement = placement_error(request)
    if missing_placement then return nil, missing_placement end
    if not bounds.id(request.previous_attempt_id) or request.previous_attempt_id == request.attempt_id then return nil, "continuation needs a distinct previous attempt" end
    if not bounds.id(request.session_ref) then return nil, "continuation needs a retained session" end
    local stored, stored_error = value(call, "bee.threads.carrier:checkpoint", {thread_id = request.thread_id, attempt_id = request.previous_attempt_id})
    if not stored then return nil, stored_error end
    if stored.attempt_id ~= request.previous_attempt_id or stored.action_id ~= request.action_id then return nil, "previous attempt belongs to another action" end
    if request.placement_binding_ref and stored.placement_binding ~= request.placement_binding_ref then return nil, "previous attempt used another placement binding" end
    if stored.placement_binding_digest ~= request.placement_binding_digest then return nil, "previous attempt has no matching placement binding digest" end
    if stored.attempt_state ~= "ended" or stored.attempt_outcome ~= "succeeded" or stored.open_turn_id ~= nil then return nil, "previous attempt has no successful completed turn" end
    local point, point_error = checkpoint.decode(stored.checkpoint)
    if not point then return nil, "previous checkpoint: " .. tostring(point_error) end
    if point.binding_ref ~= request.binding_ref or point.binding_digest ~= request.binding_digest or point.profile_id ~= request.profile_id or point.profile_digest ~= request.profile_digest then
        return nil, "previous attempt used another driver or profile"
    end
    if point.retained_session_ref ~= request.session_ref then return nil, "previous attempt did not use this retained session" end
    -- Captured-output completeness stays a separate recorded fact. The
    -- native terminal result and committed receipt decide turn completion.
    local terminal = point.terminal
    local resume_ref = terminal and bounds.id(terminal.resume_ref) or nil
    if not terminal or terminal.outcome ~= "succeeded" or not resume_ref then return nil, "native harness did not record a successful resumable result" end
    local status_target = target(request, "status")
    if not status_target then return nil, "placement binding has no status method" end
    local status, status_error = value(call, status_target, {attempt_id = request.previous_attempt_id})
    if not status then return nil, status_error end
    local attempt = bounds.object(status.attempt)
    if not attempt or attempt.attempt_id ~= request.previous_attempt_id or attempt.action_id ~= request.action_id or attempt.owner_id ~= request.owner_id or attempt.session_ref ~= request.session_ref then
        return nil, "previous native process has another owner or session"
    end
    if attempt.execution_state ~= "exited" then return nil, "previous native process has not exited" end
    return resume_ref, nil
end
-- Explicit interactive resume is not another successful structured turn.
-- The old process must be gone; its committed observations identify the
-- conversation, while the new attempt supplies fresh admission and grants.
type PreviousWindow = {stored: {[string]: unknown}, point: checkpoint.Checkpoint, attempt: {[string]: unknown}, binding: string, private_home: boolean}
function M.inspect_window(call: Call, request: Request, ended: boolean): (PreviousWindow?, string?)
    local missing_placement = placement_error(request)
    if missing_placement then return nil, missing_placement end
    if not bounds.id(request.previous_attempt_id) or request.previous_attempt_id == request.attempt_id then return nil, "continuation needs a distinct previous attempt" end
    if not bounds.id(request.session_ref) then return nil, "continuation needs a retained session" end
    local stored, stored_error = value(call, "bee.threads.carrier:checkpoint", {thread_id = request.thread_id, attempt_id = request.previous_attempt_id})
    if not stored then return nil, stored_error end
    if stored.attempt_id ~= request.previous_attempt_id or stored.action_id ~= request.action_id then return nil, "previous attempt belongs to another action" end
    if stored.placement_binding ~= request.placement_binding_ref then return nil, "previous attempt used another placement binding" end
    -- Automatic continuation pins the old placement. Explicit review authorizes
    -- today's implementation of that same binding, after its owner proves the
    -- old execution and retained session below. It grants no cross-placement
    -- transfer and never changes the historical preparation record.
    if request.reauthorize ~= true and stored.placement_binding_digest ~= request.placement_binding_digest then return nil, "previous attempt has no matching placement binding digest" end
    if (ended and stored.attempt_state ~= "ended") or stored.open_turn_id ~= nil then return nil, "previous window attempt has not ended" end
    local point, point_error = checkpoint.decode(stored.checkpoint)
    if not point then return nil, "previous checkpoint: " .. tostring(point_error) end
    if point.binding_ref ~= request.binding_ref or point.profile_id ~= request.profile_id then
        return nil, "previous attempt used another driver or profile"
    end
    if request.reauthorize ~= true and (point.binding_digest ~= request.binding_digest or point.profile_digest ~= request.profile_digest) then
        return nil, "previous attempt used another driver or profile implementation"
    end
    if point.retained_session_ref ~= request.session_ref then return nil, "previous attempt did not use this retained session" end
    local binding = point.gateway_binding
    if not binding then return nil, "previous window has no recorded hook binding" end
    local status_target = target(request, "status")
    if not status_target then return nil, "placement binding has no status method" end
    local status, status_error = value(call, status_target, {attempt_id = request.previous_attempt_id})
    if not status then return nil, status_error end
    local attempt = bounds.object(status.attempt)
    if not attempt or attempt.attempt_id ~= request.previous_attempt_id or attempt.action_id ~= request.action_id or attempt.owner_id ~= request.owner_id or attempt.session_ref ~= request.session_ref then
        return nil, "previous native process has another owner or session"
    end
    if ended and attempt.execution_state ~= "exited" then return nil, "previous native process has not exited" end
    if attempt.cleanup_state ~= "complete" and attempt.cleanup_state ~= "pending" and attempt.cleanup_state ~= "uncertain" then
        return nil, "previous native process cleanup state is invalid"
    end
    if type(status.private_home) ~= "boolean" then return nil, "previous native process has no durable HOME selection" end

    return {stored = stored, point = point, attempt = attempt, binding = binding, private_home = status.private_home :: boolean}, nil
end
function M.resolve_window(call: Call, request: Request): (string?, string?, boolean?)
    local previous, inspect_error = M.inspect_window(call, request, true)
    if not previous then return nil, inspect_error end
    local attempt, binding = previous.attempt, previous.binding
    local cursor = 0
    local conversation_session_id: string? = nil
    -- A full page advances by at least MAX_PAGE_RECORDS; a sparse page
    -- advances the owner's scan window. The thread itself has a fixed bound.
    local pages = math.ceil(bounds.MAX_THREAD_RECORDS / bounds.MAX_PAGE_RECORDS) + 1
    for _ = 1, pages do
        local page, page_error = value(call, "bee.threads.service:read_after", {thread_id = request.thread_id, cursor = cursor,
            limit = bounds.MAX_PAGE_RECORDS, filter = {kinds = {"observation"}, action_id = request.action_id}})
        if not page then return nil, page_error end
        local through = bounds.cursor(page.scanned_through)
        if not through or through < cursor or type(page.has_more) ~= "boolean" or (page.has_more and through == cursor) then
            return nil, "invalid continuation page cursor"
        end
        if type(page.records) ~= "table" then return nil, "continuation records must be a list" end
        local rows = page.records :: {unknown}
        local count = 0
        for key in pairs(rows) do
            if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil, "continuation records must be a dense list" end
            count = count + 1
        end
        if count ~= #rows or count > bounds.MAX_PAGE_RECORDS then return nil, "continuation page exceeds its record bound" end
        local sequence = cursor
        for _, row in ipairs(rows) do
            local item, item_error = record.decode(row)
            if not item then return nil, "continuation record: " .. tostring(item_error) end
            if item.thread_id ~= request.thread_id or item.action_id ~= request.action_id or item.kind ~= "observation"
                or item.sequence <= sequence or item.sequence > through then return nil, "continuation record does not match its page" end
            sequence = item.sequence
            if item.attempt_id == request.previous_attempt_id and item.source == "bee" and item.producer_id == request.owner_id then
                local body = bounds.object(item.body)
                local extension = body and bounds.object(body.data) or nil
                if extension and extension.type == "extension" and extension.event_name == "bee.harness.hook" then
                    if extension.event_revision ~= "1" then return nil, "unsupported hook observation revision" end
                    local encoded = bounds.text(extension.payload_json, bounds.MAX_RECORD_BYTES)
                    if not encoded then return nil, "invalid hook observation payload" end
                    local raw, decode_error = json.decode(encoded)
                    local payload = not decode_error and bounds.object(raw) or nil
                    if not payload or payload.binding_id ~= binding or type(payload.ambiguous) ~= "boolean" then
                        return nil, "hook observation does not match the previous binding"
                    end
                    local fields, fields_error = hooks.stored_fields(payload.fields)
                    if not fields or fields.event ~= payload.event then return nil, "invalid hook observation fields: " .. tostring(fields_error) end
                    -- Occurrence ambiguity says that this delivery cannot
                    -- identify one unique event. It does not erase the
                    -- provider conversation claim carried by the validated
                    -- fields. Keep that claim separate from occurrence
                    -- deduplication, and require all eligible claims to
                    -- agree before resuming.
                    local candidate = bounds.id(fields.session_id)
                    if candidate then
                        if conversation_session_id and conversation_session_id ~= candidate then return nil, "conflicting provider conversation references" end
                        conversation_session_id = candidate
                    end
                end
            end
        end
        cursor = through
        if not page.has_more then
            if not conversation_session_id then return nil, "previous window recorded no provider conversation" end
            -- Only an owned, ended attempt with a verified conversation can
            -- request cleanup. Placement still proves group absence and keeps
            -- the retained session home; a refused or uncertain cleanup does
            -- not authorize a replacement attempt.
            if attempt.cleanup_state ~= "complete" then
                local cleanup_target = target(request, "cleanup")
                if not cleanup_target then return nil, "placement binding has no cleanup method" end
                local cleaned, cleanup_error = value(call, cleanup_target, {attempt_id = request.previous_attempt_id})
                if not cleaned then return nil, cleanup_error end
                if cleaned.attempt_id ~= request.previous_attempt_id or cleaned.action_id ~= request.action_id
                    or cleaned.owner_id ~= request.owner_id or cleaned.session_ref ~= request.session_ref then
                    return nil, "cleanup reply belongs to another attempt or session"
                end
                if cleaned.execution_state ~= "exited" or cleaned.cleanup_state ~= "complete" then
                    return nil, "previous native process cleanup is not complete"
                end
            end
            return conversation_session_id, nil, previous.private_home
        end
    end
    return nil, "continuation scan exceeds the thread bound"
end
return M
