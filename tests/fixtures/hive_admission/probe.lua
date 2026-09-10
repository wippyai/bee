-- SPDX-License-Identifier: MIT
-- Harmless probe and authorized child process for hive admission proof.
local process = require("process")

type ProbeDone = {
    status: string
}

local function main(coordinator_pid: unknown, topic: unknown, token: unknown): ProbeDone
    if type(coordinator_pid) == "string" and type(topic) == "string" and type(token) == "string" then
        local reply_payload = {
            version = 1,
            kind = "probe_ready",
            host = tostring(process.pid()),
            token = token
        }
        assert(process.send(coordinator_pid, topic, reply_payload))
    end
    return {status = "done"}
end

return {main = main}
