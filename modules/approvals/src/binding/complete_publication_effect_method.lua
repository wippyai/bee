-- MIT. Record completion after the effect owner reads its durable Hub receipt.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.complete_publication_effect(request)
end
return {handle = handle}
