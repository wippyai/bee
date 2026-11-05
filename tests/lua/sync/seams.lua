-- SPDX-License-Identifier: MIT
-- The suite hygiene owner asks the sync service, by bee.test.sync.idle, to
-- settle and answer once none of its workers is woken or distributing.
local process = require("process")
local workers: {[string]: string} = {}
local observer: {pid: string, topic: string}? = nil

local function answer()
    if not observer then return end
    for _, state in pairs(workers) do
        if state == "pending" or state == "busy" then return end
    end
    local reply = observer
    observer = nil
    assert(process.send(reply.pid, reply.topic, {}))
end

return {
    ["bee.sync.service.inspections"] = function(): unknown
        return assert(process.listen("bee.test.sync.idle", {message = true}))
    end,
    ["bee.sync.service.worker"] = function(payload: unknown?): unknown
        local change = payload :: {key: string, state: string}
        workers[change.key] = change.state
        answer()
        return nil
    end,
    ["bee.sync.service.inspected"] = function(payload: unknown?): unknown
        local message = payload :: process.Message
        local controller = process.registry.lookup("bee.test.hygiene", process.registry.LOCAL)
        local data = message:payload():data()
        assert(controller and tostring(controller) == tostring(message:from()) and type(data) == "table"
            and type(data.topic) == "string", "sync inspection from the hygiene owner")
        observer = {pid = tostring(message:from()), topic = data.topic}
        answer()
        return nil
    end,
}
