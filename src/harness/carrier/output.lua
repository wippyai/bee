-- MIT. Carrier output framing, normalization and permission intake.
local json = require("json")
local permission = require("permission")
local bounds = require("bounds")
local canonical = require("canonical")
local provenance = require("provenance")
local checkpoint = require("checkpoint")
local stream_json = require("stream_json")
local driver_types = require("driver_types")
local placement_protocol = require("placement_protocol")
local placement_decode = require("placement_decode")
local record_types = require("record_types")
local observation_decode = require("observation_decode")
local carrier_types = require("carrier_types")
local permission_exchange = require("permission_exchange")
local part_planning = require("part_planning")
local M = {}
type Object = part_planning.Object
type IO = part_planning.IO
type Plan = part_planning.Plan
local must = part_planning.must
local digest_of = part_planning.digest_of
M.plan = part_planning.plan
M.CARRIER_OPS = "bee.threads.binding"
M.MAX_RECORDS_PER_COMMIT = 64
-- A frame may be as large as the chunks the runner holds unacknowledged; a
-- checkpoint carries only a partial frame up to checkpoint.MAX_CARRY_BYTES.
M.MAX_FRAME_BYTES = placement_protocol.MAX_OUTSTANDING_CHUNKS * placement_protocol.MAX_CHUNK_BYTES
M.APPROVALS = "bee.approvals.binding"
type OutputState = carrier_types.OutputState
type Session = carrier_types.Session
local function step(io: IO, name: string): ()
    if io.after then io.after(name) end
end
-- The durable states travel in the checkpoint so a replacement keeps what
-- was observed; unobserved and incomplete are conclusions, never stored
-- over an observation.
local function mark_output(session: Session, state: OutputState)
    session.output = state
    if state == "open" or state == "complete" or state == "truncated" then session.checkpoint.output = state end
end
-- commit: records and the current checkpoint in one thread transaction.
function M.commit(io: IO, session: Session, records: {{[string]: unknown}}): (boolean, string?)
    local value, err = must(io, M.CARRIER_OPS .. ":commit", {thread_id = session.plan.request.thread_id, idempotency_key = io.key(), attempt_id = session.plan.request.attempt_id,
        carrier_epoch = session.epoch, expected_revision = session.revision, checkpoint = session.checkpoint, records = records})
    if err then return false, err end
    local revision, decode_error = checkpoint.decode_commit(value, session.plan.request.attempt_id, session.epoch)
    if not revision then return false, "carrier commit returned an invalid revision: " .. tostring(decode_error) end
    session.revision = revision
    return true, nil
end
-- A provider may echo an entire tool input or result in one JSONL status
-- frame. Keep a bounded prefix, record one omission, then drain through the
-- newline. A checkpoint records the drain state for carrier replacement.
type FrameProblem = {index: integer, message: string, sample: string}
type FrameEnvelope = {index: integer, value: {[string]: unknown}}
local function feed_stdout(session: Session, chunk: string, exhausted: boolean): ({FrameEnvelope}, {FrameProblem}, string?)
    local data = chunk
    if session.dropping_stdout then
        local newline = data:find("\n", 1, true)
        if not newline then return {}, {}, nil end
        data = data:sub(newline + 1)
        session.dropping_stdout = false
    end
    local newline = data:find("\n", 1, true)
    local first_length = #session.decoder.framer.carry + (newline or (#data + 1)) - 1
    if first_length > M.MAX_FRAME_BYTES
        or (exhausted and not newline and first_length > checkpoint.MAX_CARRY_BYTES) then
        session.decoder.framer.carry = ""
        session.decoder.index = session.decoder.index + 1
        local problem: FrameProblem = {index = session.decoder.index,
            message = "oversized frame omitted after the bounded runner window", sample = ""}
        if not newline then
            session.dropping_stdout = true
            return {}, {problem}, nil
        end
        local envelopes, rest, feed_error = stream_json.feed(session.decoder, data:sub(newline + 1))
        table.insert(rest, 1, problem)
        return envelopes, rest, feed_error
    end
    local envelopes, problems, feed_error = stream_json.feed(session.decoder, data)
    return envelopes, problems, feed_error
end
-- Every placement operation is selected once in the measured plan. Persisted
-- and admitted plans always carry the concrete binding and its targets.
function M.placement_target(plan: Plan, method: string): string?
    return plan.placement_binding.methods[method]
end
-- attach_action: a fresh sequential attempt on an action an earlier attempt
-- already admitted. The admit call reports the action exists; this verifies
-- the existing action is the requester's own and discovers its latest
-- settled attempt to chain, so two starters cannot prepare concurrently.
-- Anything unverified fails closed with the admit refusal. The owner still
-- enforces the chain, the open thread and the single live attempt.
local function snapshot_object(value: unknown, label: string, maximum: integer): (Object?, string?)
    if value == nil then return nil, nil end
    local object = bounds.object(value)
    if not object then return nil, label .. " must be an object" end
    local encoded, encode_error = canonical.encode(object)
    if not encoded then return nil, label .. " is not valid JSON: " .. tostring(encode_error) end
    if #encoded > maximum then return nil, label .. " exceeds " .. tostring(maximum) .. " bytes" end
    local decoded, decode_error = json.decode(encoded)
    if decode_error then return nil, label .. " could not be copied: " .. tostring(decode_error) end
    local copied = bounds.object(decoded)
    if not copied then return nil, label .. " did not decode as an object" end
    return copied, nil
end
local function snapshot_state(value: unknown): (Object?, string?)
    if value == nil then return nil, nil end
    local state, state_error = checkpoint.normalizer_state(value)
    if not state then return nil, state_error end
    return snapshot_object(state, "normalizer_state", checkpoint.MAX_NORMALIZER_STATE_BYTES)
end
local function snapshot_terminal(value: driver_types.Terminal?): (driver_types.Terminal?, string?)
    if value == nil then return nil, nil end
    local copied, copy_error = snapshot_object(value, "terminal", checkpoint.MAX_TERMINAL_BYTES)
    if not copied then return nil, copy_error end
    return checkpoint.decode_terminal(copied)
end
type Normalized = {state: Object, observations: {record_types.Observation}, terminal: driver_types.Terminal?, writes: {string}}
local function decode_normalized(value: unknown): (Normalized?, string?)
    local object = bounds.object(value)
    if not object then return nil, "reply must be an object" end
    local unknown_field = bounds.fields(object, {"ok", "error", "state", "observations", "terminal", "writes"})
    if unknown_field then return nil, "reply: " .. unknown_field end
    if object.ok == false then
        if object.state ~= nil or object.observations ~= nil or object.terminal ~= nil or object.writes ~= nil then return nil, "failed reply carries successful result fields" end
        local message = bounds.text(object.error, 4096)
        if not message or message == "" then return nil, "failure has no bounded error" end
        return nil, message
    end
    if object.ok ~= true or object.error ~= nil then return nil, "reply status is invalid" end
    if object.state == nil then return nil, "successful reply has no normalizer state" end
    local state, state_error = checkpoint.normalizer_state(object.state)
    if not state then return nil, "normalizer state: " .. tostring(state_error) end
    local raw_observations, array_error = bounds.array(object.observations, bounds.MAX_ARRAY_ITEMS)
    if not raw_observations then return nil, "normalizer observations must be a bounded dense list: " .. tostring(array_error) end
    local observations: {record_types.Observation} = {}
    for index, raw in ipairs(raw_observations) do
        local item, observation_error = observation_decode.decode(raw)
        if not item then return nil, "normalizer observations[" .. tostring(index) .. "]: " .. tostring(observation_error) end
        observations[index] = item
    end
    local terminal: driver_types.Terminal? = nil
    if object.terminal ~= nil then
        terminal, state_error = checkpoint.decode_terminal(object.terminal)
        if not terminal then return nil, "normalizer terminal: " .. tostring(state_error) end
    end
    local raw_writes, writes_error = bounds.array(object.writes or {}, checkpoint.MAX_PENDING_WRITES)
    if not raw_writes then return nil, "normalizer writes: " .. tostring(writes_error) end
    local writes: {string} = {}
    for _, raw_write in ipairs(raw_writes) do
        local line = bounds.text(raw_write, checkpoint.MAX_PENDING_WRITE_BYTES)
        if not line or line == "" then return nil, "normalizer write is not bounded text" end
        writes[#writes + 1] = line
    end
    if terminal and #writes > 0 then return nil, "terminal normalizer result carries writes" end
    return {state = state, observations = observations, terminal = terminal, writes = writes}, nil
end
local function normalize(io: IO, session: Session, index: integer, envelope: {[string]: unknown}?, eof: boolean): ({record_types.Observation}?, driver_types.Terminal?, string?, {string}?)
    local input: Object = {state = session.normalizer, index = index, envelope = envelope, eof = eof, resumed = false}
    if session.plan.exchange and session.plan.exchange.transport == "stdio" then
        input.context = {permission_exchange = true, brief = session.plan.request.brief, resume_ref = session.plan.resume_ref,
            options = session.plan.policy.prepare_options}
    end
    local reply, err = io.call(session.plan.normalize_target, input)
    if err then return nil, nil, "driver normalize: " .. err end
    local result, decode_error = decode_normalized(reply)
    if not result then return nil, nil, "driver normalize: " .. tostring(decode_error) end
    session.normalizer = result.state
    return result.observations, result.terminal, nil, result.writes
end
local function from_runner(session: Session, sender: string, generation: integer): boolean
    return session.runner ~= nil and sender == session.runner and generation == session.epoch
end
-- Permission exchange. Every key is derived once from owner, attempt and
-- the request's event key and kept in the checkpoint; the thread carries
-- one control record per phase under a deterministic key.
local function acknowledged_through(session: Session, sequence: integer): integer
    local held = session.held_from
    if held and held - 1 < sequence then return held - 1 end
    return sequence
end
local function revalidate_permission(io: IO, session: Session): string?
    local exchange = session.plan.exchange
    if not exchange then return "permission exchange no longer enabled" end
    if session.terminal or session.settled or not session.runner then return "attempt no longer waiting" end
    local recorded = session.checkpoint.plan_digest
    if not recorded then return "the checkpoint records no plan digest" end
    local fresh, plan_error = M.plan(io, session.plan.request)
    if not fresh then return "measurements unavailable: " .. tostring(plan_error) end
    if fresh.exchange_refusal then return fresh.exchange_refusal end
    if fresh.plan_digest ~= recorded then return "plan measurements changed since the checkpoint" end
    local current = fresh.exchange
    if not current then return "permission exchange no longer enabled" end
    if current.adapter.digest ~= exchange.adapter.digest then return "permission adapter changed" end
    if current.acceptance_digest ~= exchange.acceptance_digest then return "acceptance record changed" end
    for _, state in ipairs(session.checkpoint.permissions) do
        local found: permission.Request = {permission_request_id = state.permission_request_id, correlation_id = state.correlation_id,
            acknowledgment_id = state.acknowledgment_id or state.correlation_id, tool_name = state.tool_name,
            input_digest = state.input_digest, input = {}, prompt = state.prompt}
        local proposal_digest = digest_of(permission.proposal(exchange.adapter, {action_id = session.plan.request.action_id,
            attempt_id = session.plan.request.attempt_id, plan_digest = session.plan.plan_digest}, found))
        if proposal_digest ~= state.proposal_digest then return "proposal no longer digests as recorded" end
    end
    local reconcile_target = M.placement_target(session.plan, "reconcile")
    if not reconcile_target then return "selected placement binds no reconcile" end
    local reconciled, reconcile_error = must(io, reconcile_target, {attempt_id = session.plan.request.attempt_id})
    if reconcile_error then return "placement reconcile: " .. reconcile_error end
    local attempt, attempt_decode_error = placement_decode.attempt(reconciled)
    if not attempt then return "placement reconcile returned an invalid attempt: " .. tostring(attempt_decode_error) end
    if attempt.execution_state ~= "running" then return "placement is " .. tostring(attempt.execution_state) .. " under its grants and projections" end
    return nil
end
local function permission_context(io: IO, session: Session): permission_exchange.Context
    return {state = {binding_id = session.checkpoint.gateway_binding, request = session.plan.request, plan_digest = session.plan.plan_digest, exchange = session.plan.exchange,
            permissions = session.checkpoint.permissions, epoch = session.epoch, turn_id = session.turn_open and session.turn_id or nil},
        now_ms = io.now_ms, approvals = M.APPROVALS, max_consume_attempts = permission_exchange.MAX_CONSUME_ATTEMPTS,
        commit = function(records: {Object}): (boolean, string?) return M.commit(io, session, records) end,
        call = io.call, digest_of = digest_of,
        step = function(name: string) step(io, name) end,
        write = function(write_id: string, line: string): (boolean, string?)
            if session.plan.exchange and session.plan.exchange.transport == "hook_http" then
                return M.commit(io, session, {{source = "bee", body = {type = "extension", event_key = "write:" .. write_id .. ":prepared",
                    data = {type = "extension", event_name = "bee.carrier.write", event_revision = "1",
                        payload_json = canonical.encode({write_id = write_id, phase = "prepared", delivery = "hook", acknowledgment = "unproven"})}}}})
            end
            return M.write(io, session, write_id, line)
        end,
        revalidate = function(): string? return revalidate_permission(io, session) end,
        recovered = session.recovered,
        waiting = function(): boolean return not session.terminal and not session.eof.stdout and session.runner ~= nil end,
        settled = function(): boolean return session.settled ~= nil or session.terminal ~= nil end}
end
function M.on_output(io: IO, session: Session, sender: string, message: placement_protocol.Output, max_records_per_commit: integer): (boolean, string?)
    if not from_runner(session, sender, message.generation) then return true, nil end
    if message.sequence <= session.last_sequence[message.stream] then
        if message.eof and not session.eof[message.stream] then
            session.eof[message.stream] = true
            if message.truncated then mark_output(session, "truncated")
            elseif session.eof.stdout and session.eof.stderr and session.output == "open" then mark_output(session, "complete") end
            local committed, commit_error = M.commit(io, session, {})
            if not committed then return false, commit_error end
            step(io, message.stream .. "_ended")
        end
        io.send(sender, placement_protocol.TOPIC_ACK, {generation = session.epoch, consumed_through = acknowledged_through(session, message.sequence)})
        return true, nil
    end
    local protocol_writes: {checkpoint.PendingWrite} = {}
    local protocol_records: {Object} = {}
    local prior_writes = #session.checkpoint.pending_writes
    local before_state, before_state_error = snapshot_state(session.normalizer)
    if session.normalizer ~= nil and before_state == nil then return false, "normalizer state cannot be checkpointed: " .. tostring(before_state_error) end
    local before_terminal, before_terminal_error = snapshot_terminal(session.terminal)
    if session.terminal ~= nil and before_terminal == nil then return false, "terminal cannot be checkpointed: " .. tostring(before_terminal_error) end
    local was_held = session.held_from ~= nil
    local before = {carry = session.decoder.framer.carry, index = session.decoder.index, state = before_state,
        terminal = before_terminal, stream_ended = session.stream_ended, dropping_stdout = session.dropping_stdout,
        output = session.output, checkpoint_output = session.checkpoint.output, eof_stdout = session.eof.stdout,
        eof_stderr = session.eof.stderr, held_from = session.held_from, stderr_sequence = session.stderr_sequence}
    local function refuse(reason: string): (boolean, string?)
        session.decoder.framer.carry = before.carry
        session.decoder.index = before.index
        session.normalizer = before.state
        session.terminal = before.terminal
        session.stream_ended = before.stream_ended
        session.dropping_stdout = before.dropping_stdout
        session.output = before.output
        session.checkpoint.output = before.checkpoint_output
        session.eof.stdout = before.eof_stdout
        session.eof.stderr = before.eof_stderr
        session.held_from = before.held_from
        session.stderr_sequence = before.stderr_sequence
        while #session.checkpoint.pending_writes > prior_writes do table.remove(session.checkpoint.pending_writes) end
        return false, reason
    end
    local records: {{[string]: unknown}} = {}
    local consumed = acknowledged_through(session, math.max(session.checkpoint.consumed.stdout, session.checkpoint.consumed.stderr))
    local exhausted = message.sequence - consumed >= placement_protocol.MAX_OUTSTANDING_CHUNKS
    if message.stream ~= "stdout" and exhausted and #session.decoder.framer.carry > checkpoint.MAX_CARRY_BYTES then
        local _, problems = feed_stdout(session, "", true)
        for _, problem in ipairs(problems) do
            records[#records + 1] = {source = "stream", provenance = {schema_revision = provenance.REVISION, stream_id = "stdout", source_first_sequence = session.checkpoint.consumed.stdout + 1,
                source_last_sequence = session.last_sequence.stdout, envelope_index = problem.index, event_index = 0},
                body = {type = "notice", event_key = "ignored", data = {type = "notice", level = "warning", code = "oversized_frame", content = {text = problem.message}}}}
        end
    end
    if message.eof then
        session.eof[message.stream] = true
        if message.truncated then
            mark_output(session, "truncated")
            local truncation: {[string]: unknown} = {source = "bee", body = {type = "extension", event_key = "output:" .. session.plan.request.attempt_id .. ":" .. message.stream .. ":truncated",
                data = {type = "extension", event_name = "bee.carrier.output", event_revision = "1", payload_json = json.encode({attempt_id = session.plan.request.attempt_id, stream = message.stream, state = "truncated", attachment_generation = session.epoch})}}}
            records[#records + 1] = truncation
        elseif session.eof.stdout and session.eof.stderr and session.output == "open" then
            mark_output(session, "complete")
        end
        if message.stream == "stdout" then
            local observations, terminal, err = normalize(io, session, session.decoder.index + 1, nil, true)
            if not observations then return refuse(err or "driver normalize failed") end
            for event_index, item in ipairs(observations) do
                records[#records + 1] = {source = "stream", provenance = {schema_revision = provenance.REVISION, stream_id = "stdout", source_first_sequence = message.sequence,
                    source_last_sequence = message.sequence, envelope_index = session.decoder.index + 1, event_index = event_index - 1}, body = item}
            end
            if terminal and not session.terminal then
                session.terminal = terminal
                session.stream_ended = true
            end
        end
    elseif message.stream == "stdout" then
        -- The runner stops sending once its unacknowledged window is full.
        -- Count from the last durable acknowledgment, not from the chunk
        -- where the partial frame first exceeded the checkpoint carry. The
        -- runner cannot send chunk 17 until all 16 unacknowledged chunks move.
        local envelopes, problems, framing_error = feed_stdout(session, message.data or "", exhausted)
        if framing_error then
            local fault = {source = "stream", provenance = {schema_revision = provenance.REVISION, stream_id = "stdout", source_first_sequence = message.sequence, source_last_sequence = message.sequence,
                envelope_index = session.decoder.index + 1, event_index = 0}, body = {type = "notice", event_key = "ignored", data = {type = "notice", level = "error", code = "framing", content = {text = framing_error}}}}
            session.terminal = {outcome = "uncertain", answer = nil, resume_ref = nil, usage = nil, error = {code = "framing", message = framing_error, retryable = false}}
            records[#records + 1] = fault
        else
            for _, problem in ipairs(problems) do
                local code = problem.message:find("oversized frame omitted", 1, true) and "oversized_frame" or "undecodable_frame"
                records[#records + 1] = {source = "stream", provenance = {schema_revision = provenance.REVISION, stream_id = "stdout", source_first_sequence = message.sequence, source_last_sequence = message.sequence,
                    envelope_index = problem.index, event_index = 0}, body = {type = "notice", event_key = "ignored", data = {type = "notice", level = "warning", code = code, content = {text = problem.message}}}}
            end
            for _, envelope in ipairs(envelopes) do
                local observations, terminal, err, writes = normalize(io, session, envelope.index, envelope.value, false)
                if not observations then return refuse(err or "driver normalize failed") end
                for event_index, item in ipairs(observations) do
                    records[#records + 1] = {source = "stream", provenance = {schema_revision = provenance.REVISION, stream_id = "stdout", source_first_sequence = message.sequence,
                        source_last_sequence = message.sequence, envelope_index = envelope.index, event_index = event_index - 1}, body = item}
                end
                if terminal and not session.terminal then session.terminal = terminal end
                for write_index, line in ipairs(writes or {}) do
                    if not session.plan.exchange or session.plan.exchange.transport ~= "stdio" or session.plan.launch.stdin_eof == true then
                        return refuse("normalizer writes require an admitted duplex channel")
                    end
                    local write_id = "protocol:" .. tostring(envelope.index) .. ":" .. tostring(write_index)
                    local digest = assert(digest_of(line))
                    local existing: checkpoint.PendingWrite? = nil
                    for _, item in ipairs(session.checkpoint.pending_writes) do
                        if item.write_id == write_id then existing = item end
                    end
                    if existing and (existing.input_digest ~= digest or existing.data ~= line) then return refuse("protocol write identity changed on replay") end
                    if not existing then
                        if #session.checkpoint.pending_writes + #protocol_writes >= checkpoint.MAX_PENDING_WRITES then return refuse("too many protocol writes await acknowledgment") end
                        local pending: checkpoint.PendingWrite = {write_id = write_id, input_digest = digest, data = line, dispatched = false}
                        protocol_writes[#protocol_writes + 1] = pending
                    end
                    protocol_records[#protocol_records + 1] = {source = "bee", body = {type = "extension", event_key = "write:" .. write_id .. ":intended",
                        data = {type = "extension", event_name = "bee.carrier.write", event_revision = "1",
                            payload_json = canonical.encode({write_id = write_id, input_digest = digest, phase = "intended"})}}}
                end
            end
        end
    else
        session.stderr_sequence = session.stderr_sequence + 1
        records[#records + 1] = {source = "stream", provenance = {schema_revision = provenance.REVISION, stream_id = "stderr", source_first_sequence = message.sequence, source_last_sequence = message.sequence,
            envelope_index = message.sequence, event_index = 0}, body = {type = "notice", event_key = "ignored", data = {type = "notice", level = "info", code = "stderr", content = {text = message.data or ""}}}}
    end
    if session.turn_open then
        for _, record in ipairs(records) do record.turn_id = session.turn_id end
    end
    if #session.decoder.framer.carry <= checkpoint.MAX_CARRY_BYTES then
        session.held_from = nil
    elseif message.stream == "stdout" then
        session.held_from = session.held_from or message.sequence
    end
    -- Only a boundary whose partial frame fits the checkpoint moves the
    -- stdout position; records committed beyond it replay idempotently from
    -- the chunks the runner still holds.
    local at_boundary = session.held_from == nil
    if #protocol_writes > 0 and not at_boundary then return refuse("protocol input requires a complete checkpoint boundary") end
    local detected, detect_error = permission_exchange.detect(permission_context(io, session), records)
    if detect_error then return refuse(detect_error) end
    permission_exchange.acknowledge(permission_context(io, session), records)
    local total = #records
    local offset = 0
    while true do
        local batch: {{[string]: unknown}} = {}
        local batch_limit = max_records_per_commit - #protocol_records
        for index = offset + 1, math.min(offset + batch_limit, total) do batch[#batch + 1] = records[index] end
        local observations_in_batch = #batch
        local final = offset + observations_in_batch >= total
        if final then
            for _, record in ipairs(protocol_records) do batch[#batch + 1] = record end
            for _, pending in ipairs(protocol_writes) do session.checkpoint.pending_writes[#session.checkpoint.pending_writes + 1] = pending end
        end
        if final and at_boundary then
            local state, state_error = snapshot_state(session.normalizer)
            if session.normalizer ~= nil and state == nil then return refuse("normalizer state cannot be checkpointed: " .. tostring(state_error)) end
            local terminal, terminal_error = snapshot_terminal(session.terminal)
            if session.terminal ~= nil and terminal == nil then return refuse("terminal cannot be checkpointed: " .. tostring(terminal_error)) end
            session.checkpoint.consumed[message.stream] = message.sequence
            session.checkpoint.carry.stdout = session.decoder.framer.carry
            session.checkpoint.dropping_stdout = session.dropping_stdout
            session.checkpoint.envelope_index = session.decoder.index
            session.checkpoint.normalizer_state = state
            session.checkpoint.event_cursor = nil
            session.checkpoint.terminal = terminal
            session.checkpoint.stream_ended = session.stream_ended
        elseif final and message.stream == "stderr" then
            session.checkpoint.consumed.stderr = message.sequence
        elseif not final and not was_held and at_boundary then
            session.checkpoint.carry.stdout = before.carry
            session.checkpoint.dropping_stdout = before.dropping_stdout
            session.checkpoint.envelope_index = before.index
            session.checkpoint.normalizer_state = before.state
            session.checkpoint.event_cursor = {envelope_index = before.index + 1, events_committed = offset + #batch}
        end
        local committed, commit_error = M.commit(io, session, batch)
        if not committed then return false, commit_error end
        if final then break end
        offset = offset + observations_in_batch
        step(io, "partial_commit")
    end
    if #protocol_writes > 0 then step(io, "protocol_prepared") end
    for _, pending in ipairs(protocol_writes) do
        io.send(sender, placement_protocol.TOPIC_INPUT, {write_id = pending.write_id, generation = session.epoch, data = pending.data})
        pending.dispatched = true
    end
    session.last_sequence[message.stream] = message.sequence
    step(io, "committed")
    if message.eof then step(io, message.stream .. "_ended") end
    if detected > 0 then step(io, "permission_intended") end
    io.send(sender, placement_protocol.TOPIC_ACK, {generation = session.epoch, consumed_through = acknowledged_through(session, message.sequence)})
    step(io, "acknowledged")
    return true, nil
end
local function control_record(session: Session, write_id: string, phase: string, extra: {[string]: unknown}): {[string]: unknown}
    local payload: {[string]: unknown} = {write_id = write_id, attempt_id = session.plan.request.attempt_id, turn_id = session.turn_id, attachment_generation = session.epoch, phase = phase}
    for key, value in pairs(extra) do payload[key] = value end
    return {source = "bee", body = {type = "extension", event_key = "write:" .. write_id .. ":" .. phase, data = {type = "extension", event_name = "bee.carrier.write", event_revision = "1", payload_json = json.encode(payload)}}}
end
local function forget_write(session: Session, write_id: string)
    local kept: {checkpoint.PendingWrite} = {}
    for _, pending in ipairs(session.checkpoint.pending_writes) do
        if pending.write_id ~= write_id then kept[#kept + 1] = pending end
    end
    session.checkpoint.pending_writes = kept
end
-- write: intent is committed with the write held in the checkpoint before
-- any dispatch; acceptance or uncertainty is committed after. A write is
-- refused once the runner is not bound or the intent cannot be committed,
-- so a fenced carrier never dispatches.
function M.write(io: IO, session: Session, write_id: string, data: string): (boolean, string?)
    if not session.runner then return false, "no runner is bound" end
    if session.plan.launch.stdin_eof == true then
        -- The launch closed stdin after its initial input; a later write is
        -- refused on record rather than dispatched or dropped silently.
        local digest = digest_of(data) or ""
        return M.commit(io, session, {control_record(session, write_id, "refused", {input_digest = digest, reason = "stdin closed after the initial input"})})
    end
    if session.checkpoint.input_closed then
        local digest = digest_of(data) or ""
        return M.commit(io, session, {control_record(session, write_id, "refused", {input_digest = digest, reason = "stdin closed after settlement"})})
    end
    if #data > checkpoint.MAX_PENDING_WRITE_BYTES then return false, "write exceeds " .. tostring(checkpoint.MAX_PENDING_WRITE_BYTES) .. " bytes" end
    if #session.checkpoint.pending_writes >= checkpoint.MAX_PENDING_WRITES then return false, "too many writes await acknowledgment" end
    local digest, digest_error = digest_of(data)
    if not digest then return false, digest_error end
    local pending: checkpoint.PendingWrite = {write_id = write_id, input_digest = digest, data = data, dispatched = false}
    session.checkpoint.pending_writes[#session.checkpoint.pending_writes + 1] = pending
    local intended, intended_error = M.commit(io, session, {control_record(session, write_id, "intended", {input_digest = digest})})
    if not intended then
        forget_write(session, write_id)
        return false, intended_error
    end
    step(io, "write_intended")
    local runner = session.runner
    if not runner then return false, "no runner is bound" end
    io.send(runner, placement_protocol.TOPIC_INPUT, {write_id = write_id, generation = session.epoch, data = data})
    pending.dispatched = true
    step(io, "write_dispatched")
    return true, nil
end
M.must = must
M.digest_of = digest_of
M.step = step
M.mark_output = mark_output
M.feed_stdout = feed_stdout
M.snapshot_object = snapshot_object
M.snapshot_state = snapshot_state
M.snapshot_terminal = snapshot_terminal
M.decode_normalized = decode_normalized
M.normalize = normalize
M.from_runner = from_runner
M.acknowledged_through = acknowledged_through
M.revalidate_permission = revalidate_permission
M.permission_context = permission_context
M.control_record = control_record
M.forget_write = forget_write
return M
