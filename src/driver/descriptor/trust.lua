local bounds = require("bounds")
local json = require("json")
local toml = require("toml")
local canonical = require("canonical")
local paths = require("paths")
local exec = require("exec")
local quote = require("quote")
local M = {}
type Object = {[string]: unknown}
function M.admit(workdir: string, roots: {string}, executor_ref: string, repository_root: boolean, project_config: {string}?): (string?, string?)
    local physical, err = paths.admit(workdir, roots, executor_ref)
    if not physical then return nil, err end
    if repository_root then
        local executor, executor_error = exec.get(executor_ref)
        if not executor then return nil, tostring(executor_error) end
        local command = 'p="$1"; while :; do if [ -e "$p/.git" ]; then printf "%s" "$p"; exit 0; fi; [ "$p" = / ] && exit 0; p=${p%/*}; [ -n "$p" ] || p=/; done'
        local proc, command_error = executor:exec(quote.line({"sh", "-c", command, "bee-trust-root", physical}))
        if not proc then executor:release(); return nil, tostring(command_error) end
        local output = proc:stdout_stream()
        local started, start_error = proc:start()
        if not started then executor:release(); return nil, tostring(start_error) end
        local root = output:read(8194)
        output:close()
        local code, wait_error = proc:wait()
        executor:release()
        if code ~= 0 or wait_error or type(root) ~= "string" then return nil, "Cannot establish folder trust scope" end
        if root ~= "" and root ~= physical then return nil, "CLI folder trust would widen to repository root outside approved workdir: " .. root end
    end
    if project_config and #project_config > 0 then
        local executor, executor_error = exec.get(executor_ref)
        if not executor then return nil, tostring(executor_error) end
        local argv = {"sh", "-c", 'root="$1"; shift; for path do if [ -e "$root/$path" ]; then printf "%s" "$path"; exit 0; fi; done', "bee-trust-config", physical}
        for _, path in ipairs(project_config) do argv[#argv + 1] = path end
        local proc, command_error = executor:exec(quote.line(argv))
        if not proc then executor:release(); return nil, tostring(command_error) end
        local output = proc:stdout_stream()
        local started, start_error = proc:start()
        if not started then executor:release(); return nil, tostring(start_error) end
        local found, read_error = output:read(8194)
        output:close()
        local code, wait_error = proc:wait()
        executor:release()
        if read_error and tostring(read_error) ~= "EOF" then return nil, "Cannot inspect project configuration trust" end
        if found == nil then found = "" end
        if code ~= 0 or wait_error or type(found) ~= "string" then return nil, "Cannot inspect project configuration trust" end
        if found ~= "" then return nil, "Folder trust would activate project configuration outside the host ceiling: " .. found end
    end
    return physical, nil
end
function M.render(mapping: Object, workdir: string?, source: string?): (string?, string?)
    local parsed: unknown = json.decode("{}")
    if source and source ~= "" then
        if mapping.format == "json" then parsed = json.decode(source)
        elseif mapping.format == "toml" then parsed = toml.decode(source)
        else return nil, "Unsupported trust configuration format" end
    end
    local document = bounds.object(parsed)
    if not document then return nil, "Isolated trust configuration is invalid" end
    local projects = document.projects == nil and bounds.object(json.decode("{}")) or bounds.object(document.projects)
    if not projects then return nil, "Isolated trust projects must be an object" end
    local key = bounds.id(mapping.key)
    if not key then return nil, "Invalid trust key" end
    for _, raw in pairs(projects) do
        local project = bounds.object(raw)
        if not project then return nil, "Isolated trust project must be an object" end
        project[key] = nil
    end
    if workdir then
        local project = projects[workdir] == nil and {} or bounds.object(projects[workdir])
        if not project then return nil, "Isolated trust project must be an object" end
        project[key] = mapping.value
        projects[workdir] = project
    end
    document.projects = projects
    if mapping.format == "json" then return canonical.encode(document) end
    return toml.encode(document)
end
return M
