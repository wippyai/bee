-- MIT. Type definitions for the native Wippy in-process agent driver.
local M = {}

type Object = {[string]: unknown}

type HostConfig = {
    endpoint: string,
    credential_ref: string?,
    model: string?,
    timeout_ms: integer?,
    stream: boolean?,
}

type ToolCall = {[string]: unknown}

type Message = {[string]: unknown}

type ChatPayload = {[string]: unknown}

type ChatResponse = {[string]: unknown}

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
    resume: boolean?,
    session_ref: string?,
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
