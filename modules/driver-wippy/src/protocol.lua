-- MIT. Native Wippy driver protocol.
local M = {}
M.PROTOCOL_REVISION = "native-1"

type State = {
    resumed: boolean,
    terminal: {[string]: unknown}?,
}

type Step = {
    observations: {{[string]: unknown}},
    terminal: {[string]: unknown}?,
}

function M.new(resumed: boolean): State
    return {resumed = resumed, terminal = nil}
end

function M.normalize(state: State, index: integer, envelope: {[string]: unknown}): Step
    return {observations = {}, terminal = nil}
end

function M.finish(state: State, index: integer): Step
    return {observations = {}, terminal = state.terminal}
end

return M
