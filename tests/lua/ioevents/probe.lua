-- MIT. Opens a watch as the calling actor and reports the refusal it meets.
local ioevents = require("ioevents")

local function probe(volume: string): string
    local watch, err = ioevents.watch(volume, ".")
    if watch then
        watch:close()
        return "watched"
    end
    return tostring(err)
end

return {probe = probe}
