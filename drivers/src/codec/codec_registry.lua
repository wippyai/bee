-- MIT. Codecs are function entries a driver package registers with meta
-- type bee.driver.codec and meta.codec naming the protocol a CLI descriptor
-- selects. Each answers one normalizer request carrying the descriptor's
-- json_paths.
local funcs = require("funcs")
local bounds = require("bounds")
local M = {}

M.TYPE = "bee.driver.codec"

type Object = {[string]: unknown}

-- find returns the function entry that registers codec_id.
function M.find(pinned: registry.Snapshot, codec_id: string): (string?, string?)
    local found, find_error = pinned:find({[".kind"] = "function.lua", ["meta.type"] = M.TYPE, ["meta.codec"] = codec_id})
    if find_error or not found then return nil, "codec registrations are unreadable: " .. tostring(find_error) end
    if #found == 0 then return nil, "no driver package registers codec " .. codec_id end
    if #found > 1 then return nil, "codec " .. codec_id .. " is registered more than once" end
    local id = bounds.id((bounds.object(found[1]) or {}).id)
    if not id then return nil, "codec " .. codec_id .. " registration has no identity" end
    return id, nil
end

-- bind returns the normalizer that calls one codec function with the
-- json_paths of the descriptor that selects it.
function M.bind(target: string, json_paths: Object): (unknown) -> unknown
    return function(raw: unknown): unknown
        local request = bounds.object(raw)
        if not request then return {ok = false, error = "request must be an object"} end
        local forwarded: Object = {}
        for key, value in pairs(request) do forwarded[key] = value end
        forwarded.json_paths = json_paths
        local reply, call_error = funcs.call(target, forwarded)
        if call_error then return {ok = false, error = "codec " .. target .. ": " .. tostring(call_error)} end
        return reply
    end
end

return M
