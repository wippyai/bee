-- MIT. Claude Code launch specifications: declarative argv for a first turn
-- and for a resumed turn. Nothing here runs; placement resolves the
-- executable, the home and the working directory.
local bounds = require("bounds")
local canonical = require("canonical")
local types = require("types")
local M = {}
-- The API-key path is the environment projection of ANTHROPIC_API_KEY
-- with the host-selected endpoint in ANTHROPIC_BASE_URL; the proof through
-- the placement runner runs only where the pinned executable is bound, so
-- the gate stays open until the pinned build runs it.
M.CLAUDE_AUTHENTICATION = "unproven"
M.PERMISSION_MODES = {"default", "acceptEdits", "plan", "dontAsk"}
M.EFFORTS = {"low", "medium", "high", "xhigh", "max"}
M.MAX_TURNS = 32
-- permission_exchange is set by the host when it enabled an interactive
-- exchange: the launch then takes its brief over stream-json input, keeps
-- stdin open for the responses and routes permission prompts to stdin.
type Request = {profile_id: string, brief: string, permission_mode: string, max_turns: integer, model: string?, effort: string?, resume_ref: string?, permission_exchange: boolean, gateway_tools: {string}?}
function M.decode(value: unknown): (Request?, string?)
    local object = bounds.object(value)
    if not object then return nil, "launch request must be an object" end
    local unknown_field = bounds.fields(object, {"profile_id", "brief", "permission_mode", "max_turns", "model", "effort", "resume_ref", "permission_exchange", "gateway_tools", "gateway_hooks"})
    if unknown_field then return nil, unknown_field end
    local profile_id = bounds.id(object.profile_id)
    if not profile_id then return nil, "profile_id is not an identifier" end
    local brief = bounds.text(object.brief)
    if not brief or (#brief == 0 and profile_id ~= "window") then return nil, "brief must be nonempty bounded text" end
    local mode = "default"
    if object.permission_mode ~= nil then
        local declared = bounds.member(object.permission_mode, M.PERMISSION_MODES)
        if not declared then return nil, "permission_mode is not one Bee admits" end
        mode = declared
    end
    if profile_id == "window" and object.max_turns ~= nil then return nil, "max_turns is only supported for structured turns" end
    local turns = 1
    if object.max_turns ~= nil then
        local number = bounds.integer(object.max_turns)
        if not number or number < 1 or number > M.MAX_TURNS then return nil, "max_turns must be between 1 and " .. tostring(M.MAX_TURNS) end
        turns = number
    end
    local model: string? = nil
    if object.model ~= nil then
        local declared = bounds.text(object.model, 128)
        if not declared or declared == "" or not declared:match("^[A-Za-z0-9][A-Za-z0-9._:-]*$") then return nil, "model is not one bounded model identifier" end
        model = declared
    end
    local effort: string? = nil
    if object.effort ~= nil then
        local declared = bounds.member(object.effort, M.EFFORTS)
        if not declared then return nil, "effort is not one Bee admits" end
        effort = declared
    end
    local resume: string? = nil
    if object.resume_ref ~= nil then
        resume = bounds.id(object.resume_ref)
        if not resume then return nil, "resume_ref is not an identifier" end
        if resume:sub(1, 1) == "-" then return nil, "resume_ref must not be a command-line option" end
    end
    local exchange = false
    if object.permission_exchange ~= nil then
        if type(object.permission_exchange) ~= "boolean" then return nil, "permission_exchange must be a boolean" end
        exchange = object.permission_exchange :: boolean
    end
    if profile_id == "window" and exchange then return nil, "stdio permission exchange is only supported for structured turns" end
    -- Hook events reach Claude Code through the settings adapter in its
    -- home; the launch line carries nothing for them.
    if object.gateway_hooks ~= nil then
        local declared, hooks_error = bounds.ids(object.gateway_hooks, true)
        if not declared then return nil, "gateway_hooks: " .. tostring(hooks_error) end
    end
    local gateway_tools: {string} = {}
    if object.gateway_tools ~= nil then
        local declared, tools_error = bounds.ids(object.gateway_tools, true)
        if not declared then return nil, "gateway_tools: " .. tostring(tools_error) end
        for _, tool in ipairs(declared) do
            if not tool:match("^[a-z_]+$") then return nil, "gateway_tools names a tool that is not a plain identifier" end
        end
        table.sort(declared)
        gateway_tools = declared
    end
    return {profile_id = profile_id, brief = brief, permission_mode = mode, max_turns = turns, model = model, effort = effort, resume_ref = resume, permission_exchange = exchange, gateway_tools = gateway_tools}, nil
end
-- The exchange launch: the executable reads stream-json input, so the
-- brief is the first user line on stdin rather than an argument, stdin
-- stays open for control responses, and permission prompts go to the
-- stdio prompt tool. The harness ends when stdin closes; a close while a
-- prompt is pending denies it.
function M.specification(request: Request): types.Launch
    local window = request.profile_id == "window"
    local argv: {string} = {}
    if not window then
        argv[#argv + 1] = "-p"
        if request.permission_exchange then
            argv[#argv + 1] = "--input-format"
            argv[#argv + 1] = "stream-json"
        end
        for _, item in ipairs({"--output-format", "stream-json", "--verbose", "--include-partial-messages"}) do argv[#argv + 1] = item end
    end
    argv[#argv + 1] = "--permission-mode"
    argv[#argv + 1] = request.permission_mode
    if not window then
        argv[#argv + 1] = "--max-turns"
        argv[#argv + 1] = tostring(request.max_turns)
    end
    if request.model then
        argv[#argv + 1] = "--model"
        argv[#argv + 1] = request.model
    end
    if request.effort then
        argv[#argv + 1] = "--effort"
        argv[#argv + 1] = request.effort
    end
    if request.permission_exchange then
        for _, item in ipairs({"--permission-prompt-tool", "stdio", "--permission-prompts", "host"}) do argv[#argv + 1] = item end
    end
    if request.resume_ref then
        argv[#argv + 1] = "-r"
        argv[#argv + 1] = request.resume_ref
    end
    -- The session tool reads the active trait schemas and requests host
    -- approval for changes. It is advertised beside admitted gateway tools,
    -- so Claude in dontAsk mode must be allowed to call it too. Its operations
    -- still pass the gateway's own admission checks.
    local gateway_tools = request.gateway_tools or {}
    if #gateway_tools > 0 then
        local names: {string} = {"mcp__bee__session"}
        for _, tool in ipairs(gateway_tools) do
            if tool ~= "session" then names[#names + 1] = "mcp__bee__" .. tool end
        end
        argv[#argv + 1] = "--allowedTools"
        argv[#argv + 1] = table.concat(names, ",")
    end
    local environment: {string} = {}
    if window then
        if request.brief ~= "" then
            argv[#argv + 1] = "--"
            argv[#argv + 1] = request.brief
        end
        return {executable = "claude", argv = argv, environment = environment, readiness = "terminal:attached",
            login = {provider = "claude", command = "claude", files = {{variable = "CLAUDE_CONFIG_DIR", default_directory = ".claude", path = ".credentials.json"}}}}
    end
    if not request.permission_exchange then
        argv[#argv + 1] = "--"
        argv[#argv + 1] = request.brief
    end
    local launch: types.Launch = {executable = "claude", argv = argv, environment = environment, readiness = "protocol:system.init"}
    if request.permission_exchange then
        -- Canonical encoding keeps the launch specification, and with it
        -- the plan digest, identical across processes.
        local line, encode_error = canonical.encode({type = "user", message = {role = "user", content = request.brief}})
        if not line then error("encode the brief: " .. tostring(encode_error)) end
        launch.stdin = line .. "\n"
        launch.session_end = "stdin_close"
    end
    return launch
end
return M
