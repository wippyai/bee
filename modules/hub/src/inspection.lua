-- MIT. Pure exact-artifact request and inspection values.
local bounds = require("bounds")
local requirements = require("requirements")
local M = {}
type Request = {component: string, version: string, parameters: {requirements.Parameter}}
type Entry = {id: string, kind: string, meta: {[string]: unknown}, data: unknown}
type Inspection = {component: string, version: string, digest: string, requirements: requirements.Result, entries: {Entry}}

function M.decode(raw: unknown): (Request?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "package request must be an object" end
    local extra = bounds.fields(value, {"component", "version", "parameters"})
    if extra then return nil, extra end
    local component = bounds.line(value.component, 160)
    if not component or not component:match("^[%w_%-%.]+/[%w_%-%.]+$") then return nil, "component must be an org/module name" end
    local org, name = component:match("^([^/]+)/([^/]+)$")
    if org == "." or org == ".." or name == "." or name == ".." then return nil, "component must be an org/module name" end
    local version = bounds.line(value.version, 128)
    if not version or not version:match("^v?%d+%.%d+%.%d+[%w%.%+%-]*$") then return nil, "an exact package version is required" end
    local supplied: unknown = value.parameters
    if supplied == nil then supplied = {} end
    local parameters, parameter_error = requirements.parameters(supplied)
    if not parameters then return nil, parameter_error end
    return {component = component, version = version, parameters = parameters}, nil
end

return M
