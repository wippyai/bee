-- MIT. Loads one application trait with the caller's authority, as the
-- Agents app does when it resolves a launch plan that holds the trait.
local bounds = require("bounds")
local app_traits = require("app_traits")

local function load(raw: unknown): {[string]: unknown}
    local request = assert(bounds.object(raw))
    local trait, problem = app_traits.load(tostring(request.ref), bounds.id(request.workspace))
    return {trait = trait, error = problem}
end

return {load = load}
