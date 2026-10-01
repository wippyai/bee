-- MIT. The caller's scope denies executable facts, even when the host has them.
local plan = require("plan")
local graph = require("graph")
local inspection = require("inspection")
local M = {}
function M.run(): {refused: boolean, message: string}
    local request, request_error = plan.decode({action = "update", component = "bee/bee", version = "0.2.0"})
    if not request then error(request_error or "invalid probe request") end
    local source: graph.Source = {
        versions = function(_: string, _: integer): ({string}?, boolean?, string?) return {}, false, nil end,
        artifact = function(name: string, version: string): (inspection.Inspection?, string?)
            local required = "v0.0.0-20260926183503-c0d6585b5fd1"
            return {component = name, version = version, digest = string.rep("a", 64),
                requirements = {requirements = {}, missing = {}}, next_offset = nil, eof = true,
                entries = {{id = "bee:definition", kind = "ns.definition", meta = {native_requirements = {
                    {package = "github.com/wippyai/bee/native/launch", version = required}}}, data = {}},
                    {id = "bee.env:binary_identity", kind = "registry.entry", meta = {type = "bee.binary_identity"},
                        data = {version = version, build = "fixture", source = "fixture", source_revision = "fixture",
                            runtime = "fixture", runtime_commit = "runtime-commit", native = "github.com/wippyai/bee/native",
                            native_version = required, website = "fixture", native_components = {
                                {package = "github.com/wippyai/bee/native/launch", version = required}}}}}}, nil
        end,
    }
    local prepared, problem = plan.prepare({entries = {{id = "bee:deployment", kind = "ns.dependency",
        registry = {owner = "", root = true}, data = {component = "bee/bee", version = "0.1.0", parameters = {}}}},
        resolution = {modules = {{name = "bee/bee", version = "0.1.0", source = "local"}}}}, 12, request, source)
    return {refused = prepared == nil, message = problem or ""}
end
return M
