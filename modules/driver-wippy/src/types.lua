-- MIT. Type definitions for the native Wippy in-process agent driver.
local M = {}
local driver_types = require("driver_types")

type Object = {[string]: unknown}
type RunState = "starting" | "running" | "ended" | "cancelling"
type Outcome = driver_types.Outcome
type Role = "system" | "user" | "assistant" | "tool"

type HostConfig = {
    endpoint: string,
    credential_ref: string?,
    model: string?,
    timeout_ms: integer?,
    stream: boolean?,
    admitted_delegates: {string}?,
    max_turns: integer?,
}

-- One decoded function tool call: the wire nests name and arguments under
-- a "function" object, which the client flattens on decode.
type ToolCall = {
    id: string,
    kind: "function",
    name: string,
    arguments: string,
}

type Message = {role: "system" | "user", content: string}
    | {role: "assistant", content: string?, tool_calls: {ToolCall}?}
    | {role: "tool", tool_call_id: string, content: string}

type ChatPayload = {
    model: string,
    messages: {{[string]: unknown}},
    tools: {{[string]: unknown}}?,
    stream: boolean?,
}

type ChatResponse = {
    content: string?,
    tool_calls: {ToolCall}?,
    finish_reason: string?,
}

type RunRequest = {
    thread_id: string,
    action_id: string,
    attempt_id: string,
    agent_ref: string?,
    brief: string?,
    workspace_id: string?,
    host_config: HostConfig?,
    idempotency_key: string?,
    carrier_epoch: integer?,
}

type ExecutionContext = {
    thread_id: string,
    action_id: string,
    attempt_id: string,
    carrier_epoch: integer,
    checkpoint_revision: integer,
    checkpoint: unknown,
    cancelled: () -> boolean,
    commit: (string, {{[string]: unknown}}, {[string]: unknown}) -> (boolean, string?),
}

type RunReceipt = {
    scope: "attempt",
    thread_id: string,
    action_id: string,
    attempt_id: string,
    state: RunState,
    idempotency_key: string?,
}

type RunResult =
    {ok: true, error: nil, outcome: Outcome, answer: string?, thread_id: string, action_id: string,
        attempt_id: string, receipt: RunReceipt?, state: RunState?, status: RunState?}
    | {ok: false, error: string, outcome: Outcome, answer: string?, thread_id: string, action_id: string,
        attempt_id: string, receipt: RunReceipt?, state: RunState?, status: RunState?}

type ExecutionResult =
    {outcome: "succeeded", error: nil, answer: string?, checkpoint: Object?}
    | {outcome: "failed", error: string, answer: string?, checkpoint: Object?}
    | {outcome: "cancelled", error: nil, answer: string?, checkpoint: Object?}
    | {outcome: "uncertain", error: string, answer: string?, checkpoint: Object?}

return M
