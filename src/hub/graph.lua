-- MIT. Bounded application-level dependency planning. Native registry apply
-- remains responsible for resolution and linking the published roots.
local bounds = require("bounds")
local requirements = require("requirements")
local inspect = require("inspect")
local semver = require("semver")
local canonical = require("canonical")
local M = {}
type Edge = {component: string, version: string, parameters: {requirements.Parameter}}
type Package = {component: string, version: string, digest: string,
    entries: {inspect.Entry}, dependencies: {Edge}, requirements: requirements.Result}
type Source = {
    versions: (string, integer) -> ({string}?, boolean?, string?),
    artifact: (string, string) -> (inspect.Inspection?, string?),
}
type Result = {packages: {Package}, missing: {string}}

function M.edge(raw: unknown): (Edge?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "invalid dependency" end
    local component, version = bounds.line(value.component, 160), bounds.line(value.version, 128)
    if not component or not version then
        return nil, "dependency needs a component and version"
    end
    if not component:match("^[%w_%-%.]+/[%w_%-%.]+$") then return nil, "invalid dependency component" end
    local org, name = component:match("^([^/]+)/([^/]+)$")
    if org == "." or org == ".." or name == "." or name == ".." then return nil, "invalid dependency component" end
    local parameters, problem = requirements.parameters(value.parameters or {})
    if not parameters then return nil, problem end
    return {component = component, version = version, parameters = parameters}, nil
end

local function package(artifact: inspect.Inspection): (Package?, string?)
    local dependencies: {Edge} = {}
    for _, entry in ipairs(artifact.entries) do
        if entry.kind == "ns.dependency" then
            local edge, problem = M.edge(entry.data)
            if not edge then return nil, entry.id .. ": " .. tostring(problem) end
            if #dependencies >= 128 then return nil, "package exceeds dependency bound" end
            dependencies[#dependencies + 1] = edge
        end
    end
    table.sort(dependencies, function(a: Edge, b: Edge): boolean return a.component < b.component end)
    return {component = artifact.component, version = artifact.version, digest = artifact.digest,
        entries = artifact.entries, dependencies = dependencies, requirements = artifact.requirements}, nil
end

-- Rebuild constraints from each candidate assignment. Backtracking discards
-- edges from abandoned package versions, including diamond dependencies.
function M.resolve(roots: {Edge}, source: Source): (Result?, string?)
    if #roots > 128 then return nil, "too many dependency roots" end
    local versions_cache: {[string]: {items: {string}, more: boolean}} = {}
    local artifact_cache: {[string]: Package} = {}
    local assigned: {[string]: Package} = {}
    local searches, artifact_count = 0, 0
    local fatal: string? = nil
    local last_conflict = "no compatible dependency versions"
    local function search(depth: integer): boolean
        searches = searches + 1
        if searches > 512 or depth > 64 then fatal = "dependency plan exceeds search bound"; return false end
        local incoming: {[string]: {string}} = {}
        local names: {string} = {}
        local function add(edge: Edge)
            local constraints = incoming[edge.component]
            if not constraints then constraints = {}; incoming[edge.component] = constraints; names[#names + 1] = edge.component end
            constraints[#constraints + 1] = edge.version
        end
        for _, root in ipairs(roots) do add(root) end
        for _, item in pairs(assigned) do for _, edge in ipairs(item.dependencies) do add(edge) end end
        if #names > 64 then fatal = "dependency closure exceeds 64 modules"; return false end
        table.sort(names)
        local next_name: string? = nil
        for _, name in ipairs(names) do
            local chosen = assigned[name]
            if chosen then
                for _, constraint in ipairs(incoming[name]) do
                    local matches, problem = semver.matches(chosen.version, constraint)
                    if matches == nil then fatal = problem or "invalid version constraint"; return false end
                    if not matches then last_conflict = name .. " has conflicting constraints: " .. table.concat(incoming[name], ", "); return false end
                end
            elseif not next_name then next_name = name end
        end
        if not next_name then return true end
        local name = next_name
        -- An exact incoming pin supplies the only possible candidate directly.
        -- Ranges inspect catalog pages lazily; successful plans never fetch the
        -- remainder of a package's release history.
        local pinned: string? = nil
        for _, constraint in ipairs(incoming[name]) do
            if semver.parse(constraint) then pinned = constraint; break end
        end
        local page = 1
        local more = true
        while more do
            local versions: {string} = {}
            if pinned then
                versions = {pinned}; more = false
            else
                local cache_key = name .. "#" .. tostring(page)
                local cached = versions_cache[cache_key]
                if not cached then
                    local listed, has_more, problem = source.versions(name, page)
                    if not listed or has_more == nil then fatal = problem or "cannot list dependency versions"; return false end
                    versions = {}
                    for _, version in ipairs(listed) do
                        if not semver.parse(version) then fatal = name .. " has an invalid version"; return false end
                        versions[#versions + 1] = version
                    end
                    table.sort(versions, function(a: string, b: string): boolean return (semver.compare(a, b) or 0) > 0 end)
                    cached = {items = versions, more = has_more}
                    versions_cache[cache_key] = cached
                end
                versions, more = cached.items, cached.more
            end
        for _, version in ipairs(versions) do
            local allowed = true
            for _, constraint in ipairs(incoming[name]) do
                local matches, problem = semver.matches(version, constraint)
                if matches == nil then fatal = problem or "invalid version constraint"; return false end
                if not matches then allowed = false; break end
            end
            if allowed then
                local key = name .. "@" .. version
                local item = artifact_cache[key]
                if not item then
                    artifact_count = artifact_count + 1
                    if artifact_count > 128 then fatal = "artifact inspection exceeds bound"; return false end
                    local artifact, problem = source.artifact(name, version)
                    if not artifact then fatal = problem or "cannot inspect package"; return false end
                    if artifact.component ~= name or (semver.compare(artifact.version, version) or 1) ~= 0 then
                        fatal = "artifact identity does not match its selection"; return false
                    end
                    local decoded, decode_error = package(artifact)
                    if not decoded then fatal = decode_error; return false end
                    item = decoded
                    artifact_cache[key] = item
                end
                assigned[name] = item
                if search(depth + 1) then return true end
                assigned[name] = nil
                if fatal then return false end
            end
        end
            page = page + 1
        end
        last_conflict = name .. " has no version satisfying " .. table.concat(incoming[name], ", ")
        return false
    end
    if not search(0) then return nil, fatal or last_conflict end
    local parameters: {[string]: requirements.Parameter} = {}
    local function bind(edge: Edge): string?
        for _, parameter in ipairs(edge.parameters) do
            local old = parameters[parameter.name]
            if old and canonical.encode(old.value) ~= canonical.encode(parameter.value) then
                return "conflicting parameter " .. parameter.name
            end
            parameters[parameter.name] = parameter
        end
        return nil
    end
    for _, edge in ipairs(roots) do local problem = bind(edge); if problem then return nil, problem end end
    for _, item in pairs(assigned) do
        for _, edge in ipairs(item.dependencies) do local problem = bind(edge); if problem then return nil, problem end end
    end
    local packages: {Package} = {}
    local missing: {string} = {}
    local used: {[string]: boolean} = {}
    local ids: {[string]: string} = {}
    for _, item in pairs(assigned) do
        local supplied: {requirements.Parameter} = {}
        for _, hole in ipairs(item.requirements.requirements) do
            local parameter = parameters[hole.id]
            if parameter then supplied[#supplied + 1] = parameter; used[hole.id] = true end
        end
        local selected, problem = requirements.read(item.entries, supplied)
        if not selected then return nil, problem end
        item.requirements = selected
        for _, id in ipairs(selected.missing) do missing[#missing + 1] = id end
        for _, entry in ipairs(item.entries) do
            if ids[entry.id] then return nil, "packages collide at " .. entry.id end
            ids[entry.id] = item.component
        end
        packages[#packages + 1] = item
    end
    for name in pairs(parameters) do if not used[name] then return nil, "parameter names no requirement " .. name end end
    table.sort(packages, function(a: Package, b: Package): boolean return a.component < b.component end)
    table.sort(missing)
    return {packages = packages, missing = missing}, nil
end
return M
