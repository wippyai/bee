-- MIT. Bounded application-level dependency planning. Native registry apply
-- remains responsible for resolution and linking the published roots.
local bounds = require("bounds")
local requirements = require("requirements")
local inspection = require("inspection")
local semver = require("semver")
local canonical = require("canonical")
local M = {}
type Edge = {component: string, version: string, parameters: {requirements.Parameter}}
type Package = {component: string, version: string, digest: string,
    entries: {inspection.Entry}, dependencies: {Edge}, requirements: requirements.Result}
type Source = {
    versions: (string, integer) -> ({string}?, boolean?, string?),
    artifact: (string, string) -> (inspection.Inspection?, string?),
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

local function package(artifact: inspection.Inspection): (Package?, string?)
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

local function forward_defaults(packages: {Package}): ({Package}?, string?)
    local holes: {[string]: requirements.Requirement} = {}
    for _, item in ipairs(packages) do
        for _, hole in ipairs(item.requirements.requirements) do
            if holes[hole.id] then return nil, "packages collide at " .. hole.id end
            holes[hole.id] = hole
        end
    end
    local writers: {[string]: {string}} = {}
    for _, hole in pairs(holes) do
        for _, target in ipairs(hole.targets) do
            if holes[target.entry] and (target.path == ".default" or target.path == "default") then
                local sources = writers[target.entry] or {}
                sources[#sources + 1] = hole.id
                writers[target.entry] = sources
            end
        end
    end
    type Value = {value: unknown?, present: boolean}
    local values: {[string]: Value} = {}
    local visiting: {[string]: boolean} = {}
    local function evaluate(id: string, depth: integer): (Value?, string?)
        if depth >= 128 then return nil, "requirement default forwarding exceeds depth bound" end
        if values[id] then return values[id], nil end
        if visiting[id] then return nil, "requirement default cycle at " .. id end
        local hole = holes[id]
        if not hole then return nil, "unknown forwarded requirement " .. id end
        if hole.has_selected then
            local selected: Value = {value = hole.selected, present = true}
            values[id] = selected
            return selected, nil
        end
        visiting[id] = true
        local chosen: Value = {present = false}
        for _, source_id in ipairs(writers[id] or {}) do
            local source, problem = evaluate(source_id, depth + 1)
            if not source then return nil, problem end
            if source.present then
                if chosen.present and canonical.encode(chosen.value) ~= canonical.encode(source.value) then
                    return nil, "conflicting requirement defaults for " .. id
                end
                chosen = source
            end
        end
        if not chosen.present and hole.has_default then chosen = {value = hole.default, present = true} end
        visiting[id] = nil
        values[id] = chosen
        return chosen, nil
    end
    for id in pairs(holes) do
        local value, problem = evaluate(id, 0)
        if not value then return nil, problem end
    end
    local bound: {Package} = {}
    for _, item in ipairs(packages) do
        local missing: {string} = {}
        local selected: {requirements.Requirement} = {}
        for _, hole in ipairs(item.requirements.requirements) do
            local value = values[hole.id]
            local fallback, has_default = hole.default, hole.has_default
            if not hole.has_selected and value and value.present then
                fallback, has_default = value.value, true
            end
            selected[#selected + 1] = {id = hole.id, default = fallback, has_default = has_default,
                targets = hole.targets, selected = hole.selected, has_selected = hole.has_selected}
            if not hole.has_selected and not has_default then missing[#missing + 1] = hole.id end
        end
        bound[#bound + 1] = {component = item.component, version = item.version, digest = item.digest,
            entries = item.entries, dependencies = item.dependencies, requirements = {requirements = selected, missing = missing}}
    end
    return bound, nil
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
            local qualified = parameter.name:find(":", 1, true) ~= nil
            local visited: {[string]: boolean} = {}
            local addressed: {string} = {}
            local function visit(component: string)
                if visited[component] then return end
                visited[component] = true
                local item = assigned[component]
                if not item then return end
                for _, hole in ipairs(item.requirements.requirements) do
                    if hole.id == parameter.name or (not qualified and hole.id:match(":([^:]+)$") == parameter.name) then
                        addressed[#addressed + 1] = hole.id
                    end
                end
                if qualified then
                    for _, dependency in ipairs(item.dependencies) do visit(dependency.component) end
                end
            end
            visit(edge.component)
            if #addressed == 0 then return "parameter names no requirement " .. parameter.name .. " in " .. edge.component end
            for _, id in ipairs(addressed) do
                local old = parameters[id]
                if old and canonical.encode(old.value) ~= canonical.encode(parameter.value) then
                    return "conflicting parameter " .. id
                end
                parameters[id] = {name = id, value = parameter.value}
            end
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
        packages[#packages + 1] = {component = item.component, version = item.version, digest = item.digest,
            entries = item.entries, dependencies = item.dependencies, requirements = selected}
    end
    local bound, default_error = forward_defaults(packages)
    if not bound then return nil, default_error end
    local projected_packages: {Package} = {}
    for _, item in ipairs(bound) do
        local selected = item.requirements
        local projected, projection_error = requirements.migration_targets(item.entries, selected)
        if not projected then return nil, projection_error end
        for _, id in ipairs(selected.missing) do missing[#missing + 1] = id end
        for _, entry in ipairs(projected) do
            if ids[entry.id] then return nil, "packages collide at " .. entry.id end
            ids[entry.id] = item.component
        end
        projected_packages[#projected_packages + 1] = {component = item.component, version = item.version, digest = item.digest,
            entries = projected, dependencies = item.dependencies, requirements = selected}
    end
    for name in pairs(parameters) do if not used[name] then return nil, "parameter names no requirement " .. name end end
    table.sort(projected_packages, function(a: Package, b: Package): boolean return a.component < b.component end)
    table.sort(missing)
    return {packages = projected_packages, missing = missing}, nil
end
return M
