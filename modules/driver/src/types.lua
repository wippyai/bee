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
type GitWritableRootsAdapter = "codex_workspace_write" | "claude_add_dir" | "agy_add_dir"
type Sandbox = {providers: {string}, required_placement_features: {string}, git_writable_roots_adapter: GitWritableRootsAdapter?}
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
-- A host file a launch needs before it starts, named by the environment
-- variable that locates its directory and a safe relative path inside it, or
-- by the user's home plus a default directory. Placement checks existence
-- only; the driver never reads the file's contents.
type RequiredFile = {variable: string, path: string, default_directory: string?}
-- Window advisories keep compatibility file paths and the descriptor
-- alternatives. Placement observes files; other kinds remain unknown there.
-- The command is display text, never an instruction to execute login.
type LoginEvidence = {provider: string, command: string, files: {RequiredFile}, any_of: {login_evidence.Evidence}?}
type LocateStatus = "ready" | "missing" | "unconfigured" | "incompatible" | "unknown"
type LocatePlatform = {os: string?, arch: string?, compatible: boolean?}
type LocateExecutable = {name: string, present: boolean?, version: string?}
type LocateLogin = {evidence: "file_exists" | "any_of" | "not_required", path: string?, exists: boolean?}
type LocateResult = {provider: string, status: LocateStatus, executable: LocateExecutable,
    login: LocateLogin, platform: LocatePlatform, checked_at: string?, reason: string?}
type ProviderHomeFile =
    {source_path: string, path: string, kind: "login", optional: boolean, write_back: boolean}
    | {source_path: string, path: string, kind: "config", optional: boolean, write_back: false}
    | {source_path: nil, path: string, kind: "state", optional: boolean, write_back: false}
type ProviderHomeEnvironment = {variable: string, directory: string}
-- A private managed home receives only these provider-owned files from the
-- machine login source. `variable` and `directory` select the child CLI's
-- provider home; files stay relative to HOME so the projection is auditable.
-- `retain_session` opts into an admitted session home instead of an attempt home.
type ProviderHome =
    {provider: string, private: boolean, retain_session: boolean?, variable: string, directory: string, extra_variables: {ProviderHomeEnvironment}?, files: {ProviderHomeFile}}
    | {provider: string, private: boolean, retain_session: boolean?, variable: nil, directory: nil, extra_variables: {ProviderHomeEnvironment}?, files: {ProviderHomeFile}}
type Launch = {
    executable: string,
    -- Arguments only. Placement prepends the separately selected executable.
    argv: {string},
    stdin: string?,
    stdin_eof: boolean?,
    -- stdin_close: the harness ends its session when stdin closes, so the
    -- owner closes it after settlement and stop stays the fallback.
    session_end: string?,
    environment: {string},
    working_directory_ref: string?,
    home_ref: string?,
    required_files: {RequiredFile}?,
    login: LoginEvidence?,
    provider_home: ProviderHome?,
    readiness: string,
}
-- What a normalizer reports when the protocol says the turn is over.
type Outcome = "succeeded" | "failed" | "cancelled" | "uncertain"
type Usage = events.Usage
type Fault = {code: string, message: string, retryable: boolean}
type Terminal = {
    outcome: Outcome,
    answer: string?,
    resume_ref: string?,
    usage: Usage?,
    error: Fault?,
}
local bounds = require("bounds")
local events = require("events")
local values = require("values")
local login_evidence = require("login_evidence")
local M = {}
-- Executable-backed provider login flows remain an explicit integration gate.
M.AUTHENTICATION_STATUS = "unproven"
type GitWritableRootsAdapters = {
    CODEX_WORKSPACE_WRITE: "codex_workspace_write",
    CLAUDE_ADD_DIR: "claude_add_dir",
    AGY_ADD_DIR: "agy_add_dir",
}
local git_writable_roots_adapters: GitWritableRootsAdapters = {
    CODEX_WORKSPACE_WRITE = "codex_workspace_write",
    CLAUDE_ADD_DIR = "claude_add_dir",
    AGY_ADD_DIR = "agy_add_dir",
}
M.GIT_WRITABLE_ROOTS_ADAPTERS = git_writable_roots_adapters
function M.git_writable_roots_adapter(value: unknown): GitWritableRootsAdapter?
    if value == git_writable_roots_adapters.CODEX_WORKSPACE_WRITE
        or value == git_writable_roots_adapters.CLAUDE_ADD_DIR
        or value == git_writable_roots_adapters.AGY_ADD_DIR then
        return value
    end
    return nil
end
function M.decode_terminal(value: unknown): (Terminal?, string?)
    local object = bounds.object(value)
    if not object then return nil, "terminal must be an object" end
    local unknown = bounds.fields(object, {"outcome", "answer", "resume_ref", "usage", "error"})
    if unknown then return nil, "terminal: " .. unknown end
    local outcome = bounds.member(object.outcome, {"succeeded", "failed", "cancelled", "uncertain"})
    if not outcome then return nil, "terminal.outcome is not a carrier outcome" end
    local answer: string? = nil
    if object.answer ~= nil then
        answer = bounds.text(object.answer, 32768)
        if not answer then return nil, "terminal.answer exceeds its byte bound" end
    end
    local resume_ref: string? = nil
    if object.resume_ref ~= nil then
        resume_ref = bounds.id(object.resume_ref)
        if not resume_ref then return nil, "terminal.resume_ref is not an identifier" end
    end
    local usage: Usage? = nil
    if object.usage ~= nil then
        local raw_usage = bounds.object(object.usage)
        if not raw_usage then return nil, "terminal.usage must be an object" end
        local decoded, usage_error = values.usage(raw_usage)
        if usage_error then return nil, "terminal." .. tostring(usage_error) end
        usage = decoded
    end
    local fault: Fault? = nil
    if object.error ~= nil then
        local raw_fault = bounds.object(object.error)
        if not raw_fault then return nil, "terminal.error must be an object" end
        local fault_unknown = bounds.fields(raw_fault, {"code", "message", "retryable"})
        if fault_unknown then return nil, "terminal.error: " .. fault_unknown end
        local code = bounds.id(raw_fault.code)
        local message = bounds.text(raw_fault.message, bounds.MAX_FAULT_MESSAGE_BYTES)
        if not code or not message or type(raw_fault.retryable) ~= "boolean" then return nil, "terminal.error is malformed" end
        fault = {code = code, message = message, retryable = raw_fault.retryable}
    end
    if outcome == "failed" and not fault then return nil, "failed terminal must include an error" end
    return {outcome = outcome :: Outcome, answer = answer, resume_ref = resume_ref, usage = usage, error = fault}, nil
end
return M
