-- MIT. Grok CLI launch specifications: declarative argv for a first turn
-- and for a resumed turn. Placement resolves the executable, the home and
-- the working directory; nothing here runs a process.
local bounds = require("bounds")
local types = require("types")
local M = {}

-- The API-key path uses environment projection of XAI_API_KEY (or browser/device
-- credentials in GROK_HOME); until verified against a live key, the gate stays open.
M.GROK_AUTHENTICATION = "unproven"
M.PERMISSION_MODES = {"default", "acceptEdits", "auto", "dontAsk", "bypassPermissions", "plan"}
M.EFFORTS = {"none", "minimal", "low", "medium", "high", "xhigh", "max"}
M.MAX_TURNS = 32

type Request = {
    profile_id: string,
    brief: string,
    permission_mode: string,
    max_turns: integer,
    model: string?,
    effort: string?,
    resume_ref: string?,
    gateway_tools: {string}?,
}

function M.decode(value: unknown): (Request?, string?)
    local object = bounds.object(value)
    if not object then return nil, "launch request must be an object" end
    local unknown_field = bounds.fields(object, {"profile_id", "brief", "permission_mode", "max_turns", "model", "effort", "reasoning_effort", "resume_ref", "gateway_tools"})
    if unknown_field then return nil, "launch request: " .. unknown_field end
    local profile_id = bounds.id(object.profile_id)
    if not profile_id then return nil, "profile_id is not an identifier" end
    if not (profile_id == "session" or profile_id == "batch" or profile_id == "window") then
        return nil, "profile_id is not one Bee admits"
    end
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
    local raw_effort = object.effort ~= nil and object.effort or object.reasoning_effort
    if raw_effort ~= nil then
        local declared = bounds.member(raw_effort, M.EFFORTS)
        if not declared then return nil, "effort is not one Bee admits" end
        effort = declared
    end
    local resume: string? = nil
    if object.resume_ref ~= nil then
        resume = bounds.id(object.resume_ref)
        if not resume then return nil, "resume_ref is not an identifier" end
        if resume:sub(1, 1) == "-" then return nil, "resume_ref must not be a command-line option" end
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
    return {
        profile_id = profile_id,
        brief = brief,
        permission_mode = mode,
        max_turns = turns,
        model = model,
        effort = effort,
        resume_ref = resume,
        gateway_tools = gateway_tools,
    }, nil
end

function M.specification(request: Request): types.Launch
    local window = request.profile_id == "window"
    local argv: {string} = {}
    if not window then
        if request.brief:sub(1, 1) == "-" then
            argv[#argv + 1] = "--single=" .. request.brief
        else
            argv[#argv + 1] = "-p"
            argv[#argv + 1] = request.brief
        end
        argv[#argv + 1] = "--output-format"
        argv[#argv + 1] = "streaming-json"
    end
    if not window or request.permission_mode ~= "default" then
        argv[#argv + 1] = "--permission-mode"
        argv[#argv + 1] = request.permission_mode
    end
    if not window then
        argv[#argv + 1] = "--max-turns"
        argv[#argv + 1] = tostring(request.max_turns)
    end
    if request.model then
        argv[#argv + 1] = "--model"
        argv[#argv + 1] = request.model
    end
    if request.effort then
        argv[#argv + 1] = "--reasoning-effort"
        argv[#argv + 1] = request.effort
    end
    if request.resume_ref then
        argv[#argv + 1] = "-r"
        argv[#argv + 1] = request.resume_ref
    end
    local gateway_tools = request.gateway_tools or {}
    if #gateway_tools > 0 then
        argv[#argv + 1] = "--allow"
        argv[#argv + 1] = "MCPTool(bee__*)"
    end
    local environment: {string} = {}
    if window then
        if request.brief ~= "" then
            argv[#argv + 1] = "--"
            argv[#argv + 1] = request.brief
        end
        return {executable = "grok", argv = argv, environment = environment, readiness = "terminal:attached"}
    end
    return {executable = "grok", argv = argv, environment = environment, readiness = "none"}
end

return M
