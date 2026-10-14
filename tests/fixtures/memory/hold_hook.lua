local process = require("process")
local bounds = require("bounds")
local function handle(raw: unknown): {[string]: unknown}
    local turn = assert(bounds.object(raw))
    local input = assert(bounds.object(turn.input))
    local release = assert(process.listen("bee.tests.hook.release", {message = true}))
    assert(process.send(assert(bounds.id(input.controller)), "bee.tests.hook.ready", {pid = tostring(process.pid()), invocation_id = turn.invocation_id}))
    assert((release:receive()))
    process.unlisten(release)
    if input.mode == "held_change" then return {kind = "change", input = {text = tostring(input.text) .. ":a"}} end
    return {kind = "deny", reason = "fixture concurrent denial"}
end
return {handle = handle}
