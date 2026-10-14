-- MIT. Resource authority method revoke_all: the caller's actor, the linked store, one operation.
local authority = require("authority")
local revocation_stops = require("revocation_stops")
local function handle(request: unknown): authority.Reply
    return revocation_stops.apply(authority.revoke_all(request), false)
end
return {handle = handle}
