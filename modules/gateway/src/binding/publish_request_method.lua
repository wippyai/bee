-- MIT. Gateway method publish_request: the caller's actor, the linked store, one operation.
local publication = require("publication")
local function handle(request: unknown): publication.Reply
    return publication.publish_request(request)
end
return {handle = handle}
