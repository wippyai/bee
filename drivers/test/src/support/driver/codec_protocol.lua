-- MIT. A codec library folded in process with the JSON paths of the CLI
-- descriptor that selects it, for suites that drive a codec directly.
local descriptor = require("descriptor")
local bounds = require("bounds")
local M = {}
type Object = {[string]: unknown}
type Step = {observations: {Object}, terminal: unknown?}
type Codec<State> = {
    PROTOCOL_REVISION: string,
    MAX_ANSWER_BYTES: integer,
    new: (boolean) -> State,
    decode_state: (unknown) -> (State?, string?),
    normalize: (State, integer, Object, Object?) -> Step,
    finish: (State, integer) -> Step,
}
type Protocol<State> = {
    revision: () -> string,
    max_answer_bytes: () -> integer,
    new: (boolean) -> State,
    decode_state: (unknown) -> (State?, string?),
    normalize: (State, integer, Object) -> Step,
    finish: (State, integer) -> Step,
}
function M.of<State>(codec: Codec<State>, ref: string): Protocol<State>
    local function paths(): Object
        local selected, load_error = descriptor.load(ref)
        if not selected then error(tostring(load_error)) end
        return bounds.object(selected.json_paths) or {}
    end
    return {
        revision = function(): string return codec.PROTOCOL_REVISION end,
        max_answer_bytes = function(): integer return codec.MAX_ANSWER_BYTES end,
        new = codec.new,
        decode_state = codec.decode_state,
        normalize = function(state: State, index: integer, envelope: Object): Step return codec.normalize(state, index, envelope, paths()) end,
        finish = codec.finish,
    }
end
return M
