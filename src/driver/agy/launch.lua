local bounds = require("bounds")
local canonical = require("canonical")
local types = require("types")

local M = {}

M.AGY_AUTHENTICATION = "unproven"
M.AGY_HOOKS = "unproven"
M.AGY_MCP = "unproven"

M.MODES = {"default", "accept-edits", "plan"}
M.EFFORTS = {"low", "medium", "high"}

type Request = {
    profile_id: string,
    brief: string,
    mode: string?,
    model: string?,
    effort: string?,
    sandbox: boolean?,
    dangerously_skip_permissions: boolean?,
    agent: string?,
    resume_ref: string?,
    print_timeout: string?,
    gateway_tools: {string}?,
    gateway_hooks: {string}?,
}

function M.decode(value: unknown): (Request?, string?)
    local object = bounds.object(value)
    if not object then return nil, "launch request must be an object" end
    local unknown_field = bounds.fields(object, {
        "profile_id", "brief", "mode", "model", "effort", "sandbox",
        "dangerously_skip_permissions", "agent", "resume_ref",
        "print_timeout", "gateway_tools", "gateway_hooks",
    })
    if unknown_field then return nil, unknown_field end

    local profile_id = bounds.id(object.profile_id)
    if not profile_id then return nil, "profile_id is not an identifier" end

    local brief = bounds.text(object.brief)
    if not brief or (#brief == 0 and profile_id ~= "window") then
        return nil, "brief must be nonempty bounded text"
    end

    if profile_id == "window" and object.print_timeout ~= nil then
        return nil, "print_timeout is only supported for structured print turns"
    end

    local mode: string? = nil
    if object.mode ~= nil then
        local declared = bounds.member(object.mode, M.MODES)
        if not declared then return nil, "mode is not one Bee admits" end
        mode = declared
    end

    local model: string? = nil
    if object.model ~= nil then
        local declared = bounds.text(object.model, 128)
        if not declared or declared == "" or not declared:match("^[A-Za-z0-9][A-Za-z0-9._:-]*$") then
            return nil, "model is not one bounded model identifier"
        end
        model = declared
    end

    local effort: string? = nil
    if object.effort ~= nil then
        local declared = bounds.member(object.effort, M.EFFORTS)
        if not declared then return nil, "effort is not one Bee admits" end
        effort = declared
    end

    local sandbox: boolean? = nil
    if object.sandbox ~= nil then
        if type(object.sandbox) ~= "boolean" then return nil, "sandbox must be a boolean" end
        sandbox = object.sandbox :: boolean
    end

    local dangerously_skip: boolean? = nil
    if object.dangerously_skip_permissions ~= nil then
        if type(object.dangerously_skip_permissions) ~= "boolean" then
            return nil, "dangerously_skip_permissions must be a boolean"
        end
        dangerously_skip = object.dangerously_skip_permissions :: boolean
    end

    local agent: string? = nil
    if object.agent ~= nil then
        agent = bounds.id(object.agent)
        if not agent then return nil, "agent is not an identifier" end
        if agent:sub(1, 1) == "-" then return nil, "agent must not be a command-line option" end
    end

    local resume: string? = nil
    if object.resume_ref ~= nil then
        resume = bounds.id(object.resume_ref)
        if not resume then return nil, "resume_ref is not an identifier" end
        if resume:sub(1, 1) == "-" then return nil, "resume_ref must not be a command-line option" end
    end

    local print_timeout: string? = nil
    if object.print_timeout ~= nil then
        local declared = bounds.text(object.print_timeout, 32)
        if not declared or not declared:match("^[1-9][0-9]*[smh]$") then
            return nil, "print_timeout must be a positive duration string"
        end
        print_timeout = declared
    end

    local gateway_tools: {string}? = nil
    if object.gateway_tools ~= nil then
        local declared, tools_error = bounds.ids(object.gateway_tools, true)
        if not declared then return nil, "gateway_tools: " .. tostring(tools_error) end
        gateway_tools = declared
    end

    local gateway_hooks: {string}? = nil
    if object.gateway_hooks ~= nil then
        local declared, hooks_error = bounds.ids(object.gateway_hooks, true)
        if not declared then return nil, "gateway_hooks: " .. tostring(hooks_error) end
        gateway_hooks = declared
    end

    return {
        profile_id = profile_id,
        brief = brief,
        mode = mode,
        model = model,
        effort = effort,
        sandbox = sandbox,
        dangerously_skip_permissions = dangerously_skip,
        agent = agent,
        resume_ref = resume,
        print_timeout = print_timeout,
        gateway_tools = gateway_tools,
        gateway_hooks = gateway_hooks,
    }, nil
end

function M.specification(request: Request): types.Launch
    local window = request.profile_id == "window"
    local argv: {string} = {}

    if not window then
        argv[#argv + 1] = "--print="
        argv[#argv + 1] = "--input-format"
        argv[#argv + 1] = "stream-json"
        argv[#argv + 1] = "--output-format"
        argv[#argv + 1] = "stream-json"
        argv[#argv + 1] = "--disable-slash-commands"
    end

    if request.mode and request.mode ~= "default" then
        argv[#argv + 1] = "--mode"
        argv[#argv + 1] = request.mode
    end

    if request.dangerously_skip_permissions then
        argv[#argv + 1] = "--dangerously-skip-permissions"
    end

    if request.sandbox then
        argv[#argv + 1] = "--sandbox"
    end

    if request.model then
        argv[#argv + 1] = "--model"
        argv[#argv + 1] = request.model
    end

    if request.effort then
        argv[#argv + 1] = "--effort"
        argv[#argv + 1] = request.effort
    end

    if request.agent then
        argv[#argv + 1] = "--agent"
        argv[#argv + 1] = request.agent
    end

    if not window and request.print_timeout then
        argv[#argv + 1] = "--print-timeout"
        argv[#argv + 1] = request.print_timeout
    end

    if request.resume_ref then
        argv[#argv + 1] = "--conversation"
        argv[#argv + 1] = request.resume_ref
    end

    local environment: {string} = {}

    if window then
        if request.brief ~= "" then
            argv[#argv + 1] = "--prompt-interactive"
            argv[#argv + 1] = request.brief
        end
        return {
            executable = "agy",
            argv = argv,
            environment = environment,
            readiness = "terminal:attached",
        }
    end

    local line, encode_error = canonical.encode({
        event = "user",
        message = {content = request.brief, role = "user"},
    })
    if not line then error("encode the brief: " .. tostring(encode_error)) end

    return {
        executable = "agy",
        argv = argv,
        stdin = line .. "\n",
        stdin_eof = true,
        environment = environment,
        readiness = "protocol:init",
    }
end

return M
