-- MIT. Read-only desktop attention summary through the approval owner.
local service = require("service")
local function handle(request: unknown): service.Reply return service.attention_count(request) end
return {handle = handle}
