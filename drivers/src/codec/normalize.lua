-- MIT. Shared driver request boundary for normalizer methods.
local bounds = require("bounds")
local M = {}

type Step = {observations: {{[string]: unknown}}, terminal: unknown?}
type Protocol<State> = {
    new: (boolean) -> State,
    decode_state: (unknown) -> (State?, string?),
    normalize: (State, integer, {[string]: unknown}) -> (Step?, string?),
    finish: (State, integer) -> (Step?, string?),
}
type Reply<State> = {ok: boolean, error: string?, state: State?, observations: {{[string]: unknown}}?, terminal: unknown}

function M.handle<State>(raw: unknown, protocol: Protocol<State>): Reply<State>
    local request = bounds.object(raw)
    if not request then return {ok = false, error = "request must be an object"} end
    local unknown = bounds.fields(request, {"state", "index", "envelope", "eof", "resumed", "context"})
    if unknown then return {ok = false, error = unknown} end
    local index = bounds.count(request.index)
    if not index then return {ok = false, error = "index must be a nonnegative integer"} end
    local resumed = false
    if request.resumed ~= nil then
        if type(request.resumed) ~= "boolean" then return {ok = false, error = "resumed must be a boolean"} end
        resumed = request.resumed
    end
    local eof = false
    if request.eof ~= nil then
        if type(request.eof) ~= "boolean" then return {ok = false, error = "eof must be a boolean"} end
        eof = request.eof
    end
    local state: State
    if request.state == nil then
        state = protocol.new(resumed)
    else
        local decoded, state_error = protocol.decode_state(request.state)
        if not decoded then return {ok = false, error = state_error or "state is invalid"} end
        state = decoded
    end
    local step: Step?
    local step_error: string?
    if eof then
        if request.envelope ~= nil then return {ok = false, error = "eof request carries an envelope"} end
        step, step_error = protocol.finish(state, index)
    else
        local envelope = bounds.object(request.envelope)
        if not envelope then return {ok = false, error = "envelope must be an object"} end
        step, step_error = protocol.normalize(state, index, envelope)
    end
    if not step then return {ok = false, error = step_error or "normalizer rejected the request"} end
    return {ok = true, state = state, observations = step.observations, terminal = step.terminal}
end

function M.bind<State>(new: (boolean) -> State,
    decode_state: (unknown) -> (State?, string?),
    normalize: (State, integer, {[string]: unknown}) -> (Step?, string?),
    finish: (State, integer) -> (Step?, string?)): (unknown) -> Reply<State>
    local protocol: Protocol<State> = {new = new, decode_state = decode_state, normalize = normalize, finish = finish}
    return function(request: unknown) return M.handle(request, protocol) end
end

type Codec<State> = {
    new: (boolean) -> State,
    decode_state: (unknown) -> (State?, string?),
    normalize: (State, integer, {[string]: unknown}, {[string]: unknown}?) -> Step,
    finish: (State, integer) -> Step,
}

-- serve answers a codec function request: the normalizer request plus the
-- descriptor's json_paths, which select the codec's protocol fields.
function M.serve<State>(codec: Codec<State>): (unknown) -> Reply<State>
    return function(raw: unknown): Reply<State>
        local request = bounds.object(raw)
        if not request then return {ok = false, error = "request must be an object"} end
        local paths = bounds.object(request.json_paths == nil and {} or request.json_paths)
        if not paths then return {ok = false, error = "json_paths must be an object"} end
        local selected = assert(paths)
        local forwarded: {[string]: unknown} = {}
        for key, value in pairs(request) do
            if key ~= "json_paths" then forwarded[key] = value end
        end
        return M.handle(forwarded, {
            new = codec.new,
            decode_state = codec.decode_state,
            normalize = function(state: State, index: integer, envelope: {[string]: unknown}): (Step?, string?)
                return codec.normalize(state, index, envelope, selected), nil
            end,
            finish = function(state: State, index: integer): (Step?, string?) return codec.finish(state, index), nil end,
        })
    end
end

return M
