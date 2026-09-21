local process = require("process")
local sql = require("sql")
local security = require("security")
local function main(): {pid: string, actor: string, storage_denied: boolean}
    local database, err = sql.get("bee.thread_demo:db")
    if database then database:release() end
    local actor = security.actor()
    return {pid = tostring(process.pid()), actor = actor and actor:id() or "", storage_denied = database == nil and err ~= nil}
end
return {main = main}
