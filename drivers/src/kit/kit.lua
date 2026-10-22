-- MIT. The host-facing driver kit: the activated drivers with their profiles
-- and declared options, a launch or configuration through a driver binding,
-- and one CLI output stream folded into records. It adds no authority: every
-- call goes through the activated binding under the caller's policies.
local registry = require("registry")
local contract = require("contract")
local bounds = require("bounds")
local resolver = require("resolver")
local profile_codec = require("profile")
local descriptor = require("descriptor")
local stream_json = require("stream_json")
local M = {}
M.CONTRACT = "bee.drivers:driver"
type Object = {[string]: unknown}
type Profile = {id: string, mode: string, protocol: string}
type Driver = {binding_ref: string, driver_id: string, title: string, descriptor_ref: string?, default_profile: string?,
    profiles: {Profile}, options: Object}
type Step = {observations: {Object}, terminal: Object?}
type Stream = {feed: (Stream, string) -> (Step?, string?), finish: (Stream) -> (Step?, string?)}

local function driver_of(pinned: registry.Snapshot, ref: string): (Driver?, string?)
    local binding, binding_error = resolver.entry(pinned, ref)
    if binding_error then return nil, binding_error end
    local meta = binding and bounds.object(binding.meta)
    if not binding or binding.kind ~= "contract.binding" or not meta or meta.type ~= "harness.driver" then
        return nil, ref .. " is not a driver binding"
    end
    local driver_id = bounds.id(meta.driver_id)
    if not driver_id then return nil, ref .. " has no driver_id" end
    local result: Driver = {binding_ref = ref, driver_id = driver_id, title = driver_id, profiles = {}, options = {}}
    local profiles_ref = bounds.id(meta.profiles_ref)
    if profiles_ref then
        local entry, entry_error = resolver.entry(pinned, profiles_ref)
        if entry_error then return nil, entry_error end
        local data = entry and bounds.object(entry.data)
        local decoded, decode_error = profile_codec.decode(data and data.driver)
        if not decoded then return nil, ref .. " profiles: " .. tostring(decode_error) end
        result.title = decoded.title
        result.default_profile = decoded.default_profile
        for _, item in ipairs(decoded.profiles) do
            result.profiles[#result.profiles + 1] = {id = item.id, mode = item.mode, protocol = item.protocol}
        end
    end
    local descriptor_ref = bounds.id(meta.descriptor_ref)
    if descriptor_ref then
        local loaded, load_error = descriptor.load_from(pinned, descriptor_ref)
        if not loaded then return nil, ref .. " descriptor: " .. tostring(load_error) end
        result.descriptor_ref = descriptor_ref
        result.options = bounds.object(loaded.options.fields) or {}
    end
    return result, nil
end

-- catalog lists the drivers the host activated, ordered by binding.
function M.catalog(): ({Driver}?, string?)
    local pinned, pin_error = registry.snapshot()
    if not pinned then return nil, tostring(pin_error) end
    local active, active_error = resolver.active(pinned)
    if not active then return nil, active_error end
    local refs: {string} = {}
    for ref in pairs(active) do refs[#refs + 1] = ref end
    table.sort(refs)
    local drivers: {Driver} = {}
    for _, ref in ipairs(refs) do
        local driver, driver_error = driver_of(pinned, ref)
        if not driver then return nil, driver_error end
        drivers[#drivers + 1] = driver
    end
    return drivers, nil
end

local function call(binding_ref: string, method: string, request: unknown): (Object?, string?)
    local pinned, pin_error = registry.snapshot()
    if not pinned then return nil, tostring(pin_error) end
    local active, active_error = resolver.active(pinned)
    if not active then return nil, active_error end
    if not active[binding_ref] then return nil, "driver binding " .. binding_ref .. " is not activated" end
    local instance, open_error = contract.open(binding_ref)
    if not instance then return nil, "open " .. binding_ref .. ": " .. tostring(open_error) end
    local reply, call_error = instance[method](instance, request)
    if call_error then return nil, binding_ref .. " " .. method .. ": " .. tostring(call_error) end
    local object = bounds.object(reply)
    if not object then return nil, binding_ref .. " " .. method .. " returned no object" end
    return object, nil
end

-- prepare returns the declarative launch for a request: profile_id, brief,
-- the declared option values and the placement isolation.
function M.prepare(binding_ref: string, request: Object): (Object?, string?)
    local reply, err = call(binding_ref, "prepare", request)
    if not reply then return nil, err end
    if reply.ok ~= true then return nil, tostring(reply.error or "launch refused") end
    return assert(bounds.object(reply.launch)), nil
end

-- configure returns the arguments and private-home files a configuration
-- request selects.
function M.configure(binding_ref: string, request: Object): (Object?, string?)
    local reply, err = call(binding_ref, "configure", request)
    if not reply then return nil, err end
    if reply.ok ~= true then return nil, tostring(reply.error or "configuration refused") end
    return reply, nil
end

-- stream folds one CLI output stream through the binding's normalizer:
-- feed accepts raw output chunks, finish settles the stream at its end.
function M.stream(binding_ref: string, resumed: boolean?): Stream
    local decoder = stream_json.new(nil)
    local state: unknown = nil
    local index = 0
    local function step(request: Object, observations: {Object}): (Object?, string?)
        if state ~= nil then request.state = state else request.resumed = resumed == true end
        local reply, err = call(binding_ref, "normalize", request)
        if not reply then return nil, err end
        if reply.ok ~= true then return nil, tostring(reply.error or "normalizer refused the envelope") end
        state = reply.state
        for _, observation in ipairs(bounds.array(reply.observations or {}, 4096) or {}) do observations[#observations + 1] = observation end
        return bounds.object(reply.terminal), nil
    end
    local stream: Stream = {
        feed = function(_self: Stream, chunk: string): (Step?, string?)
            local envelopes, problems, feed_error = stream_json.feed(decoder, chunk)
            if feed_error then return nil, feed_error end
            local observations: {Object} = {}
            local terminal: Object? = nil
            for _, problem in ipairs(problems) do
                observations[#observations + 1] = {type = "notice", level = "warning", code = "stream_problem", content = {text = problem.message}}
            end
            for _, envelope in ipairs(envelopes) do
                index = envelope.index
                local reported, err = step({index = envelope.index, envelope = envelope.value}, observations)
                if err then return nil, err end
                terminal = reported or terminal
            end
            return {observations = observations, terminal = terminal}, nil
        end,
        finish = function(_self: Stream): (Step?, string?)
            local problem = stream_json.finish(decoder)
            local observations: {Object} = {}
            if problem then
                observations[#observations + 1] = {type = "notice", level = "warning", code = "stream_problem", content = {text = problem.message}}
            end
            local terminal, err = step({index = index + 1, eof = true}, observations)
            if err then return nil, err end
            return {observations = observations, terminal = terminal}, nil
        end,
    }
    return stream
end

return M
