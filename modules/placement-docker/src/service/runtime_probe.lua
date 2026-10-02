-- SPDX-License-Identifier: MIT
local exec = require("exec")
local uuid = require("uuid")
local bounds = require("bounds")
local quote = require("quote")
local resources = require("resources")
local capture = require("capture")
local M = {}
function M.command(image: string, runtime: string, raw: unknown, name: string): ({string}?, string?)
    local args = bounds.array(raw, 8)
    if not args or #args == 0 then return nil, "Docker probe requires bounded arguments" end
    if not name:match("^bee%-probe%-%x[%x%-]+$") or not runtime:match("^[A-Za-z0-9_.%-]+$") or (#image ~= 71 or not image:match("^sha256:[0-9a-f]+$")) then return nil, "Docker probe requires an immutable image and private identity" end
    local argv: {string} = {"docker", "run", "--pull=never", "--rm", "--name", name, "--network", "none", "--read-only",
        "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--pids-limit", "32", "--memory", "256m", "--user", "1000:1000",
        "--env", "HOME=/home/bee", "--tmpfs", "/home/bee:rw,nosuid,nodev,size=16m", "--entrypoint", runtime, image}
    for _, raw_arg in ipairs(args) do
        local arg = bounds.line(raw_arg, 128)
        if not arg then return nil, "Docker probe argument is invalid" end
        argv[#argv + 1] = arg
    end
    return argv, nil
end
function M.run(raw_client: unknown, image: string, runtime: string, raw: unknown): (string?, string?)
    local client = bounds.object(raw_client)
    local remove = client and client.remove_container
    if not client or type(remove) ~= "function" then return nil, "Docker cleanup client is invalid" end
    local id = uuid.v7()
    if not id then return nil, "Docker probe identity unavailable" end
    local name = "bee-probe-" .. id
    local argv, command_error = M.command(image, runtime, raw, name)
    if not argv then return nil, command_error end
    local ref, reference_error = resources.executor()
    local executor = ref and exec.get(ref)
    if not executor then return nil, reference_error or "Docker probe executor unavailable" end
    local child, err = executor:exec(quote.line(argv))
    if not child then executor:release(); return nil, tostring(err) end
    local stdout, stderr = child:stdout_stream(), child:stderr_stream()
    if not stdout or not stderr then child:close(true); executor:release(); return nil, "Docker probe streams unavailable" end
    local started, start_error = child:start()
    if not started then remove(client, name, true); child:close(true); stdout:close(); stderr:close(); executor:release(); return nil, tostring(start_error) end
    local proc: capture.Process = {wait = function(_self) return child:wait() end, close = function(_self, force) child:close(force) end}
    local output: capture.Stream = {read = function(_self: capture.Stream, size: integer): (unknown, unknown) local value, err = stdout:read(size); return value, err end, close = function(_self) stdout:close(); return nil end}
    local errors: capture.Stream = {read = function(_self: capture.Stream, size: integer): (unknown, unknown) local value, err = stderr:read(size); return value, err end, close = function(_self) stderr:close(); return nil end}
    local text, code, failure = capture.capture(proc, output, errors, function() executor:release() end, 3000, 65536)
    remove(client, name, true)
    if code ~= 0 or failure then return nil, failure or "Docker runtime probe failed" end
    return text, nil
end
return M
