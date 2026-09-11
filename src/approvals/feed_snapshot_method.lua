-- MIT. Visibility-scoped owner ledger adapter.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.feed_snapshot(request)
end
return {handle = handle}
