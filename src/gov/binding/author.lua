-- MIT. The person-facing name of the agent that makes a version: the title of
-- the definition its session runs, read through the public Sessions contract
-- as the author itself. A caller that is no session has no name.
local bounds = require("bounds")

local M = {}
M.MAX_NAME = 80
M.SESSION_PREFIX = "bs:"

-- Source reads the world the name comes from: a session's snapshot and a
-- definition's title.
type Source = {session: (string) -> unknown, title: (string) -> string?}

function M.name(subject: unknown, source: Source): string?
    local id = bounds.id(subject)
    if not id or id:sub(1, #M.SESSION_PREFIX) ~= M.SESSION_PREFIX then return nil end
    local snapshot = bounds.object(source.session(id))
    local definition = snapshot and bounds.text(snapshot.definition, 256)
    if not definition or definition == "" then return nil end
    return bounds.line(source.title(definition), M.MAX_NAME)
end

return M
