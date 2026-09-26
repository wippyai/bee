-- MIT. OpenCode launch specifications: declarative argv for the interactive
-- window and for a headless structured turn. Nothing here runs; placement
-- resolves the executable, the home and the working directory.
--
-- Verified against opencode 1.18.32 (`opencode --help`, `opencode run
-- --help`, `opencode run --format json` traces): bare `opencode` starts the
-- TUI, `run [message..]` is the non-interactive entrypoint, `--format json`
-- streams newline-delimited JSON events, `--session` continues a session by
-- ID, and `--` separates a leading-dash message from flags. There is no
-- model, effort or auto-approve flag here: the user configures models and
-- permissions in their own OpenCode home, so Bee never names them.
local bounds = require("bounds")
local types = require("types")
local M = {}
-- OpenCode authentication uses the user's own `opencode providers login`
-- flow; the proof through the placement runner runs only where the pinned
-- executable is bound, so the gate stays open until the pinned build runs it.
M.OPENCODE_AUTHENTICATION = "unproven"
type Request = {profile_id: string, brief: string, resume_ref: string?}
function M.decode(value: unknown): (Request?, string?)
    local object = bounds.object(value)
    if not object then return nil, "launch request must be an object" end
    local unknown_field = bounds.fields(object, {"profile_id", "brief", "resume_ref", "gateway_tools", "gateway_hooks"})
    if unknown_field then return nil, unknown_field end
    -- Gateway tools reach OpenCode through the generated opencode.json mcp
    -- section; the launch line carries nothing for them.
    if object.gateway_tools ~= nil then
        local declared, tools_error = bounds.ids(object.gateway_tools, true)
        if not declared then return nil, "gateway_tools: " .. tostring(tools_error) end
        for _, tool in ipairs(declared) do
            if not tool:match("^[a-z_]+$") then return nil, "gateway_tools names a tool that is not a plain identifier" end
        end
    end
    -- OpenCode has no hook transport: its plugin events are provider-owned
    -- JavaScript, not Bee's admitted hook handlers, so any requested hook
    -- event is refused here rather than silently dropped.
    if object.gateway_hooks ~= nil then
        local declared, hooks_error = bounds.ids(object.gateway_hooks, true)
        if not declared then return nil, "gateway_hooks: " .. tostring(hooks_error) end
        if #declared > 0 then return nil, "opencode declares no hook transport for gateway hooks" end
    end
    local profile_id = bounds.id(object.profile_id)
    if not profile_id then return nil, "profile_id is not an identifier" end
    if profile_id ~= "window" and profile_id ~= "batch" then return nil, "profile_id is not one Bee admits" end
    local brief = bounds.text(object.brief)
    if not brief or (#brief == 0 and profile_id ~= "window") then return nil, "brief must be nonempty bounded text" end
    local resume: string? = nil
    if object.resume_ref ~= nil then
        resume = bounds.id(object.resume_ref)
        if not resume then return nil, "resume_ref is not an identifier" end
        if resume:sub(1, 1) == "-" then return nil, "resume_ref must not be a command-line option" end
    end
    return {profile_id = profile_id, brief = brief, resume_ref = resume}, nil
end
function M.specification(request: Request): types.Launch
    local environment: {string} = {}
    if request.profile_id == "window" then
        -- The TUI takes a project path positionally, never a prompt, so a
        -- brief travels in the documented --prompt option instead.
        local argv: {string} = {}
        if request.resume_ref then
            argv[#argv + 1] = "--session"
            argv[#argv + 1] = request.resume_ref
        end
        if request.brief ~= "" then
            argv[#argv + 1] = "--prompt"
            argv[#argv + 1] = request.brief
        end
        return {executable = "opencode", argv = argv, environment = environment, readiness = "terminal:attached",
            login = {provider = "opencode", command = "opencode auth login", files = {{variable = "HOME", path = ".local/share/opencode/auth.json"}}}}
    end
    -- The brief travels as the run message in argv. OpenCode never reads a
    -- prompt from stdin, so the launch declares no stdin at all; an inbox
    -- item arrives as a new admitted process through dispatch while stdin
    -- stays closed.
    local argv: {string} = {"run", "--format", "json"}
    if request.resume_ref then
        argv[#argv + 1] = "--session"
        argv[#argv + 1] = request.resume_ref
    end
    argv[#argv + 1] = "--"
    argv[#argv + 1] = request.brief
    return {executable = "opencode", argv = argv, environment = environment, readiness = "protocol:thread.started"}
end
return M
