-- SPDX-License-Identifier: MIT
local process = require("process")
local security = require("security")
local ctx = require("ctx")
local function main(value: unknown, name: string, token: string, operation_key: string, supervisor: string)
    assert(process.registry.register(name))
    local actor = assert(security.actor())
    assert(process.send(supervisor, "bee.session.window.reply", {ok = true, caller_token = token, value = {
        pid = tostring(process.pid()), actor = actor:id(), workspace = ctx.get("bee.workspace_id"),
        ceiling = ctx.get("bee.agent.trait_ceiling"), operation_key = operation_key}}))
    local events = assert(process.events())
    while true do
        local event = events:receive()
        if not event or event.kind == process.event.CANCEL then return end
    end
end
return {main = main}
