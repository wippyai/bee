-- SPDX-License-Identifier: MIT
local uuid = require("uuid")
local bounds = require("bounds")
local daemon = require("daemon")
local hash = require("hash")
local canonical = require("canonical")
local measurements = require("measurements")
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
local function capture(image: string, runtime: string, raw: unknown): (string?, string?)
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
-- A probe's output depends only on the immutable image and its arguments; it
-- is recorded once among the measurements under that address.
local function key_of(image: string, runtime: string, raw: unknown): string?
    local encoded = canonical.encode({image = image, runtime = runtime, args = raw})
    return encoded and hash.sha256(encoded) or nil
end
local function recorded(key: string): (string?, string?)
    local db, db_error = measurements.open()
    if not db then return nil, "probe measurements unavailable: " .. tostring(db_error) end
    local value = bounds.object(measurements.find_addressed(db, key))
    db:release()
    return value and bounds.text(value.output, 131072) or nil, nil
end
local function record(key: string, image: string, output: string): string?
    local db, db_error = measurements.open()
    if not db then return "probe measurements unavailable: " .. tostring(db_error) end
    local record_error = measurements.record_addressed(db, key, image, {output = output})
    db:release()
    return record_error
end
function M.run(image: string, runtime: string, raw: unknown): (string?, string?)
    local key = key_of(image, runtime, raw)
    if not key then return nil, "Docker probe identity cannot be measured" end
    local known, lookup_error = recorded(key)
    if lookup_error then return nil, lookup_error end
    if known then return known, nil end
    local output, failure = capture(image, runtime, raw)
    if output and not failure then
        local record_error = record(key, image, output)
        if record_error then return nil, record_error end
    end
    return output, failure
end
return M
