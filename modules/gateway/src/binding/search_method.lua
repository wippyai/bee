-- MIT. Gateway method search: the agent sessions of one workspace, as a workspace extension.
local gateway = require("gateway")
local function handle(request: unknown): gateway.Reply
    return gateway.search(request)
end
return {handle = handle}
