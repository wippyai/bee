-- MIT. Messages between the service, the runner and the bound recipient.
-- Output and input carry separate sequence spaces; acknowledgments name
-- what they consumed or accepted; EOF and exit are separate from chunks.
local M = {}
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
type Control = {command: "stop", mode: "cooperative" | "forced", grace_ms: integer} | {command: "attach", recipient: string, generation: integer} | {command: "detach", generation: integer} | {command: "write_status", write_id: string} | {command: "status", attempt_id: string, probe: string} | {command: "close_stdin", attempt_id: string, probe: string}
-- What the runner itself observes: supervision evidence, never exit or
-- cleanup proof. The reply echoes the probe that asked.
type RunnerStatus = {attempt_id: string, generation: integer, probe: string, execution: "starting" | "running" | "stopping" | "exited", exit_code: integer?, eof_seen: integer, pending_outputs: integer, remembered_writes: integer, truncated: boolean}
type StatusProbe = {runner: string, attempt_id: string, generation: integer, probe: string}
-- The runner's answer to the owner's stdin closure after settlement:
-- closed, or why not; evidence carries the same fact.
type StdinReply = {attempt_id: string, generation: integer, probe: string, closed: boolean, reason: string?}
type Attached = {attempt_id: string, generation: integer}
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
-- A status reply counts only from the placement-recorded runner, for the
-- attempt and attachment generation the service holds, answering the
-- probe it sent; anything else is unauthenticated traffic.
function M.stdin_reply_accepted(sender: string, reply: unknown, expected: StatusProbe): (StdinReply?, string?)
    if sender ~= expected.runner then return nil, "reply from " .. sender .. ", not the recorded runner" end
    if type(reply) ~= "table" then return nil, "reply is not an object" end
    local answer = reply :: StdinReply
    if answer.attempt_id ~= expected.attempt_id then return nil, "reply names another attempt" end
    if answer.generation ~= expected.generation then return nil, "reply names generation " .. tostring(answer.generation) .. ", not " .. tostring(expected.generation) end
    if answer.probe ~= expected.probe then return nil, "reply answers another probe" end
    if type(answer.closed) ~= "boolean" then return nil, "reply does not say whether stdin closed" end
    return answer, nil
end
function M.status_reply_accepted(sender: string, reply: unknown, expected: StatusProbe): (RunnerStatus?, string?)
    if sender ~= expected.runner then return nil, "reply from " .. sender .. ", not the recorded runner" end
    if type(reply) ~= "table" then return nil, "reply is not an object" end
    local status = reply :: RunnerStatus
    if status.attempt_id ~= expected.attempt_id then return nil, "reply names another attempt" end
    if status.generation ~= expected.generation then return nil, "reply names generation " .. tostring(status.generation) .. ", not " .. tostring(expected.generation) end
    if status.probe ~= expected.probe then return nil, "reply answers another probe" end
    if status.execution ~= "starting" and status.execution ~= "running" and status.execution ~= "stopping" and status.execution ~= "exited" then return nil, "reply reports an unknown execution" end
    return status, nil
end
return M
