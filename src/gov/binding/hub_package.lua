-- MIT. Verified package closure for governed application delivery.
local registry = require("registry")
local bounds = require("bounds")
local graph = require("graph")
local inventory = require("inventory")
local artifact_source = require("artifact_source")
local artifact = require("artifact")
local inspection = require("inspection")
local canonical = require("canonical")
local hash = require("hash")
local M = {}
type Object = {[string]: unknown}
type Change = {entry: Object, op: string}
type Expanded = {digest: string, changes: {Change}, resolution: Object, retained: {[string]: boolean},
    artifact: artifact.Artifact, governed: boolean}
function M.expand(state: unknown, revision: integer, root: graph.Edge): (Expanded?, string?)
    local installed, problem = inventory.decode(state, revision)
    if not installed then return nil, problem end
    local versions: {[string]: string} = {}
    local resident: {[string]: boolean} = {}
    for _, item in ipairs(installed.modules) do
        versions[item.component] = item.version
        if item.entries > 0 then resident[item.component] = true end
    end
    local source = artifact_source.new(state, installed, root.component)
    local root_metadata: Object? = nil
    local read_artifact = source.artifact
    source.artifact = function(component: string, version: string): (inspection.Inspection?, string?)
        local selected, invalid = read_artifact(component, version)
        if selected and component == root.component then root_metadata = selected.metadata end
        return selected, invalid
    end
    local resolved, resolve_error = graph.resolve({root}, source, versions)
    if not resolved then return nil, resolve_error end
    if #resolved.missing > 0 then return nil, "package has missing dependency parameters: " .. table.concat(resolved.missing, ", ") end
    local captured = bounds.object(state)
    local existing: {[string]: Object} = {}
    for _, raw in ipairs(bounds.array(captured and captured.entries, 16384) or {}) do
        local entry = bounds.object(raw)
        if entry and type(entry.id) == "string" then existing[entry.id] = entry end
    end
    local changes: {Change}, entries: {Object}, modules: {Object} = {}, {}, {}
    local retained: {[string]: boolean} = {}
    local governed = false
    for _, package in ipairs(resolved.packages) do
        modules[#modules + 1] = {name = package.component, version = package.version, digest = package.digest}
        if package.component ~= root.component and resident[package.component] and versions[package.component] == package.version then
            retained[package.component] = true
        else
            for _, raw in ipairs(package.entries) do
                local entry: Object = {id = raw.id, kind = raw.kind, meta = raw.meta, data = raw.data,
                    registry = {owner = package.component}}
                changes[#changes + 1] = {entry = entry, op = existing[raw.id] and "update" or "create"}
                if raw.kind ~= "ns.dependency" then
                    entries[#entries + 1] = {id = raw.id, kind = raw.kind, meta = raw.meta, data = raw.data}
                end
                if (raw.kind == "ns.requirement" and raw.meta.capability ~= nil)
                    or raw.meta.type == "bee.app" then governed = true end
            end
        end
    end
    if root_metadata and root_metadata.type == "application" then governed = true end
    local made, artifact_error = artifact.create(entries)
    if not made then return nil, artifact_error end
    local bytes, encode_error = canonical.encode({changes = changes, modules = modules})
    local measured = bytes and hash.sha256(bytes) or nil
    if not measured then return nil, encode_error or "cannot measure package closure" end
    return {digest = measured, changes = changes, resolution = {modules = modules}, retained = retained,
        artifact = made, governed = governed}, nil
end
function M.read(root: graph.Edge): (Expanded?, string?)
    local checked, invalid = inspection.decode({component = root.component, version = root.version, parameters = root.parameters})
    if not checked then return nil, invalid end
    local snapshot, problem = registry.snapshot()
    if not snapshot then return nil, tostring(problem) end
    local state, state_error = snapshot:state()
    if not state then return nil, tostring(state_error) end
    return M.expand(state, math.floor(snapshot:version():id()), root)
end
return M
