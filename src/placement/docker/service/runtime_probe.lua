-- SPDX-License-Identifier: MIT
local uuid = require("uuid")
local bounds = require("bounds")
local daemon = require("daemon")
local M = {}
function M.command(image: string, runtime: string, raw: unknown, name: string): ({string}?, string?)
    local args = bounds.array(raw, 8)
    if not args or #args == 0 then return nil, "Docker probe requires bounded arguments" end
    if not name:match("^bee%-probe%-%x[%x%-]+$") or not runtime:match("^[A-Za-z0-9_.%-]+$") or (#image ~= 71 or not image:match("^sha256:[0-9a-f]+$")) then return nil, "Docker probe requires an immutable image and private identity" end
    local argv: {string} = {"docker", "--host", "unix:///var/run/docker.sock", "run", "--pull=never", "--rm", "--name", name, "--network", "none", "--read-only",
        "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--pids-limit", "32", "--memory", "256m", "--user", "1000:1000",
        "--env", "HOME=/home/bee", "--tmpfs", "/home/bee:rw,nosuid,nodev,size=16m", "--entrypoint", runtime, image}
    for _, raw_arg in ipairs(args) do
        local arg = bounds.line(raw_arg, 128)
        if not arg then return nil, "Docker probe argument is invalid" end
        argv[#argv + 1] = arg
    end
    return argv, nil
end
function M.run(image: string, runtime: string, raw: unknown): (string?, string?)
    local id = uuid.v7()
    if not id then return nil, "Docker probe identity unavailable" end
    local name = "bee-probe-" .. id
    local argv, command_error = M.command(image, runtime, raw, name)
    if not argv then return nil, command_error end
    local output, failure = daemon.command(argv)
    local remaining, inspect_error = daemon.inspect("container", name)
    if inspect_error then return nil, (failure and failure .. "; " or "") .. inspect_error end
    if remaining then
        local removed, remove_error = daemon.command({"docker", "--host", "unix:///var/run/docker.sock", "rm", "--force", name})
        if not removed then return nil, (failure and failure .. "; " or "") .. tostring(remove_error) end
    end
    return output, failure
end
return M
