-- MIT. No method policy: authoring rights must not become DB/overlay rights.
local sql = require("sql")
local registry = require("registry")
local function handle(): boolean
    local db = sql.get("bee.gov:db")
    if db then db:release(); return true end
    local overlay = registry.overlay("bee.gov:agent")
    return overlay ~= nil
end
return {handle = handle}
