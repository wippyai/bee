-- MIT
local security = require("security")

local function probe(_raw: unknown): {[string]: boolean}
    return {exposed = security.can("hive.expose.open", "arbitrary.sdk:run"),
        other = security.can("hive.expose.open", "arbitrary.sdk:other"),
        policy = security.can("hive.expose.policy", "arbitrary.sdk:run"),
        registry = security.can("registry.get", "bee:db")}
end

return {probe = probe}
