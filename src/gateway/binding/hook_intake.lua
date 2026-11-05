-- MIT. Hook intake for the gateway authority.
local sql = require("sql")
local time = require("time")
local uuid = require("uuid")
local json = require("json")
local security = require("security")
local bounds = require("bounds")
local hooks = require("hooks")
local binding_store = require("binding_store")
local hook_store = require("hook_store")
local listener_store = require("listener_store")
local part_listener = require("part_listener")
local part_model = require("part_model")
local part_records = require("part_records")
local part_values = require("part_values")
local M = {}
type Reply = part_model.Reply
type Object = part_model.Object
type Binding = part_model.Binding
type Generation = part_model.Generation
type HookRecord = part_model.HookRecord
type HookQueueItem = part_model.HookQueueItem
type HookStatus = part_model.HookStatus
local FORMAT = part_values.FORMAT
local fail = part_values.fail
local succeed = part_values.succeed
local now_ms = part_values.now_ms
local stamp = part_values.stamp
local actor = part_values.actor
local integer = part_values.integer
local open = part_values.open
local optional_text = part_values.optional_text
local optional_timestamp = part_values.optional_timestamp
local binding_of = part_records.binding_of
local binding_by_id = part_records.binding_by_id
local restarts = part_listener.restarts
local function stored_hook_fields(value: unknown): (Object?, string?)
    local encoded = bounds.text(value, 8192)
    if not encoded then return nil, "hook fields JSON is corrupt" end
    local decoded, decode_error = json.decode(encoded)
    if decode_error then return nil, "hook fields JSON is corrupt" end
    local fields, fields_error = hooks.stored_fields(decoded)
    if not fields then return nil, fields_error or "hook fields are corrupt" end
    return fields, nil
end
local function hook_record(value: unknown): (HookRecord?, string?)
    local row = bounds.object(value)
    if not row then return nil, "hook row is corrupt" end
    local event_id, event = bounds.id(row.event_id), bounds.text(row.event, 64)
    local occurrence = bounds.text(row.occurrence, 256)
    local ambiguous = bounds.count(row.ambiguous)
    local digest = bounds.text(row.digest, 64)
    local provenance = bounds.text(row.provenance, 80)
    local sequence = bounds.count(row.sequence)
    local created_at = bounds.text(row.created_at, 64)
    local created, created_error = time.parse(FORMAT, created_at or "")
    local fields, fields_error = stored_hook_fields(row.fields_json)
    if not event_id then return nil, "hook row identity is corrupt" end
    if not event or not hooks.known(event) then return nil, "hook event is corrupt" end
    if not occurrence or occurrence == "" then return nil, "hook occurrence is corrupt" end
    if ambiguous == nil or (ambiguous ~= 0 and ambiguous ~= 1) then return nil, "hook ambiguity flag is corrupt" end
    if not digest then return nil, "hook digest is corrupt" end
    if #digest ~= 64 or not digest:match("^[0-9a-f]+$") then return nil, "hook digest is corrupt" end
    if not provenance or provenance == "" then return nil, "hook provenance is corrupt" end
    if sequence == nil or sequence == 0 then return nil, "hook sequence is corrupt" end
    if not created_at or created_error or not created then return nil, "hook creation time is corrupt" end
    if not fields then return nil, fields_error or "hook fields are corrupt" end
    if fields.event ~= event then return nil, "hook row event does not match its fields" end
    return {event_id = event_id, event = event, occurrence = occurrence, ambiguous = ambiguous == 1, digest = digest,
        fields = fields, provenance = provenance, sequence = sequence, created_at = created_at}, nil
end
local function hook_status(value: unknown): (HookStatus?, string?)
    local row = bounds.object(value)
    if not row then return nil, "hook status row is corrupt" end
    local event = bounds.text(row.event, 64)
    local occurrence = bounds.text(row.occurrence, 256)
    local ambiguous = bounds.count(row.ambiguous)
    local status = bounds.text(row.status, 16)
    local sequence, claimed_epoch = bounds.count(row.sequence), bounds.count(row.claimed_epoch)
    local rejected_reason, reason_valid = optional_text(row.rejected_reason, 120)
    if not event or not hooks.known(event) then return nil, "hook status event is corrupt" end
    if not occurrence or occurrence == "" then return nil, "hook status occurrence is corrupt" end
    if ambiguous == nil or (ambiguous ~= 0 and ambiguous ~= 1) then return nil, "hook status ambiguity flag is corrupt" end
    if status ~= "queued" and status ~= "committed" and status ~= "rejected" then return nil, "hook status state is corrupt" end
    if sequence == nil or sequence == 0 then return nil, "hook status sequence is corrupt" end
    if claimed_epoch == nil then return nil, "hook claimed epoch is corrupt" end
    if not reason_valid then return nil, "hook rejection reason is corrupt" end
    return {status = status, event = event, occurrence = occurrence, ambiguous = ambiguous == 1, sequence = sequence,
        claimed_epoch = claimed_epoch, rejected_reason = rejected_reason}, nil
end
-- submit_hook: an observation the attempt reports about itself, queued in
-- the gateway store under the binding's identity until a carrier commits
-- it. The payload's identifiers are recorded as claims; nothing content
-- bearing is kept; control fields are dropped first. Identity is the
-- occurrence the event carries: an identical replay answers the queued or
-- committed event again, a changed submission under the same occurrence
-- conflicts, and an event without a unique occurrence is recorded per
-- delivery as ambiguous.
function M.submit_hook(binding: Binding, payload: Object, provenance: string): Reply
    local cleaned = hooks.control_free(payload)
    local event = bounds.id(cleaned.hook_event_name) or bounds.id(cleaned.event) or ""
    if event == "" then return fail("INVALID", "hook_event_name is required") end
    if not hooks.known(event) then return fail("INVALID", "event " .. event .. " is not in the hook catalog") end
    local admitted = false
    for _, name in ipairs(binding.hooks) do if name == event then admitted = true end end
    if not admitted then return fail("DENIED", "event " .. event .. " is not admitted for this binding") end
    local submission, normalize_error = hooks.normalize(event, cleaned)
    if not submission then return fail("INVALID", normalize_error or "hook") end
    local db, open_failure = open()
    if not db then return open_failure end
    -- The seal check, the replay check, the bound and the insert are one
    -- transaction, so no submission is accepted after the seal's point.
    local tx, begin_error = db:begin()
    if not tx then db:release(); return fail("STORAGE", "begin intake") end
    local function done(reply: Reply): Reply
        tx:rollback()
        db:release()
        return reply
    end
    local state, state_error = binding_store.intake_state(tx, binding.binding_id)
    if state_error or not state or #state ~= 1 then return done(fail("STORAGE", "read binding")) end
    local current = bounds.object(state[1])
    local revoked_at, valid_revoked_at = optional_timestamp(current and current.revoked_at)
    local sealed_at, valid_sealed_at = optional_timestamp(current and current.sealed_at)
    if not current or not valid_revoked_at or not valid_sealed_at then return done(fail("STORAGE", "binding intake state is corrupt")) end
    if not submission.ambiguous then
        local existing, existing_error = hook_store.existing_occurrence(tx, binding.binding_id, event, submission.occurrence)
        if existing_error or not existing then return done(fail("STORAGE", "read hooks")) end
        if #existing > 1 then return done(fail("STORAGE", "hook occurrence is duplicated")) end
        if #existing == 1 then
            local stored = bounds.object(existing[1])
            local stored_digest = stored and bounds.text(stored.digest, 64)
            local stored_id = stored and bounds.id(stored.event_id)
            local stored_status = stored and bounds.text(stored.status, 16)
            local rejected_reason, reason_valid = optional_text(stored and stored.rejected_reason, 120)
            if not stored or not stored_digest or #stored_digest ~= 64 or not stored_digest:match("^[0-9a-f]+$") or not stored_id
                or (stored_status ~= "queued" and stored_status ~= "committed" and stored_status ~= "rejected") or not reason_valid then
                return done(fail("STORAGE", "hook occurrence row is corrupt"))
            end
            if stored_digest ~= submission.digest then return done(fail("CONFLICT", "occurrence " .. submission.occurrence .. " of " .. event .. " was already submitted with different content")) end
            return done(succeed({event = event, event_id = stored_id, status = stored_status, replayed = true, ambiguous = false, rejected_reason = rejected_reason}))
        end
    end
    if revoked_at ~= nil then return done(fail("DENIED", "intake is closed: binding revoked")) end
    if sealed_at ~= nil then return done(fail("DENIED", "intake is sealed: the attempt's child has ended")) end
    local queued, count_error = hook_store.queued_count(tx, binding.binding_id)
    if count_error or not queued or #queued ~= 1 then return done(fail("STORAGE", "count hooks")) end
    local queued_row = bounds.object(queued[1])
    local queued_count = queued_row and bounds.count(queued_row.queued)
    if queued_count == nil then return done(fail("STORAGE", "queued hook count is corrupt")) end
    if queued_count >= hooks.MAX_QUEUE then
        return done(fail("OVERLOAD", "the binding holds " .. tostring(hooks.MAX_QUEUE) .. " queued hooks; retry after " .. tostring(hooks.RETRY_AFTER_MS) .. " ms"))
    end
    local sequence_rows, sequence_error = hook_store.last_sequence(tx, binding.binding_id)
    if sequence_error or not sequence_rows or #sequence_rows ~= 1 then return done(fail("STORAGE", "sequence hooks")) end
    local sequence_row = bounds.object(sequence_rows[1])
    local last_sequence = (sequence_row and bounds.count(sequence_row.last)) or -1
    if last_sequence < 0 or last_sequence >= 9007199254740991 then return done(fail("STORAGE", "hook sequence is corrupt")) end
    local sequence = last_sequence + 1
    local event_id, id_error = uuid.v7()
    if id_error or not event_id then return done(fail("STORAGE", "event id")) end
    local at = stamp(now_ms())
    local fields_json, fields_error = json.encode(submission.fields)
    if fields_error or not fields_json then return done(fail("STORAGE", "encode hook fields")) end
    local _, insert_error = hook_store.insert(tx, event_id, binding.binding_id, binding.attempt_id, binding.action_id, binding.carrier_epoch,
        event, submission.occurrence, submission.ambiguous and 1 or 0, submission.digest, fields_json, provenance, sequence, at)
    if insert_error then return done(fail("STORAGE", "queue hook")) end
    local _, commit_error = tx:commit()
    db:release()
    if commit_error then return fail("STORAGE", "commit intake") end
    return succeed({event = event, event_id = event_id, status = "queued", replayed = false, ambiguous = submission.ambiguous})
end
-- hook_status: what became of one submission; unknown when nothing under
-- that id exists for the binding, which after a loss permits a replay.
function M.hook_status(binding: Binding, event_id: string): Reply
    local db, open_failure = open()
    if not db then return open_failure end
    local rows, err = hook_store.status(db, event_id, binding.binding_id)
    db:release()
    if err or not rows then return fail("STORAGE", "read hook") end
    if #rows == 0 then return succeed({event_id = event_id, status = "unknown"}) end
    local status, decode_error = hook_status(rows[1])
    if not status then return fail("STORAGE", decode_error or "hook status is corrupt") end
    return succeed({event_id = event_id, status = status.status, event = status.event, occurrence = status.occurrence,
        ambiguous = status.ambiguous, sequence = status.sequence, claimed_epoch = status.claimed_epoch, rejected_reason = status.rejected_reason})
end
-- hook_queue: the queued and committed submissions of a binding in order,
-- for the carrier that will commit them and for proofs. Fields only.
function M.hook_queue(binding: Binding, event_id: string?): Reply
    local db, open_failure = open()
    if not db then return open_failure end
    local rows, err = hook_store.queue(db, binding.binding_id, event_id)
    db:release()
    if err or not rows then return fail("STORAGE", "read hooks") end
    local list: {HookQueueItem} = {}
    for index, row in ipairs(rows) do
        local base, base_error = hook_record(row)
        local stored = bounds.object(row)
        local status = stored and bounds.text(stored.status, 16)
        local claimed_epoch = stored and bounds.count(stored.claimed_epoch)
        local rejected_reason, reason_valid = optional_text(stored and stored.rejected_reason, 120)
        if not base or not stored or (status ~= "queued" and status ~= "committed" and status ~= "rejected")
            or claimed_epoch == nil or not reason_valid then
            return fail("STORAGE", base_error or "hook queue row is corrupt")
        end
        list[index] = {event_id = base.event_id, event = base.event, occurrence = base.occurrence, ambiguous = base.ambiguous,
            digest = base.digest, fields = base.fields, provenance = base.provenance, status = status, sequence = base.sequence,
            created_at = base.created_at, claimed_epoch = claimed_epoch, rejected_reason = rejected_reason}
    end
    return succeed({hooks = list})
end
-- The binding admission and every hook mutation serialize this comparison in
-- one gateway-store transaction. The thread carrier epoch still fences the
-- record commit; this only prevents a preflight read from letting an old
-- gateway claim or acknowledgment race a later admission.
local function intake_epoch(tx: sql.Transaction, attempt_id: string, carrier_epoch: integer): Reply?
    local rows, err = binding_store.intake_carrier_epoch(tx, attempt_id)
    if err or not rows or #rows ~= 1 then return fail("STORAGE", "read bindings") end
    local row = bounds.object(rows[1])
    local highest = row and bounds.count(row.highest)
    if highest == nil or highest == 0 then return fail("STORAGE", "binding carrier epoch is corrupt") end
    if carrier_epoch < highest then
        return fail("CONFLICT", "carrier epoch " .. tostring(carrier_epoch) .. " is below the highest epoch " .. tostring(highest) .. " admitted for attempt " .. attempt_id)
    end
    return nil
end
local function intake_binding(tx: sql.Transaction, binding_id: string): (Binding?, Reply?)
    local rows, err = binding_store.intake_binding(tx, binding_id)
    if err or not rows then return nil, fail("STORAGE", "read binding") end
    if #rows == 0 then return nil, fail("NOT_FOUND", "binding does not exist") end
    local binding, decode_error = binding_of(rows[1])
    if not binding then return nil, fail("STORAGE", decode_error or "binding is corrupt") end
    return binding, nil
end
local function intake_generation(tx: sql.Transaction): (Generation?, Reply?)
    local rows, err = listener_store.epoch(tx)
    if err or not rows then return nil, fail("STORAGE", "read listener") end
    if #rows == 0 then return nil, fail("UNAVAILABLE", "the gateway listener has not been opened") end
    if #rows ~= 1 then return nil, fail("STORAGE", "listener row is duplicated") end
    local count, count_error = restarts()
    if not count then return nil, fail("UNAVAILABLE", count_error or "listener restarts unknown") end
    local row = bounds.object(rows[1])
    local epoch = row and bounds.count(row.epoch)
    if not epoch or epoch == 0 then return nil, fail("STORAGE", "listener epoch is corrupt") end
    return {epoch = epoch, restarts = count}, nil
end
local function intake_caller(binding: Binding): Reply?
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(part_model.ADMIT, binding.action_id) and not security.can(part_model.MANAGE, "bindings") then return fail("DENIED", "caller may not drain this binding's hooks") end
    return nil
end
local function intake_request(value: unknown, extra: {string}): (Object?, Binding?, sql.DB?, integer?, Reply?)
    local object = bounds.object(value)
    if not object then return nil, nil, nil, nil, fail("INVALID", "request must be an object") end
    local fields = {"binding_id", "carrier_epoch"}
    for _, name in ipairs(extra) do fields[#fields + 1] = name end
    local unknown_field = bounds.fields(object, fields)
    if unknown_field then return nil, nil, nil, nil, fail("INVALID", unknown_field) end
    local binding_id = bounds.id(object.binding_id)
    if not binding_id then return nil, nil, nil, nil, fail("INVALID", "binding_id is not an identifier") end
    local carrier_epoch = integer(object.carrier_epoch)
    if not carrier_epoch or carrier_epoch < 1 then return nil, nil, nil, nil, fail("INVALID", "carrier_epoch must be a positive integer") end
    local db, open_failure = open()
    if not db then return nil, nil, nil, nil, open_failure end
    local binding, missing = binding_by_id(db, binding_id)
    if not binding then db:release(); return nil, nil, nil, nil, missing end
    local refusal = intake_caller(binding)
    if refusal then db:release(); return nil, nil, nil, nil, refusal end
    return object, binding, db, carrier_epoch, nil
end
-- hook_claim: the carrier takes the next queued submissions of its binding
-- under its epoch. Rows a lower epoch claimed are taken over; rows already
-- claimed by this epoch are redelivered until acknowledgment, while rows a
-- higher epoch claimed are never touched. An invalid binding rejects only
-- work no carrier claimed. It still lets a current or replacement carrier
-- reclaim claimed rows, because their thread commit may have succeeded before
-- the acknowledgement was lost.
function M.hook_claim(value: unknown): Reply
    local object, binding, db, carrier_epoch, refusal = intake_request(value, {"limit"})
    if not object or not binding or not db or not carrier_epoch then return assert(refusal) end
    local limit = part_model.MAX_HOOK_CLAIM
    if object.limit ~= nil then
        local declared = bounds.integer(object.limit)
        if not declared or declared < 1 or declared > part_model.MAX_HOOK_CLAIM then db:release(); return fail("INVALID", "limit must be between 1 and " .. tostring(part_model.MAX_HOOK_CLAIM)) end
        limit = declared
    end
    local tx, begin_error = db:begin()
    if not tx then db:release(); return fail("STORAGE", "begin hook claim") end
    local current_binding, binding_failure = intake_binding(tx, binding.binding_id)
    if not current_binding then tx:rollback(); db:release(); return binding_failure end
    local generation, generation_failure = intake_generation(tx)
    if not generation then tx:rollback(); db:release(); return generation_failure end
    local epoch_refusal = intake_epoch(tx, current_binding.attempt_id, carrier_epoch)
    if epoch_refusal then tx:rollback(); db:release(); return epoch_refusal end
    local at = stamp(now_ms())
    local ok, reason = part_listener.valid(current_binding, generation)
    local recovery_only = false
    if not ok then
        -- A credential cannot submit after revocation, expiry or a
        -- listener-epoch change. This internal operation is independently
        -- authorized and carrier-epoch fenced, so it may recover only rows
        -- whose delivery already began; unclaimed rows are terminally refused.
        local _, reject_error = hook_store.reject_unclaimed_for_binding(tx, current_binding.binding_id, reason, at)
        if reject_error then tx:rollback(); db:release(); return fail("STORAGE", "reject unclaimed hooks") end
        recovery_only = true
    end
    local rows, err = hook_store.queued_ids(tx, current_binding.binding_id, carrier_epoch, recovery_only, limit)
    if err or not rows then tx:rollback(); db:release(); return fail("STORAGE", "read queued hooks") end
    local claimed: {HookRecord} = {}
    for _, row in ipairs(rows) do
        local event_id = bounds.id((row).event_id)
        if not event_id then tx:rollback(); db:release(); return fail("STORAGE", "queued hook identity is corrupt") end
        local result, claim_error = hook_store.claim(tx, event_id, carrier_epoch, at)
        if claim_error then tx:rollback(); db:release(); return fail("STORAGE", "claim hook") end
        local affected = result and bounds.count(result.rows_affected)
        if affected == nil or affected > 1 then tx:rollback(); db:release(); return fail("STORAGE", "hook claim result is corrupt") end
        if affected == 1 then
            local detail, detail_error = hook_store.claimed_row(tx, event_id)
            if detail_error or not detail or #detail ~= 1 then tx:rollback(); db:release(); return fail("STORAGE", "read claimed hook") end
            local item, item_error = hook_record(detail[1])
            if not item or item.event_id ~= event_id then
                tx:rollback(); db:release(); return fail("STORAGE", item_error or "claimed hook identity is corrupt")
            end
            claimed[#claimed + 1] = item
        end
    end
    local _, commit_error = tx:commit()
    db:release()
    if commit_error then return fail("STORAGE", "commit hook claim") end
    return succeed({binding_id = binding.binding_id, carrier_epoch = carrier_epoch, hooks = claimed})
end
-- Keeps the retained rows of a binding within the bounds by dropping the
-- oldest committed or rejected ones; queued rows are never pruned.
local function prune(db: sql.DB, binding_id: string): string?
    local rows, err = hook_store.retained(db, binding_id)
    if err or not rows then return "read retained hooks" end
    local kept = 0
    local bytes = 0
    for _, row in ipairs(rows) do
        kept = kept + 1
        local stored = bounds.object(row)
        local stored_bytes = stored and bounds.count(stored.bytes)
        if stored_bytes == nil then return "retained hook byte count is corrupt" end
        bytes = bytes + stored_bytes
        if kept > part_model.MAX_RETAINED_HOOKS or bytes > part_model.MAX_RETAINED_HOOK_BYTES then
            local event_id = stored and bounds.id(stored.event_id)
            if not event_id then return "retained hook identity is corrupt" end
            local _, delete_error = hook_store.delete(db, event_id)
            if delete_error then return "prune retained hooks" end
        end
    end
    return nil
end
-- hook_ack: the carrier reports that the named claimed submissions are
-- thread records; only the epoch that claimed them may say so.
function M.hook_ack(value: unknown): Reply
    local object, binding, db, carrier_epoch, refusal = intake_request(value, {"event_ids"})
    if not object or not binding or not db or not carrier_epoch then return assert(refusal) end
    local event_ids, ids_error = bounds.ids(object.event_ids, true)
    if not event_ids then db:release(); return fail("INVALID", "event_ids: " .. tostring(ids_error)) end
    if #event_ids > part_model.MAX_HOOK_CLAIM then db:release(); return fail("INVALID", "event_ids exceeds " .. tostring(part_model.MAX_HOOK_CLAIM)) end
    local tx, begin_error = db:begin()
    if not tx then db:release(); return fail("STORAGE", "begin hook acknowledgment") end
    local epoch_refusal = intake_epoch(tx, binding.attempt_id, carrier_epoch)
    if epoch_refusal then tx:rollback(); db:release(); return epoch_refusal end
    local at = stamp(now_ms())
    local acknowledged = 0
    for _, event_id in ipairs(event_ids) do
        -- Only the epoch that claimed a row may acknowledge it: a replacement
        -- takes the row over first, then commits it, then acknowledges.
        local result, ack_error = hook_store.acknowledge(tx, at, event_id, binding.binding_id, carrier_epoch)
        if ack_error then tx:rollback(); db:release(); return fail("STORAGE", "acknowledge hook") end
        local affected = result and bounds.count(result.rows_affected)
        if affected == nil or affected > 1 then tx:rollback(); db:release(); return fail("STORAGE", "hook acknowledgment result is corrupt") end
        if affected == 1 then acknowledged = acknowledged + 1 end
    end
    local _, commit_error = tx:commit()
    if commit_error then db:release(); return fail("STORAGE", "commit hook acknowledgment") end
    local prune_error = prune(db, binding.binding_id)
    db:release()
    if prune_error then return fail("STORAGE", prune_error) end
    return succeed({binding_id = binding.binding_id, acknowledged = acknowledged})
end
-- hook_reject: the carrier ends intake for its binding. Only unclaimed rows
-- are proved never to have reached a thread commit; claimed rows stay for
-- reconciliation rather than being falsely called rejected.
function M.hook_reject(value: unknown): Reply
    local object, binding, db, carrier_epoch, refusal = intake_request(value, {"reason"})
    if not object or not binding or not db or not carrier_epoch then return assert(refusal) end
    local reason = bounds.line(object.reason, 120)
    if not reason or reason == "" then db:release(); return fail("INVALID", "reason is required") end
    local tx, begin_error = db:begin()
    if not tx then db:release(); return fail("STORAGE", "begin hook rejection") end
    local epoch_refusal = intake_epoch(tx, binding.attempt_id, carrier_epoch)
    if epoch_refusal then tx:rollback(); db:release(); return epoch_refusal end
    local result, reject_error = hook_store.reject_binding(tx, stamp(now_ms()), reason, binding.binding_id)
    if reject_error then tx:rollback(); db:release(); return fail("STORAGE", "reject queued hooks") end
    local rejected = result and bounds.count(result.rows_affected)
    if rejected == nil then tx:rollback(); db:release(); return fail("STORAGE", "hook rejection result is corrupt") end
    local _, commit_error = tx:commit()
    db:release()
    if commit_error then return fail("STORAGE", "commit hook rejection") end
    return succeed({binding_id = binding.binding_id, rejected = rejected})
end
return M
