-- MIT. The driver binding schema: what a provider declares it supports.
-- Metadata describes; host admission decides. Every field is decoded by
-- bee.driver:profile before anything reads it.
type Mode = "window" | "session" | "batch"
type Protocol = "stream-json" | "acp" | "app-server" | "rpc" | "sdk" | "native" | "pty" | "http-events"
type HookTransport = "command" | "http" | "mcp_tool" | "plugin"
type Hooks = {transports: {HookTransport}, events: {string}, adapter_ref: string?}
type AnswerStrategy = "terminal_field" | "accumulate" | "transcript" | "runner"
type AnswerPath = {strategy: "none"} | {strategy: AnswerStrategy, adapter_ref: string}
type ResumeStrategy = "per-process" | "in-process" | "none"
type Resume = {strategy: ResumeStrategy, portable: boolean}
type Inbound = "next_turn" | "mcp_pull" | "stream_stdin" | "steering" | "acp" | "rpc" | "runner"
type IsolationEnv = {variables: {string}, private_home: boolean}
type TrustPreanswer = {supported: boolean, adapter_ref: string?}
type ReadyStrategy = "protocol" | "hook" | "probe" | "none"
type InputReady = {strategy: ReadyStrategy, adapter_ref: string?, timeout_ms: integer}
type InterruptMethod = "protocol" | "signal_group" | "runner_cancel"
type Interrupt = {methods: {InterruptMethod}, adapter_ref: string?}
type McpTransport = "stdio" | "streamable_http" | "sse" | "ws"
type ToolFilter = {syntax: string, adapter_ref: string}
type Mcp = {client_transports: {McpTransport}, bridge_ref: string?, tool_filter: ToolFilter?, initialize_timeout_ms: integer?, call_timeout_ceiling_ms: integer?}
type Sandbox = {providers: {string}, required_placement_features: {string}}
-- A permission exchange is enabled only by an adapter pinned by reference
-- and digest; none means a permission-denied outcome stays terminal.
type PermissionMode = "none" | "adapter"
type PermissionExchange = {mode: PermissionMode, adapter_ref: string?, adapter_digest: string?}
type Profile = {
    id: string,
    mode: Mode,
    protocol: Protocol,
    protocol_revision: string,
    hooks: Hooks,
    answer_path: AnswerPath,
    resume: Resume,
    inbound: {Inbound},
    isolation_env: IsolationEnv,
    trust_preanswer: TrustPreanswer,
    exit_codes_trustworthy: boolean,
    input_ready: InputReady,
    interrupt: Interrupt,
    mcp: Mcp,
    sandbox: Sandbox,
    permission_exchange: PermissionExchange,
}
type Binding = {
    schema_revision: string,
    kind: string,
    title: string,
    implementation_version: string,
    profiles: {Profile},
    default_profile: string,
}
-- A launch specification: declarative, resolved by placement, never run here.
type Launch = {
    executable: string,
    argv: {string},
    stdin: string?,
    stdin_eof: boolean?,
    -- stdin_close: the harness ends its session when stdin closes, so the
    -- owner closes it after settlement and stop stays the fallback.
    session_end: string?,
    environment: {string},
    working_directory_ref: string?,
    home_ref: string?,
    readiness: string,
}
-- What a normalizer reports when the protocol says the turn is over.
type Outcome = "succeeded" | "failed" | "cancelled" | "uncertain"
type Terminal = {
    outcome: Outcome,
    answer: string?,
    resume_ref: string?,
    usage: {[string]: unknown}?,
    error: {code: string, message: string, retryable: boolean}?,
}
local M = {}
return M
