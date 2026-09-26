-- MIT. Type definitions for the native Wippy in-process agent driver.
local M = {}

type Object = {[string]: unknown}

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
    kind: string,
    name: string,
    arguments: string,
}

type Message = {
    role: string,
    content: string?,
    tool_calls: {ToolCall}?,
    tool_call_id: string?,
}

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

type RunReceipt = {
    scope: string,
    thread_id: string,
    action_id: string,
    attempt_id: string,
    state: string,
    idempotency_key: string?,
}

type RunResult = {
    ok: boolean,
    error: string?,
    outcome: string?,
    answer: string?,
    thread_id: string,
    action_id: string,
    attempt_id: string,
    receipt: RunReceipt?,
    state: string?,
    status: string?,
}

return M
