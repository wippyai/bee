-- MIT. Physical directory containment at the native filesystem boundary.
local exec = require("exec")
local quote = require("quote")
local M = {}

function M.resolve(path: string, executor_ref: string): (string?, string?)
    if path:sub(1, 1) ~= "/" or #path > 8192 or path:find("[%c]") then return nil, "invalid absolute directory" end
    local executor, err = exec.get(executor_ref)
    if not executor then return nil, tostring(err) end
    local proc, command_error = executor:exec(quote.line({"sh", "-c", 'CDPATH= cd -P -- "$1" && pwd -P', "bee-path", path}))
    if not proc then executor:release(); return nil, tostring(command_error) end
    local stdout = proc:stdout_stream()
    local started, start_error = proc:start()
    if not started then executor:release(); return nil, tostring(start_error) end
    local output = stdout:read(8194)
    stdout:close()
    local code, wait_error = proc:wait()
    executor:release()
    if code ~= 0 or wait_error or type(output) ~= "string" then return nil, "cannot resolve directory " .. path end
    local physical = (output :: string):gsub("\n$", "")
    if physical:sub(1, 1) ~= "/" or physical:find("[%c]") then return nil, "invalid physical directory" end
    return physical, nil
end

function M.contains(root: string, path: string): boolean
    return root == "/" or path == root or path:sub(1, #root + 1) == root .. "/"
end

function M.admit(path: string, roots: {string}, executor_ref: string): (string?, string?)
    local physical, err = M.resolve(path, executor_ref)
    if not physical then return nil, err end
    for _, root in ipairs(roots) do
        local admitted, root_error = M.resolve(root, executor_ref)
        if not admitted then return nil, root_error end
        if M.contains(admitted, physical) then return physical, nil end
    end
    return nil, "directory is outside write-granted roots: " .. physical
end
return M
