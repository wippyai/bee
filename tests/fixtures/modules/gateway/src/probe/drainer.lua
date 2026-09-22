-- MIT. Drains the gateway after a pause, while the probe is inside a wait.
local funcs = require("funcs")
local time = require("time")
local function main(pause: string?)
    time.sleep(pause or "400ms")
    local reply, err = funcs.call("bee.gateway.binding:drain", {deadline_ms = 5000})
    assert(not err and type(reply) == "table" and (reply :: {[string]: unknown}).ok == true, "drain: " .. tostring(err))
end
return {main = main}
