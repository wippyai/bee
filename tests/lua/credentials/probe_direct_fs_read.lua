-- MIT. Test probe attempting direct filesystem access on login file sources.
local fs = require("fs")

type Reply = {ok: boolean, stage: string, value: string?}
local function handle(ref: string): Reply
    local volume, err = fs.get(ref)
    if not volume then return {ok = false, stage = "get"} end
    local content, read_error = volume:readfile("auth.json")
    if not content or read_error then return {ok = false, stage = "read"} end
    return {ok = true, stage = "read", value = content}
end

return {handle = handle}
