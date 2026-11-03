-- MIT. Opens a watch as the calling actor and reports the refusal it meets.
local fs = require("fs")
local ioevents = require("ioevents")

local function probe(volume: string): string
    local files, get_error = fs.get(volume)
    if not files then return tostring(get_error) end
    local watch, err = ioevents.watch(files, ".")
    if watch then
        watch:close()
        return "watched"
    end
    return tostring(err)
end

return {probe = probe}
