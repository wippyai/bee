-- MIT. Credential broker method write_back: one provider token file only.
local broker = require("broker")
local function handle(request: unknown): broker.Reply
    return broker.write_back(request)
end
return {handle = handle}
