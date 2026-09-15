-- MIT. Credential broker availability checks one admitted provider login file
-- by stat only; it never reads or returns secret bytes.
local broker = require("broker")
local function handle(request: unknown): broker.Reply
    return broker.availability(request)
end
return {handle = handle}
