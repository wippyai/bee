-- MIT. A retained owner may construct its terminal spawn options without changing caller identity.
local process = require("process")
local security = require("security")
return {handle = function(): {[string]: unknown}
    assert(process.with_options({}))
    local actor = assert(security.actor())
    return {ok = true, value = {owner = actor:id(), workspace = actor:meta().workspace_id,
        terminal_spawn = security.can("process.context", "context")}}
end}
