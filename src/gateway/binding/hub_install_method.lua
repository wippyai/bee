-- MIT. Gateway method hub_install: file an installation or removal request
-- or poll one, as the caller's actor through the linked store.
local gateway = require("gateway")
local bounds = require("bounds")
local function handle(request: unknown): gateway.Reply
    local object = bounds.object(request)
    local operation = object and object.operation
    if operation == "install" then return gateway.install_request(request) end
    if operation == "uninstall" then return gateway.uninstall_request(request) end
    if operation == "status" then return gateway.install_status(request) end
    return {ok = false, value = nil, error = {code = "INVALID", message = "operation must be install, uninstall or status"}}
end
return {handle = handle}
