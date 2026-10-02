-- MIT. The launch selectors use the host's private probe and validate its result.
local bounds = require("bounds")
local funcs = require("funcs")
local driver_locate = require("driver_locate")
local driver_types = require("driver_types")
local M = {}
M.PROBE = "bee.harness.binding:locate_probe"

type Probe = {located: boolean, result: driver_types.LocateResult?, error: string?}
type Cache = {[string]: Probe}

function M.new_cache(): Cache
    return {}
end

function M.probe(binding_ref: string, profile_id: string, cache: Cache, placement_profile_ref: string?): Probe
    local key = binding_ref .. "\n" .. profile_id .. "\n" .. (placement_profile_ref or "")
    local existing = cache[key]
    if existing and not placement_profile_ref then return existing end
    local raw, call_error = funcs.call(M.PROBE, {binding_ref = binding_ref, profile_id = profile_id, placement_profile_ref = placement_profile_ref})
    if call_error then
        local failed: Probe = {located = true, result = nil, error = tostring(call_error)}
        cache[key] = failed
        return failed
    end
    local reply = bounds.object(raw)
    if not reply or bounds.fields(reply, {"ok", "located", "result", "error"}) or reply.ok ~= true
        or type(reply.located) ~= "boolean" then
        local malformed: Probe = {located = true, result = nil, error = "host locate probe returned a malformed reply"}
        cache[key] = malformed
        return malformed
    end
    if reply.located == false then
        if reply.result ~= nil then
            local malformed: Probe = {located = true, result = nil, error = "host locate probe returned an unexpected result"}
            cache[key] = malformed
            return malformed
        end
        local unsupported: Probe = {located = false, result = nil, error = nil}
        cache[key] = unsupported
        return unsupported
    end
    local result, decode_error = driver_locate.decode(reply.result)
    if not result then
        local malformed: Probe = {located = true, result = nil, error = decode_error or "driver locate result is malformed"}
        cache[key] = malformed
        return malformed
    end
    local selected: Probe = {located = true, result = result, error = nil}
    cache[key] = selected
    return selected
end

return M
