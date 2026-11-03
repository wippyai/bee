-- MIT. Tries every filesystem operation on a granted folder and its watch
-- source under the caller's scope and reports what the runtime allowed.
local fs = require("fs")
local security = require("security")
type Request = {folder: string, source: string}
type Result = {read: string?, writefile: boolean, open_write: boolean, mkdir: boolean, remove: boolean,
    source_get: boolean, watch_folder: boolean, watch_source: boolean}
local function run(request: Request): Result
    local result: Result = {writefile = false, open_write = false, mkdir = false, remove = false,
        source_get = false, watch_folder = security.can("ioevents.watch", request.folder),
        watch_source = security.can("ioevents.watch", request.source)}
    local source = fs.get(request.source)
    result.source_get = source ~= nil
    local folder = fs.get(request.folder)
    if not folder then return result end
    result.read = folder:readfile("/kept.txt")
    result.writefile = folder:writefile("/kept.txt", "changed\n") == true
    local file = folder:open("/created.txt", "w")
    result.open_write = file ~= nil
    if file then file:close() end
    result.mkdir = folder:mkdir("/made") == true
    result.remove = folder:remove("/kept.txt") == true
    return result
end
return {run = run}
