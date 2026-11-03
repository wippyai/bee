-- MIT. Gateway method hub_publish: file a Hub publication request or poll
-- one, as the caller's actor through the linked store.
local publication = require("publication")
local bounds = require("bounds")
local function handle(request: unknown): publication.Reply
    local object = bounds.object(request)
    local operation = object and object.operation
    if operation == "publish" then return publication.publish_request(request) end
    if operation == "status" then return publication.publish_status(request) end
    return {ok = false, value = nil, error = {code = "INVALID", message = "operation must be publish or status"}}
end
return {handle = handle}
