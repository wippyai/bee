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
                targets = hole.targets, selected = hole.selected, has_selected = hole.has_selected, capability = hole.capability,
                schema = hole.schema, description = hole.description, schema_default = hole.schema_default}
            if not hole.capability and not hole.has_selected and not has_default then missing[#missing + 1] = hole.id end
        end
        bound[#bound + 1] = {component = item.component, version = item.version, digest = item.digest,
            entries = item.entries, dependencies = item.dependencies, requirements = {requirements = selected, missing = missing}}
    end
    return bound, nil
end

-- Use the runtime resolver's worklist rule: retain a compatible installed
-- selection, otherwise choose the best catalog match. Explicit newest roots
-- use catalog selection even when the installed version remains compatible. Retract superseded
-- dependencies and resolve their intersections again; never choose a lower
-- parent version to make its descendants succeed.
function M.resolve(roots: {Edge}, source: Source, installed: {[string]: string}?, newest: {[string]: boolean}?): (Result?, string?)
    if #roots > 128 then return nil, "too many dependency roots" end
    local assigned: {[string]: Package} = {}
    local demands: {[string]: {[string]: string}} = {}
    local children: {[string]: {string}} = {}
    local queue: {string} = {}
    local queued: {[string]: boolean} = {}
    local problems: {[string]: string} = {}
    local artifact_cache: {[string]: Package} = {}
    local versions_cache: {[string]: {items: {string}, more: boolean}} = {}
    local artifact_count = 0
    local function enqueue(name: string)
        if not queued[name] then queue[#queue + 1] = name; queued[name] = true end
    end
    local function add(name: string, owner: string, constraint: string)
        local incoming = demands[name] or {}
        incoming[owner] = constraint; demands[name] = incoming
        enqueue(name)
    end
    local function retract(name: string)
        for _, child in ipairs(children[name] or {}) do
            local incoming = demands[child]
            if incoming then incoming[name] = nil end
            enqueue(child)
        end
        children[name] = nil
    end
    local function allowed(version: string, constraints: {string}, selected_prerelease: boolean?): (boolean?, string?)
        for _, constraint in ipairs(constraints) do
            local matches, problem = semver.matches(version, constraint, selected_prerelease)
            if matches == nil then return nil, problem end
            if not matches then return false, nil end
        end
        return true, nil
    end
    local function choose(name: string, constraints: {string}): (string?, string?)
        local retained = installed and installed[name] or nil
        if retained and not (newest and newest[name]) then
            local matches, problem = allowed(retained, constraints, true)
            if matches == nil then return nil, problem end
            if matches then return retained, nil end
        end
        for _, constraint in ipairs(constraints) do
            if semver.parse(constraint) then
                local matches, problem = allowed(constraint, constraints, retained == constraint or (newest and newest[name]))
                if matches == nil then return nil, problem end
                if matches then return constraint, nil end
                return nil, name .. " has conflicting constraints: " .. table.concat(constraints, ", ")
            end
        end
        local best_stable: string? = nil
        local best_prerelease: string? = nil
        for page = 1, 64 do
            local key = name .. "#" .. tostring(page)
            local cached = versions_cache[key]
            if not cached then
                local listed, more, problem = source.versions(name, page)
                if not listed or more == nil then return nil, problem or "cannot list dependency versions" end
                for _, version in ipairs(listed) do
                    if not semver.parse(version) then return nil, name .. " has an invalid version" end
                end
                table.sort(listed, function(a: string, b: string): boolean return (semver.compare(a, b) or 0) > 0 end)
                cached = {items = listed, more = more}; versions_cache[key] = cached
            end
            for _, version in ipairs(cached.items) do
                local matches, problem = allowed(version, constraints, retained == version or (newest and newest[name]))
                if matches == nil then return nil, problem end
                if matches then
                    local parsed = semver.parse(version)
                    if parsed and #parsed.prerelease == 0 then
                        if not best_stable or (semver.compare(version, best_stable) or 0) > 0 then best_stable = version end
                    elseif not best_prerelease or (semver.compare(version, best_prerelease) or 0) > 0 then best_prerelease = version end
                end
            end
            if not cached.more then
                if newest and newest[name] and best_prerelease
                    and (not best_stable or (semver.compare(best_prerelease, best_stable) or 0) > 0) then
                    return best_prerelease, nil
                end
                if best_stable or best_prerelease then return best_stable or best_prerelease, nil end
                return nil, name .. " has no version satisfying " .. table.concat(constraints, ", ")
            end
        end
        return nil, "dependency plan exceeds version page bound"
    end
    for index, root in ipairs(roots) do add(root.component, "@root/" .. tostring(index), root.version) end
    local cursor = 1
    while cursor <= #queue do
        if cursor > 512 then return nil, "dependency plan exceeds search bound" end
        local name = queue[cursor]; cursor = cursor + 1; queued[name] = nil
        local constraints: {string} = {}
        for _, constraint in pairs(demands[name] or {}) do constraints[#constraints + 1] = constraint end
        table.sort(constraints)
        if #constraints == 0 then
            retract(name); assigned[name] = nil; problems[name] = nil
        else
            local version, problem = choose(name, constraints)
            if not version then
                retract(name); assigned[name] = nil; problems[name] = problem or "no compatible dependency versions"
            elseif not assigned[name] or assigned[name].version ~= version then
                retract(name)
                local key = name .. "@" .. version
                local item = artifact_cache[key]
                if not item then
                    artifact_count = artifact_count + 1
                    if artifact_count > 128 then return nil, "artifact inspection exceeds bound" end
                    local artifact, artifact_error = source.artifact(name, version)
                    if not artifact then return nil, artifact_error or "cannot inspect package" end
                    if artifact.component ~= name or (semver.compare(artifact.version, version) or 1) ~= 0 then
                        return nil, "artifact identity does not match its selection"
                    end
                    local decoded, decode_error = package(artifact)
                    if not decoded then return nil, decode_error end
                    item = decoded; artifact_cache[key] = item
                end
                assigned[name] = item; problems[name] = nil
                local outgoing: {string} = {}
                for _, edge in ipairs(item.dependencies) do
                    add(edge.component, name, edge.version); outgoing[#outgoing + 1] = edge.component
                end
                children[name] = outgoing
            else problems[name] = nil end
        end
    end
    local names: {string} = {}
    for name in pairs(assigned) do names[#names + 1] = name end
    if #names > 64 then return nil, "dependency closure exceeds 64 modules" end
    table.sort(names)
    for _, problem in pairs(problems) do return nil, problem end
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
        projected, projection_error = requirements.configuration_targets(projected, selected)
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
