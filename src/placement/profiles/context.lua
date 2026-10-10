local registry = require("registry")
local bounds = require("bounds")
local profiles = require("profiles")
local function handle(value: unknown): {isolation: profiles.Isolation?, error: string?}
    local ref = bounds.id(value)
    if not ref then return {error = "Placement profile reference is invalid"} end
    local pinned, err = registry.snapshot()
    if not pinned then return {error = tostring(err)} end
    local resolved, invalid = profiles.resolve(pinned, ref)
    if not resolved then return {error = invalid} end
    return {isolation = resolved.isolation}
end
return {handle = handle}
