local bounds = require("bounds")
local types = require("types")
local M = {}
-- Muse authentication uses the admitted login copied into a retained private
-- HOME.
M.MUSE_AUTHENTICATION = "unproven"
M.APPROVAL_MODES = {"untrusted", "on-request", "never"}
M.EFFORTS = {"low", "medium", "high", "xhigh", "max"}
M.MAX_STEPS = 32
type Request = {profile_id: string, brief: string, approval_mode: string, max_steps: integer?, model: string?, effort: string?, resume_ref: string?, gateway_hooks: boolean?}
function M.decode(value: unknown): (Request?, string?)
    local object = bounds.object(value)
    if not object then return nil, "launch request must be an object" end
    local unknown_field = bounds.fields(object, {"profile_id", "brief", "approval_mode", "max_steps", "model", "effort", "resume_ref", "gateway_tools", "gateway_hooks"})
    if unknown_field then return nil, unknown_field end
    -- Gateway tools reach Muse through the settings file's mcpServers
    -- section; the launch line carries nothing for them.
    if object.gateway_tools ~= nil then
        local declared, tools_error = bounds.ids(object.gateway_tools, true)
        if not declared then return nil, "gateway_tools: " .. tostring(tools_error) end
    end
    -- Hook events reach Muse through the settings file in the private
    -- config home; the launch line carries nothing for them.
    local hooks = false
    if object.gateway_hooks ~= nil then
        local declared, hooks_error = bounds.ids(object.gateway_hooks, true)
        if not declared then return nil, "gateway_hooks: " .. tostring(hooks_error) end
        hooks = #declared > 0
    end
    local profile_id = bounds.id(object.profile_id)
    if not profile_id then return nil, "profile_id is not an identifier" end
    local brief = bounds.text(object.brief)
    if not brief or (#brief == 0 and profile_id ~= "window") then return nil, "brief must be nonempty bounded text" end
    local mode = "on-request"
    if object.approval_mode ~= nil then
        local declared = bounds.member(object.approval_mode, M.APPROVAL_MODES)
        if not declared then return nil, "approval_mode is not one Bee admits" end
        mode = declared
    end
    local steps: integer? = nil
    if object.max_steps ~= nil then
        local number = bounds.integer(object.max_steps)
        if not number or number < 1 or number > M.MAX_STEPS then return nil, "max_steps must be between 1 and " .. tostring(M.MAX_STEPS) end
        steps = number
    end
    local model: string? = nil
    if object.model ~= nil then
        local declared = bounds.text(object.model, 128)
        if not declared or declared == "" or not declared:match("^[A-Za-z0-9][A-Za-z0-9._:-]*$") then return nil, "model is not one bounded model identifier" end
        model = declared
    end
    local effort: string? = nil
    if object.effort ~= nil then
        effort = bounds.member(object.effort, M.EFFORTS)
        if not effort then return nil, "effort is not one Bee admits" end
    end
    local resume: string? = nil
    if object.resume_ref ~= nil then
        resume = bounds.id(object.resume_ref)
        if not resume then return nil, "resume_ref is not an identifier" end
        if resume:sub(1, 1) == "-" then return nil, "resume_ref must not be a command-line option" end
    end
    if profile_id == "window" and resume ~= nil and brief ~= "" then
        return nil, "window resume cannot carry a brief"
    end
    return {profile_id = profile_id, brief = brief, approval_mode = mode, max_steps = steps, model = model, effort = effort, resume_ref = resume, gateway_hooks = hooks}, nil
end
function M.specification(request: Request): types.Launch
    local environment: {string} = {}
    if request.profile_id == "window" then
        local argv: {string} = {}
        if request.resume_ref then
            argv[#argv + 1] = "resume"
            argv[#argv + 1] = request.resume_ref
        end
        if request.brief ~= "" then
            argv[#argv + 1] = "--"
            argv[#argv + 1] = request.brief
        end
        return {executable = "muse", argv = argv, environment = environment, readiness = "terminal:attached",
            login = {provider = "muse", command = "muse", files = {{variable = "HOME", path = ".config/muse/auth.json"}}}}
    end
    local argv: {string} = {"exec", "--json", "--approval-mode", request.approval_mode}
    if request.model then
        argv[#argv + 1] = "--model"
        argv[#argv + 1] = request.model
    end
    if request.effort then
        argv[#argv + 1] = "--reasoning-effort"
        argv[#argv + 1] = request.effort
    end
    if request.max_steps then
        argv[#argv + 1] = "--max-model-steps"
        argv[#argv + 1] = tostring(request.max_steps)
    end
    if request.resume_ref then
        argv[#argv + 1] = "--session-id"
        argv[#argv + 1] = request.resume_ref
    end
    argv[#argv + 1] = "--"
    argv[#argv + 1] = request.brief
    local launch: types.Launch = {executable = "muse", argv = argv, environment = environment, readiness = "protocol:runtime.command.accepted"}
    return launch
end
return M
