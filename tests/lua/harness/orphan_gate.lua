-- MIT. Pipe-holding descendants wait for the test's explicit release.
local exec = require("exec")
local quote = require("quote")
local M = {}
local function shell(command: string)
    local executor = assert(exec.get("bee.placement.native.env:placement_executor"))
    local child = assert(executor:exec(command))
    assert(child:start())
    local code, wait_error = child:wait()
    executor:release()
    assert(code == 0, "orphan gate command failed: " .. tostring(wait_error or code))
end
function M.create(path: string)
    shell("mkfifo -- " .. quote.posix(path))
end
function M.release(path: string)
    shell("bash -c " .. quote.posix("exec 3<>" .. quote.posix(path) .. "; printf 'release\\n' >&3; rm -- " .. quote.posix(path)))
end
return M
