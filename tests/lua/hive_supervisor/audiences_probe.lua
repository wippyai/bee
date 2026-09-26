-- MIT. Test support: replace the host exposure audience table rows.
local registry = require("registry")
local audiences = require("audiences")
local function install(value: unknown): {ok: boolean}
    local entry = registry.get(audiences.ENTRY)
    if not entry then error("audiences entry is absent") end
    local data = (entry :: {[string]: unknown}).data
    if type(data) ~= "table" then error("audiences data is missing") end
    (data :: {[string]: unknown}).audiences = value
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("install audiences: " .. tostring(err)) end
    return {ok = true}
end
return {install = install}
