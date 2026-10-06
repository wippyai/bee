-- MIT. Stands in for the window facades: it reports the session it was asked
-- to resume, or the text it was asked to type, to the test listening under
-- its name.
local process = require("process")
local function report(topic: string, value: {[string]: unknown})
    local listener = process.registry.lookup("bee.test.resume_probe")
    if listener then process.send(tostring(listener), topic, value) end
end
local function handle(request: unknown): {[string]: unknown}
    local body = request :: {[string]: unknown}
    report("bee.test.resumed", {session = body.session})
    return {ok = true, value = {session = body.session}}
end
local function type_text(request: unknown): {[string]: unknown}
    local body = request :: {[string]: unknown}
    report("bee.test.typed", {session = body.session, text = body.text})
    return {ok = true, value = {typed = true}}
end
return {handle = handle, type_text = type_text}
