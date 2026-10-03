-- MIT. Messages between the service, the runner and the bound recipient.
-- Output and input carry separate sequence spaces; acknowledgments name
-- what they consumed or accepted; EOF and exit are separate from chunks.
local M = {}
local bounds = require("bounds")
M.TOPIC_CONTROL = "bee.placement.control"
M.TOPIC_INPUT = "bee.placement.input"
M.TOPIC_ACK = "bee.placement.ack"
M.TOPIC_OUTPUT = "bee.placement.output"
M.TOPIC_EXIT = "bee.placement.exit"
M.TOPIC_STARTED = "bee.placement.started"
M.TOPIC_ATTACHED = "bee.placement.attached"
M.TOPIC_WRITE_STATUS = "bee.placement.write_status"
M.TOPIC_FENCED = "bee.placement.fenced"
M.TOPIC_STATUS = "bee.placement.status"
M.TOPIC_STDIN = "bee.placement.stdin"
M.FENCE_TIMEOUT_MS = 2000
-- How long a runner keeps a lost carrier's gateway binding alive for a
-- replacement to take over; past it the binding is retired.
M.TAKEOVER_GRACE_MS = 3000
M.MAX_CHUNK_BYTES = 16384
M.MAX_WRITE_BYTES = 65536
M.MAX_OUTSTANDING_CHUNKS = 16
M.MAX_SPOOL_BYTES = 262144
M.MAX_REMEMBERED_WRITES = 256
type Control = {control_token: string, command: "stop", mode: "cooperative" | "forced", grace_ms: integer} | {control_token: string, command: "attach", recipient: string, generation: integer} | {control_token: string, command: "detach", generation: integer} | {control_token: string, command: "write_status", write_id: string} | {control_token: string, command: "status", attempt_id: string, probe: string} | {control_token: string, command: "close_stdin", attempt_id: string, probe: string}
-- What the runner itself observes: supervision evidence, never exit or
-- cleanup proof. The reply echoes the probe that asked.
type Execution = "starting" | "running" | "stopping" | "exited"
type RunnerStatus = {attempt_id: string, generation: integer, probe: string, execution: Execution, exit_code: integer?, eof_seen: integer, pending_outputs: integer, remembered_writes: integer, truncated: boolean}
type StatusProbe = {runner: string, attempt_id: string, generation: integer, probe: string}
-- The runner's answer to the owner's stdin closure after settlement:
-- closed, or why not; evidence carries the same fact.
type StdinReply = {attempt_id: string, generation: integer, probe: string, closed: boolean, reason: string?}
type Attached = {attempt_id: string, generation: integer}
-- State notifications are hints; recipients read the authenticated owner value.
function M.decode_state_hint(raw: unknown): Attached?
    local value = bounds.object(raw)
    if not value or bounds.fields(value, {"attempt_id", "generation"}) then return nil end
    local attempt_id, generation = bounds.id(value.attempt_id), bounds.count(value.generation)
    if not attempt_id or generation == nil then return nil end
    return {attempt_id = attempt_id, generation = generation}
end
type Fenced = {attempt_id: string, generation: integer, fenced: boolean}
type WriteStatus = {attempt_id: string, generation: integer, write_id: string, status: "accepted" | "unknown"}
type Input = {write_id: string, generation: integer, data: string}
type Ack = {generation: integer, consumed_through: integer}
-- An eof marked truncated ends a stream the runner closed at the drain
-- deadline: forced truncation, not observed end of output.
type Output = {attempt_id: string, generation: integer, stream: "stdout" | "stderr", sequence: integer, data: string?, eof: boolean, truncated: boolean?}
type InputAck = {attempt_id: string, generation: integer, write_id: string, accepted: boolean, reason: string?}
-- stopped: the child ended after a stop its placement was asked for.
type Exit = {attempt_id: string, generation: integer, code: integer?, signal: integer?, uncertain: boolean, stopped: boolean?}
function M.decode_exit(raw: unknown): Exit?
    local value = bounds.object(raw)
    if not value then return nil end
    local attempt_id, generation = bounds.id(value.attempt_id), bounds.count(value.generation)
    if not attempt_id or not generation then return nil end
    local code: integer? = nil
    if value.code ~= nil then
        code = bounds.integer(value.code)
        if not code then return nil end
    end
    local signal: integer? = nil
    if value.signal ~= nil then
        signal = bounds.integer(value.signal)
        if not signal then return nil end
    end
    local uncertain = value.uncertain
    if type(uncertain) ~= "boolean" then return nil end
    local stopped = value.stopped
    if stopped ~= nil and type(stopped) ~= "boolean" then return nil end
    return {attempt_id = attempt_id, generation = generation, code = code, signal = signal, uncertain = uncertain, stopped = stopped}
end
function M.decode_output(raw: unknown): Output?
    local value = bounds.object(raw)
    if not value then return nil end
    local attempt_id, generation = bounds.id(value.attempt_id), bounds.count(value.generation)
    if not attempt_id or not generation then return nil end
    local stream = value.stream
    if stream ~= "stdout" and stream ~= "stderr" then return nil end
    local sequence = bounds.count(value.sequence)
    if not sequence then return nil end
    local data = value.data
    if data ~= nil and type(data) ~= "string" then return nil end
    local eof = value.eof
    if type(eof) ~= "boolean" then return nil end
    local truncated = value.truncated
    if truncated ~= nil and type(truncated) ~= "boolean" then return nil end
    return {attempt_id = attempt_id, generation = generation, stream = stream, sequence = sequence, data = data, eof = eof, truncated = truncated}
end
function M.decode_input_ack(raw: unknown): InputAck?
    local value = bounds.object(raw)
    if not value then return nil end
    local attempt_id, generation = bounds.id(value.attempt_id), bounds.count(value.generation)
    if not attempt_id or not generation then return nil end
    local write_id = bounds.id(value.write_id)
    if not write_id then return nil end
    local accepted = value.accepted
    if type(accepted) ~= "boolean" then return nil end
    local reason = value.reason
    if reason ~= nil and type(reason) ~= "string" then return nil end
    return {attempt_id = attempt_id, generation = generation, write_id = write_id, accepted = accepted, reason = reason}
end
function M.decode_write_status(raw: unknown): WriteStatus?
    local value = bounds.object(raw)
    if not value then return nil end
    local attempt_id, generation = bounds.id(value.attempt_id), bounds.count(value.generation)
    if not attempt_id or not generation then return nil end
    local write_id = bounds.id(value.write_id)
    if not write_id then return nil end
    local status = value.status
    if status ~= "accepted" and status ~= "unknown" then return nil end
    return {attempt_id = attempt_id, generation = generation, write_id = write_id, status = status}
end
-- A status reply counts only from the placement-recorded runner, for the
-- attempt and attachment generation the service holds, answering the
-- probe it sent; anything else is unauthenticated traffic.
function M.stdin_reply_accepted(sender: string, reply: unknown, expected: StatusProbe): (StdinReply?, string?)
    if sender ~= expected.runner then return nil, "reply from " .. sender .. ", not the recorded runner" end
    local object = bounds.object(reply)
    if not object then return nil, "reply is not an object" end
    local unknown_field = bounds.fields(object, {"attempt_id", "generation", "probe", "closed", "reason"})
    if unknown_field then return nil, "reply: " .. unknown_field end
    local attempt_id, generation, probe = bounds.id(object.attempt_id), bounds.integer(object.generation), bounds.id(object.probe)
    if attempt_id == nil or generation == nil or probe == nil then return nil, "reply identity is invalid" end
    if attempt_id ~= expected.attempt_id then return nil, "reply names another attempt" end
    if generation ~= expected.generation then
        return nil, "reply names generation " .. tostring(generation) .. ", not " .. tostring(expected.generation)
    end
    if probe ~= expected.probe then return nil, "reply answers another probe" end
    local closed = object.closed
    if type(closed) ~= "boolean" then return nil, "reply does not say whether stdin closed" end
    local reason: string? = nil
    if object.reason ~= nil then
        reason = bounds.text(object.reason, 4096)
        if not reason then return nil, "reply reason is invalid" end
    end
    if closed == true and reason ~= nil then return nil, "closed reply carries a reason" end
    if closed == false and (not reason or reason == "") then return nil, "refused reply has no reason" end
    return {attempt_id = attempt_id, generation = generation, probe = probe, closed = closed, reason = reason}, nil
end
function M.status_reply_accepted(sender: string, reply: unknown, expected: StatusProbe): (RunnerStatus?, string?)
    if sender ~= expected.runner then return nil, "reply from " .. sender .. ", not the recorded runner" end
    local object = bounds.object(reply)
    if not object then return nil, "reply is not an object" end
    local unknown_field = bounds.fields(object, {"attempt_id", "generation", "probe", "execution", "exit_code", "eof_seen", "pending_outputs", "remembered_writes", "truncated"})
    if unknown_field then return nil, "reply: " .. unknown_field end
    local attempt_id, generation, probe = bounds.id(object.attempt_id), bounds.integer(object.generation), bounds.id(object.probe)
    if attempt_id == nil or generation == nil or probe == nil then return nil, "reply identity is invalid" end
    if attempt_id ~= expected.attempt_id then return nil, "reply names another attempt" end
    if generation ~= expected.generation then
        return nil, "reply names generation " .. tostring(generation) .. ", not " .. tostring(expected.generation)
    end
    if probe ~= expected.probe then return nil, "reply answers another probe" end
    local execution: Execution? = nil
    if object.execution == "starting" then execution = "starting"
    elseif object.execution == "running" then execution = "running"
    elseif object.execution == "stopping" then execution = "stopping"
    elseif object.execution == "exited" then execution = "exited" end
    if execution == nil then return nil, "reply reports an unknown execution" end
    local exit_code: integer? = nil
    if object.exit_code ~= nil then
        exit_code = bounds.integer(object.exit_code)
        if exit_code == nil then return nil, "reply exit_code is invalid" end
    end
    local eof_seen = bounds.count(object.eof_seen)
    local pending_outputs = bounds.count(object.pending_outputs)
    local remembered_writes = bounds.count(object.remembered_writes)
    if eof_seen == nil or pending_outputs == nil or remembered_writes == nil then return nil, "reply counters are outside their bounds" end
    if eof_seen > 2 or pending_outputs > M.MAX_OUTSTANDING_CHUNKS or remembered_writes > M.MAX_REMEMBERED_WRITES then
        return nil, "reply counters are outside their bounds"
    end
    if type(object.truncated) ~= "boolean" then return nil, "reply truncated flag is invalid" end
    return {attempt_id = attempt_id, generation = generation, probe = probe, execution = execution, exit_code = exit_code,
        eof_seen = eof_seen, pending_outputs = pending_outputs, remembered_writes = remembered_writes, truncated = object.truncated}, nil
end
return M
