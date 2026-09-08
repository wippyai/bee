-- MIT. A separate controller actor used to prove recipient-scoped detach.
local process = require("process")
local tty = require("tty")
local time = require("time")
local function main(owner: string)
    local commands = assert(process.listen("bee.controller.command", {message = true}))
    assert(process.send(owner, "bee.controller.status", "ready"))
    local bootstrap = assert(commands:receive())
    assert(bootstrap:from() == owner)
    local mount: unknown = bootstrap:payload():data()
    if type(mount) ~= "string" then error("Invalid controller mount") end
    local view, err = tty.attach(mount)
    if not view then error(tostring(err)) end
    assert(process.send(owner, "bee.controller.status", "attached"))
    local verify = assert(commands:receive())
    assert(verify:from() == owner and verify:payload():data() == "verify")
    assert(view:send({type = "paste", text = "printf 'BEE_OTHER_CLIENT_%s\\n' \"$$\""}))
    assert(view:send({type = "key", key = "enter", key_type = "enter", action = "press"}))
    local observed = false
    for _ = 1, 300 do
        local snapshot = assert(view:snapshot())
        if table.concat(snapshot.rows):match("BEE_OTHER_CLIENT_%d+") then observed = true; break end
        time.sleep("10ms")
    end
    assert(observed, "Another client's detach interrupted this controller")
    assert(process.send(owner, "bee.controller.status", "verified"))
    local stop = assert(commands:receive())
    assert(stop:from() == owner and stop:payload():data() == "stop")
    view:close()
    assert(process.send(owner, "bee.controller.status", "closed"))
    process.unlisten(commands)
end
return {main = main}
