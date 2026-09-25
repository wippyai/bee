local bounds = require("bounds")
local types = require("types")
local M = {}
M.CODEX_AUTHENTICATION = "unproven"
M.EFFORTS = {"low", "medium", "high", "xhigh", "max"}
M.SANDBOXES = {"read-only", "workspace-write"}
-- A named Codex configuration profile is `$CODEX_HOME/<name>.config.toml`,
-- layered by the executable's own `-p/--profile` on top of the base user
-- config. It is a plain name: Codex itself rejects a dot, a separator, a
-- space, an empty value or a leading dash. The name is a bounded identifier,
-- never a path, so it cannot escape the Codex home.
M.MAX_CONFIG_PROFILE_BYTES = 64
type Request = {profile_id: string, brief: string, sandbox: string, resume_ref: string?, gateway_hooks: boolean?, effort: string?, config_profile: string?}
function M.decode(value: unknown): (Request?, string?)
    local object = bounds.object(value)
    if not object then return nil, "launch request must be an object" end
    local unknown_field = bounds.fields(object, {"profile_id", "brief", "sandbox", "resume_ref", "gateway_tools", "gateway_hooks", "effort", "config_profile"})
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
    local config_profile: string? = nil
    if object.config_profile ~= nil then
        local name = bounds.text(object.config_profile, M.MAX_CONFIG_PROFILE_BYTES)
        if not name or not name:match("^[A-Za-z0-9_][A-Za-z0-9_-]*$") then
            return nil, "config_profile must be a plain Codex profile name"
        end
        config_profile = name
    end
    local resume: string? = nil
    if object.resume_ref ~= nil then
        resume = bounds.id(object.resume_ref)
        if not resume then return nil, "resume_ref is not an identifier" end
        if resume:sub(1, 1) == "-" then return nil, "resume_ref must not be a command-line option" end
    end
    return {profile_id = profile_id, brief = brief, sandbox = sandbox, resume_ref = resume, gateway_hooks = hooks, effort = effort, config_profile = config_profile}, nil
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
    -- A named configuration profile is a top-level Codex option: the
    -- executable accepts it before `exec` and before a `resume` subcommand,
    -- and layers $CODEX_HOME/<name>.config.toml on top of the base config.
    -- Bee's own session `-c` MCP and hook arguments still arrive through
    -- configuration delivery and layer on top of the named profile.
    local required_files: {types.RequiredFile}? = nil
    if request.config_profile then
        table.insert(argv, 1, request.config_profile)
        table.insert(argv, 1, "--profile")
        required_files = {{variable = "CODEX_HOME", path = request.config_profile .. ".config.toml", default_directory = ".codex"}}
    end
    local environment: {string} = {}
    if request.profile_id == "window" then
        return {executable = "codex", argv = argv, environment = environment, required_files = required_files, readiness = "terminal:attached",
            login = {provider = "codex", command = "codex login", files = {{variable = "CODEX_HOME", default_directory = ".codex", path = "auth.json"}}}}
    end
    -- The brief goes in on stdin and Codex reads it until end of file, so
    -- the launch requires a placement that can close stdin after writing.
    local launch: types.Launch = {executable = "codex", argv = argv, stdin = request.brief, stdin_eof = true, environment = environment, required_files = required_files, readiness = "protocol:thread.started"}
    return launch
end
return M
