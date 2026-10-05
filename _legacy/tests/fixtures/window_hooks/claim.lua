-- MIT. Fixture latency around the real gateway operation. No reply is faked.
local time = require("time")
local gateway = require("gateway")
local function handle(request: unknown): gateway.Reply
    time.sleep("3s")
    return gateway.hook_claim(request)
end
return {handle = handle}
