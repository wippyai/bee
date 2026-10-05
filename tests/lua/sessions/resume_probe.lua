-- MIT. Stands in for the window resume facade: it reports the session it was
-- asked to resume to the test listening under its name.
local process = require("process")
local function handle(request: unknown): {[string]: unknown}
    local body = request :: {[string]: unknown}
    local listener = process.registry.lookup("bee.test.resume_probe")
    if listener then process.send(tostring(listener), "bee.test.resumed", {session = body.session}) end
    return {ok = true, value = {session = body.session}}
end
return {handle = handle}
