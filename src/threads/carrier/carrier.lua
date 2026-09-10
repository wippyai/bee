-- MIT. Carrier operations: a fenced epoch per attempt, and one transaction
-- that commits every record derived from a slice of runner output together
-- with the checkpoint that makes acknowledging that output safe. The
-- carrier keeps nothing the checkpoint does not hold.
local sql = require("sql")
local json = require("json")
local bounds = require("bounds")
local canonical = require("canonical")
local observation = require("observation")
local record_types = require("types")
local reader = require("reader")
local transaction = require("transaction")
local authority = require("authority")
local access = require("access")
local M = {}
M.CHECKPOINT_REVISION = "bee.carrier.checkpoint@1"
M.PROVENANCE_REVISION = "bee.carrier.provenance@1"
M.MAX_CHECKPOINT_BYTES = 65536
M.MAX_RECORDS = 64
-- The control schemas a carrier may commit with source bee, and nothing else.
M.CONTROL_EVENTS = {["bee.carrier.write"] = "1", ["bee.carrier.permission"] = "1", ["bee.carrier.output"] = "1", ["bee.carrier.input"] = "1", ["bee.placement.attempt"] = "1", ["bee.harness.hook"] = "1"}
type Result = transaction.Result
type Stored = {carrier_epoch: integer, checkpoint_revision: integer, checkpoint_json: string?}
type Provenance = {stream_id: string, source_first_sequence: integer, source_last_sequence: integer, envelope_index: integer, event_index: integer}
type Entry = {source: record_types.Source, decoded: record_types.Observation, turn_id: string?, provenance: Provenance?}
local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end
local function storage(err: string): Result
    return transaction.failure("INTERNAL", err)
end
local function integer(value: unknown): integer?
    if type(value) ~= "number" then return nil end
    return math.floor(value)
end
local function stored(tx: sql.Transaction, thread_id: string, attempt_id: string): (Stored?, string?)
    local rows, err = tx:query("SELECT carrier_epoch, checkpoint_revision, checkpoint_json FROM bee_thread_carriers WHERE thread_id = ? AND attempt_id = ?", {thread_id, attempt_id})
    if err or not rows then return nil, "read carrier" end
    if #rows == 0 then return nil, nil end
    local row = rows[1]
    local epoch, revision = integer(row.carrier_epoch), integer(row.checkpoint_revision)
    if not epoch or not revision then return nil, "carrier row is corrupt" end
    local checkpoint: string? = nil
    if type(row.checkpoint_json) == "string" then checkpoint = row.checkpoint_json :: string end
    return {carrier_epoch = epoch, checkpoint_revision = revision, checkpoint_json = checkpoint}, nil
end
local function view(current: Stored): {[string]: unknown}
    local checkpoint: unknown = nil
    if current.checkpoint_json then
        local decoded, err = json.decode(current.checkpoint_json :: string)
        if not err then checkpoint = decoded end
    end
    return {carrier_epoch = current.carrier_epoch, checkpoint_revision = current.checkpoint_revision, checkpoint = checkpoint}
end
-- The attempt the carrier acts on: live, in this thread, under the caller's
-- carrier authority.
local function live_attempt(tx: sql.Transaction, thread_id: string, attempt_id: string): (reader.Attempt?, Result?)
    if not access.may_carry(thread_id) then return nil, failure("DENIED", "caller holds no carrier authority for the thread") end
    local attempt, err = reader.attempt(tx, thread_id, attempt_id)
    if err then return nil, storage(err) end
    if not attempt then return nil, failure("NOT_FOUND", "attempt does not exist") end
    if attempt.state == "ended" then return nil, failure("INVALID_STATE", "attempt has ended") end
    return attempt, nil
end
local function named(request: unknown, fields: {string}): ({[string]: unknown}?, string?, Result?)
    local object = bounds.object(request)
    if not object then return nil, nil, failure("INVALID_ARGUMENT", "request must be an object") end
    local unknown_field = bounds.fields(object, fields)
    if unknown_field then return nil, nil, failure("INVALID_ARGUMENT", unknown_field) end
    local attempt_id = bounds.id(object.attempt_id)
    if not attempt_id then return nil, nil, failure("INVALID_ARGUMENT", "attempt_id is not an identifier") end
    return object, attempt_id, nil
end
-- claim: a new carrier epoch on a live attempt; the previous carrier's
-- commits are refused from now on.
function M.claim(db: sql.DB, actor: string, request: unknown): Result
    local mutation, invalid = authority.mutation(request)
    if not mutation then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local _, attempt_id, refused = named(request, {"thread_id", "idempotency_key", "attempt_id"})
    if not attempt_id then return refused or failure("INVALID_ARGUMENT", "invalid request") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, member, denied = authority.membership(tx, mutation.thread_id, actor)
        if not head or not member then return denied or failure("DENIED", "caller is not a member of the thread") end
        local replayed, replay_err = authority.replay(tx, actor, "carrier_claim", mutation)
        if replay_err then return storage(replay_err) end
        if replayed then return replayed end
        local attempt, stop = live_attempt(tx, head.thread_id, attempt_id)
        if not attempt then return stop or failure("INTERNAL", "attempt unavailable") end
        local current, current_err = stored(tx, head.thread_id, attempt_id)
        if current_err then return storage(current_err) end
        local next_epoch = (current and current.carrier_epoch or 0) + 1
        local at = transaction.now()
        local err: string?
        if current then
            local _, update_err = tx:execute("UPDATE bee_thread_carriers SET carrier_epoch = ?, updated_at = ? WHERE thread_id = ? AND attempt_id = ?", {next_epoch, at, head.thread_id, attempt_id})
            if update_err then err = "advance carrier epoch" end
        else
            local _, insert_err = tx:execute("INSERT INTO bee_thread_carriers (thread_id, attempt_id, carrier_epoch, checkpoint_revision, checkpoint_json, updated_at) VALUES (?, ?, ?, 0, NULL, ?)", {head.thread_id, attempt_id, next_epoch, at})
            if insert_err then err = "create carrier" end
        end
        if err then return storage(err) end
        local latest, latest_err = stored(tx, head.thread_id, attempt_id)
        if not latest then return storage(latest_err or "read carrier") end
        local value = view(latest)
        value.attempt_id = attempt_id
        value.action_id = attempt.action_id
        value.attempt_state = attempt.state
        return authority.remember(tx, actor, "carrier_claim", mutation, value)
    end)
end
local function decode_provenance(value: unknown): (Provenance?, string?)
    local object = bounds.object(value)
    if not object then return nil, "provenance must be an object" end
    local unknown_field = bounds.fields(object, {"schema_revision", "stream_id", "source_first_sequence", "source_last_sequence", "envelope_index", "event_index"})
    if unknown_field then return nil, unknown_field end
    if object.schema_revision ~= M.PROVENANCE_REVISION then return nil, "schema_revision is not " .. M.PROVENANCE_REVISION end
    local stream_id = bounds.id(object.stream_id)
    if not stream_id or stream_id:find("[:%s]") then return nil, "stream_id is not a plain identifier" end
    local first, last = bounds.integer(object.source_first_sequence), bounds.integer(object.source_last_sequence)
    if not first or first < 0 or not last or last < first then return nil, "chunk range must be nonnegative and ordered" end
    local envelope, event = bounds.integer(object.envelope_index), bounds.integer(object.event_index)
    if not envelope or envelope < 0 or not event or event < 0 then return nil, "envelope_index and event_index must be nonnegative integers" end
    return {stream_id = stream_id, source_first_sequence = first, source_last_sequence = last, envelope_index = envelope, event_index = event}, nil
end
-- The event key the authority derives: attempt, stream, envelope and event.
-- The chunk range is provenance, never identity.
function M.event_key(attempt_id: string, provenance: Provenance): string
    return table.concat({"carrier", attempt_id, provenance.stream_id, tostring(provenance.envelope_index), tostring(provenance.event_index)}, ":")
end
local function control_key(decoded: record_types.Observation): string?
    if decoded.type ~= "extension" then return "a bee-sourced carrier record is an extension observation" end
    local extension = decoded.data :: record_types.Extension
    local revision = M.CONTROL_EVENTS[extension.event_name]
    if not revision then return "control event " .. extension.event_name .. " is not one the carrier may commit" end
    if extension.event_revision ~= revision then return "control event " .. extension.event_name .. " revision must be " .. revision end
    return nil
end
local function decode_entries(value: unknown): ({Entry}?, string?)
    if type(value) ~= "table" then return nil, "records must be a list" end
    local list = value :: {unknown}
    if #list > M.MAX_RECORDS then return nil, "records exceeds " .. tostring(M.MAX_RECORDS) .. " items" end
    local entries: {Entry} = {}
    for index, item in ipairs(list) do
        local object = bounds.object(item)
        if not object then return nil, "records[" .. tostring(index) .. "] must be an object" end
        local unknown_field = bounds.fields(object, {"source", "body", "turn_id", "provenance"})
        if unknown_field then return nil, "records[" .. tostring(index) .. "]: " .. unknown_field end
        local source = bounds.member(object.source, {"stream", "bee"})
        if not source then return nil, "records[" .. tostring(index) .. "].source must be stream or bee" end
        local decoded, decode_error = observation.decode(object.body)
        if not decoded then return nil, "records[" .. tostring(index) .. "]: " .. tostring(decode_error) end
        if decoded.raw_ref ~= nil then return nil, "records[" .. tostring(index) .. "]: raw_ref names retained evidence, which carrier records do not carry" end
        local provenance: Provenance? = nil
        if source == "bee" then
            local problem = control_key(decoded)
            if problem then return nil, "records[" .. tostring(index) .. "]: " .. problem end
            if object.provenance ~= nil then return nil, "records[" .. tostring(index) .. "]: control records carry no provenance" end
        else
            local decoded_provenance, provenance_error = decode_provenance(object.provenance)
            if not decoded_provenance then return nil, "records[" .. tostring(index) .. "].provenance: " .. tostring(provenance_error) end
            provenance = decoded_provenance
        end
        local turn_id: string? = nil
        if object.turn_id ~= nil then
            turn_id = bounds.id(object.turn_id)
            if not turn_id then return nil, "records[" .. tostring(index) .. "].turn_id is not an identifier" end
        end
        entries[index] = {source = source :: record_types.Source, decoded = decoded, turn_id = turn_id, provenance = provenance}
    end
    return entries, nil
end
local function encode_checkpoint(value: unknown): (string?, string?)
    local object = bounds.object(value)
    if not object then return nil, "checkpoint must be an object" end
    if object.schema_revision ~= M.CHECKPOINT_REVISION then return nil, "checkpoint.schema_revision must be " .. M.CHECKPOINT_REVISION end
    local encoded, err = canonical.encode(object)
    if not encoded then return nil, "checkpoint is not encodable: " .. tostring(err) end
    if #encoded > M.MAX_CHECKPOINT_BYTES then return nil, "checkpoint exceeds " .. tostring(M.MAX_CHECKPOINT_BYTES) .. " bytes" end
    return encoded, nil
end
-- commit: every record and the next checkpoint in one transaction, fenced
-- by epoch and revision. Records already committed under their event keys
-- replay; the checkpoint still advances.
function M.commit(db: sql.DB, actor: string, request: unknown): Result
    local mutation, invalid = authority.mutation(request)
    if not mutation then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local object, attempt_id, refused = named(request, {"thread_id", "idempotency_key", "attempt_id", "carrier_epoch", "expected_revision", "checkpoint", "records"})
    if not object or not attempt_id then return refused or failure("INVALID_ARGUMENT", "invalid request") end
    local epoch = bounds.integer(object.carrier_epoch)
    if not epoch or epoch < 1 then return failure("INVALID_ARGUMENT", "carrier_epoch must be a positive integer") end
    local expected = bounds.integer(object.expected_revision)
    if not expected or expected < 0 then return failure("INVALID_ARGUMENT", "expected_revision must be a nonnegative integer") end
    local checkpoint, checkpoint_error = encode_checkpoint(object.checkpoint)
    if not checkpoint then return failure("INVALID_ARGUMENT", checkpoint_error or "invalid checkpoint") end
    local entries, entries_error = decode_entries(object.records == nil and {} or object.records)
    if not entries then return failure("INVALID_ARGUMENT", entries_error or "invalid records") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, member, denied = authority.membership(tx, mutation.thread_id, actor)
        if not head or not member then return denied or failure("DENIED", "caller is not a member of the thread") end
        local replayed, replay_err = authority.replay(tx, actor, "carrier_commit", mutation)
        if replay_err then return storage(replay_err) end
        if replayed then return replayed end
        if head.state ~= "open" then return failure("INVALID_STATE", "thread is closed") end
        local attempt, stop = live_attempt(tx, head.thread_id, attempt_id)
        if not attempt then return stop or failure("INTERNAL", "attempt unavailable") end
        local current, current_err = stored(tx, head.thread_id, attempt_id)
        if current_err then return storage(current_err) end
        if not current then return failure("CONFLICT", "no carrier has claimed the attempt") end
        if current.carrier_epoch ~= epoch then return failure("CONFLICT", "carrier epoch " .. tostring(epoch) .. " is not current; " .. tostring(current.carrier_epoch) .. " holds the attempt") end
        if current.checkpoint_revision ~= expected then return failure("CONFLICT", "checkpoint revision is " .. tostring(current.checkpoint_revision) .. ", not " .. tostring(expected)) end
        local committed: {{record_id: string, sequence: integer, replayed: boolean}} = {}
        for index, entry in ipairs(entries) do
            local turn_id: string? = entry.turn_id
            local decoded = entry.decoded
            local source = entry.source
            local context: authority.Context = {action_id = attempt.action_id, attempt_id = attempt_id, turn_id = turn_id}
            if turn_id then
                local turn, turn_err = reader.turn(tx, head.thread_id, turn_id)
                if turn_err then return storage(turn_err) end
                if not turn or turn.attempt_id ~= attempt_id then return failure("INVALID_ARGUMENT", "records[" .. tostring(index) .. "] names a turn outside the attempt") end
            end
            local provenance = entry.provenance
            if provenance then decoded.event_key = M.event_key(attempt_id, provenance) end
            local result = authority.commit_observation(tx, head, actor, source, decoded, context)
            if not result.ok then return result end
            local value = result.value :: {record_id: string, sequence: integer}
            if provenance and not result.replayed then
                local _, map_err = tx:execute("INSERT INTO bee_thread_carrier_events (thread_id, attempt_id, stream_id, envelope_index, event_index, source_first_sequence, source_last_sequence, record_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    {head.thread_id, attempt_id, provenance.stream_id, provenance.envelope_index, provenance.event_index, provenance.source_first_sequence, provenance.source_last_sequence, value.record_id})
                if map_err then return storage("record provenance") end
            end
            committed[index] = {record_id = value.record_id, sequence = value.sequence, replayed = result.replayed}
        end
        local next_revision = current.checkpoint_revision + 1
        local _, update_err = tx:execute("UPDATE bee_thread_carriers SET checkpoint_revision = ?, checkpoint_json = ?, updated_at = ? WHERE thread_id = ? AND attempt_id = ? AND carrier_epoch = ? AND checkpoint_revision = ?",
            {next_revision, checkpoint, transaction.now(), head.thread_id, attempt_id, epoch, current.checkpoint_revision})
        if update_err then return storage("store checkpoint") end
        return authority.remember(tx, actor, "carrier_commit", mutation, {attempt_id = attempt_id, carrier_epoch = epoch, checkpoint_revision = next_revision, records = committed})
    end)
end
-- checkpoint: what the last commit stored, for a carrier resuming.
function M.checkpoint(db: sql.DB, actor: string, request: unknown): Result
    local object, attempt_id, refused = named(request, {"thread_id", "attempt_id"})
    if not object or not attempt_id then return refused or failure("INVALID_ARGUMENT", "invalid request") end
    local thread_id = bounds.id(object.thread_id)
    if not thread_id then return failure("INVALID_ARGUMENT", "thread_id is not an identifier") end
    return transaction.read(db, function(tx: sql.Transaction): Result
        local head, member, denied = authority.membership(tx, thread_id, actor)
        if not head or not member then return denied or failure("DENIED", "caller is not a member of the thread") end
        local attempt, err = reader.attempt(tx, head.thread_id, attempt_id)
        if err then return storage(err) end
        if not attempt then return failure("NOT_FOUND", "attempt does not exist") end
        local current, current_err = stored(tx, head.thread_id, attempt_id)
        if current_err then return storage(current_err) end
        local value: {[string]: unknown} = current and view(current) or {carrier_epoch = 0, checkpoint_revision = 0, checkpoint = nil}
        value.attempt_id = attempt_id
        value.action_id = attempt.action_id
        value.attempt_state = attempt.state
        local open, open_err = reader.open_turn(tx, head.thread_id, attempt_id)
        if open_err then return storage(open_err) end
        value.open_turn_id = open and open.turn_id or nil
        return transaction.success(value, false)
    end)
end
return M
