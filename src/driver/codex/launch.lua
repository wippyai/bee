-- MIT. Codex CLI launch specifications: a fresh exec, or a resumed thread.
local bounds = require("bounds")
local types = require("types")
local M = {}
-- The API-key path is selected only by a generated provider configuration
-- in the private CODEX_HOME (provider with env_key OPENAI_API_KEY, base_url
-- and the responses wire API); the environment projection alone does not
-- authenticate the pinned executable. Until that configuration projection
-- ships, the gate stays open.
M.CODEX_AUTHENTICATION = "unproven"
M.EFFORTS = {"low", "medium", "high", "xhigh", "max"}
M.SANDBOXES = {"read-only", "workspace-write"}
type Request = {profile_id: string, brief: string, sandbox: string, resume_ref: string?, gateway_hooks: boolean?, effort: string?}
function M.decode(value: unknown): (Request?, string?)
    local object = bounds.object(value)
    if not object then return nil, "launch request must be an object" end
    local unknown_field = bounds.fields(object, {"profile_id", "brief", "sandbox", "resume_ref", "gateway_tools", "gateway_hooks", "effort"})
    if unknown_field then return nil, unknown_field end
    -- Gateway tools reach Codex through the provider configuration's
    -- mcp_servers section; the launch line carries nothing for them, and
    -- the tools' read-only annotations let Codex run them unprompted.
    if object.gateway_tools ~= nil then
        local declared, tools_error = bounds.ids(object.gateway_tools, true)
        if not declared then return nil, "gateway_tools: " .. tostring(tools_error) end
    end
    -- Hook events reach Codex through hooks.json and the trust state the
    -- runner writes into the bee profile layer; the launch line selects it.
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
    local sandbox = "read-only"
    if object.sandbox ~= nil then
        local declared = bounds.member(object.sandbox, M.SANDBOXES)
        if not declared then return nil, "sandbox is not one Bee admits" end
        sandbox = declared
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
    return {profile_id = profile_id, brief = brief, sandbox = sandbox, resume_ref = resume, gateway_hooks = hooks, effort = effort}, nil
end
function M.specification(request: Request): types.Launch
    local argv: {string}
    if request.profile_id == "window" then
        argv = {"--sandbox", request.sandbox}
        if request.resume_ref then
            argv[#argv + 1] = "resume"
            argv[#argv + 1] = request.resume_ref
        end
        if request.brief ~= "" then
            argv[#argv + 1] = "--"
            argv[#argv + 1] = request.brief
        end
    elseif request.resume_ref then
        argv = {"--sandbox", request.sandbox, "exec", "resume", request.resume_ref, "--json", "--skip-git-repo-check", "-"}
    else
        argv = {"exec", "--json", "--skip-git-repo-check", "--sandbox", request.sandbox, "-"}
    end
    if request.effort then
        -- Keep options before any resume subcommand or prompt delimiter.
        table.insert(argv, 1, 'model_reasoning_effort="' .. request.effort .. '"')
        table.insert(argv, 1, "--config")
    end
    local environment: {string} = {}
    if request.profile_id == "window" then
        return {executable = "codex", argv = argv, environment = environment, readiness = "terminal:attached"}
    end
    -- The brief goes in on stdin and Codex reads it until end of file, so
    -- the launch requires a placement that can close stdin after writing.
    local launch: types.Launch = {executable = "codex", argv = argv, stdin = request.brief, stdin_eof = true, environment = environment, readiness = "protocol:thread.started"}
    return launch
end
return M
