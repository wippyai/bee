-- MIT. Hub plans describe a dependency-root change against a captured
-- registry revision. Confirmation covers the request and measured artifacts.
local bounds = require("bounds")
local canonical = require("canonical")
local hash = require("hash")
local graph = require("graph")
local inspection = require("inspection")
local inventory = require("inventory")
local binary_identity = require("binary_identity")
local native_compat = require("native_compat")
local requirements = require("requirements")
local semver = require("semver")
local M = {}
type Request = {action: string, component: string, version: string, parameters: {requirements.Parameter}, migration_policy: string}
type Module = {component: string, version: string, previous_version: string, digest: string,
    change: string, reason: string?, entries: integer, requirements: requirements.Result}
type Migration = {id: string, component: string, target_db: string, timestamp: string}
-- One security policy the plan adds, replaces with a new package version, or
-- removes with its departing package, summarized from the policy definition.
type PolicyChange = {id: string, component: string, change: string, actions: {string}, resources: {string},
    expression: boolean}
type Plan = {request: Request, base_revision: integer, root_id: string, root_operation: string, digest: string,
    modules: {Module}, missing: {string}, migrations: {Migration}, starts: {string}, capabilities: {string},
    policy_changes: {PolicyChange}, ready: boolean, conversion: inventory.Conversion?}
type Prepared = {plan: Plan, resolved: graph.Result, installed: inventory.Result}

local POLICY_KINDS: {[string]: boolean} = {["security.policy"] = true, ["security.policy.expr"] = true}

local function names(raw: unknown): {string}
    if type(raw) == "string" then return {raw} end
    local result: {string} = {}
    if type(raw) ~= "table" then return result end
    for _, item in ipairs(raw) do
        if type(item) == "string" then result[#result + 1] = item end
    end
    return result
end

local function policy_change(id: string, component: string, change: string, data: unknown): PolicyChange
    local body = bounds.object(data)
    local definition = body and bounds.object(body.policy) or nil
    if not definition then
        return {id = id, component = component, change = change, actions = {}, resources = {}, expression = false}
    end
    return {id = id, component = component, change = change, actions = names(definition.actions),
        resources = names(definition.resources), expression = definition.expression ~= nil}
end

function M.decode(raw: unknown): (Request?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "Hub operation must be an object" end
    local extra = bounds.fields(value, {"action", "component", "version", "parameters", "migration_policy"})
    if extra then return nil, extra end
    local action = bounds.member(value.action, {"install", "update", "uninstall"})
    if not action then return nil, "action must be install, update or uninstall" end
    local version: unknown = value.version
    if action == "uninstall" then
        if version ~= nil or value.parameters ~= nil then return nil, "uninstall takes no version or parameters" end
        version = "*"
    end
    local edge, problem = graph.edge({component = value.component, version = version, parameters = value.parameters or {}})
    if not edge then return nil, problem end
    if action ~= "uninstall" and not semver.parse(edge.version) then return nil, "select an exact package version" end
    local policy: unknown = value.migration_policy
    if policy == nil then policy = action == "uninstall" and "block" or "none" end
    local policies: {string} = {"none", "up"}
    if action == "uninstall" then policies = {"block", "leave", "down"} end
    local selected = bounds.member(policy, policies)
    if not selected then return nil, "invalid migration policy" end
    return {action = action, component = edge.component, version = action == "uninstall" and "" or edge.version,
        parameters = edge.parameters, migration_policy = selected}, nil
end

function M.root_id(component: string): (string?, string?)
    local digest, problem = hash.sha256(component)
    if not digest then return nil, tostring(problem) end
    return "bee.hub.deps:" .. digest, nil
end

local function target_error(holes: requirements.Result, targets: {[string]: boolean}): string?
    for _, hole in ipairs(holes.requirements) do
        local namespace = hole.id:match("^([^:]+):")
        if not namespace then return "requirement has no namespace: " .. hole.id end
        for _, target in ipairs(hole.targets) do
            local destination = target.entry
            if not destination:find(":", 1, true) then destination = namespace .. ":" .. destination end
            if not targets[destination] then return "requirement target does not resolve: " .. hole.id .. " -> " .. destination end
        end
    end
    return nil
end

local function installer_error(packages: {{component: string, entries: {{id: string, kind: string, data: unknown}}}}, entries: {unknown}): string?
    for _, item in ipairs(packages) do
        if item.component == "bee/hub" then
            local candidate: {[string]: {id: string, kind: string, data: unknown}} = {}
            for _, entry in ipairs(item.entries) do candidate[entry.id] = entry end
            for _, raw in ipairs(entries) do
                local entry = bounds.object(raw)
                local owned = entry and bounds.object(entry.registry)
                local id = entry and bounds.id(entry.id) or nil
                if entry and owned and id and owned.owner == "bee/hub"
                    and (entry.kind == "library.lua" or entry.kind == "function.lua" or entry.kind == "process.lua") then
                    local proposed = candidate[id]
                    if not proposed or proposed.kind ~= entry.kind or canonical.encode(proposed.data) ~= canonical.encode(entry.data) then
                        return "Bee self-update would replace the active Hub installer: " .. id
                    end
                end
            end
        end
    end
    return nil
end

function M.prepare(state: unknown, revision: integer, request: Request, source: graph.Source,
	 baked_identity: binary_identity.Baked?): (Prepared?, string?)
    local installed, inventory_error = inventory.decode(state, revision)
    if not installed then return nil, inventory_error end
    local self_update = request.component == "bee/bee"
    if self_update and request.action ~= "update" then return nil, "the Bee deployment root can only be updated" end
    local raw_state = bounds.object(state)
    if not raw_state or type(raw_state.entries) ~= "table" then return nil, "invalid captured registry" end
    local controlled = inventory.dependency_members(installed, self_update)
    local protected: {[string]: string} = {["bee/hub"] = "bee/hub"}
    for _, root in ipairs(installed.roots) do
        if not root.managed and root.component ~= "bee/bee" then protected[root.component] = root.id end
    end
    local changed = true
    while changed do
        changed = false
        for _, item in ipairs(installed.modules) do
            if not protected[item.component] then
                for _, owner in ipairs(item.used_by) do
                    if protected[owner] then
                        local dependent = owner
                        for _, raw in ipairs(raw_state.entries) do
                            local entry = bounds.object(raw)
                            local ownership = entry and bounds.object(entry.registry)
                            local data = entry and bounds.object(entry.data)
                            local id = entry and bounds.id(entry.id) or nil
                            if entry and id and ownership and data and entry.kind == "ns.dependency"
                                and ownership.owner == owner and data.component == item.component then dependent = id; break end
                        end
                        protected[item.component] = dependent; changed = true; break
                    end
                end
            end
        end
    end
    if not self_update and protected[request.component] and request.action ~= "install" then
        return nil, "protected boot/installer component cannot be " .. (request.action == "uninstall" and "removed" or "updated")
            .. " independently: " .. request.component .. "; required by " .. protected[request.component]
    end
    local root_id, root_error = M.root_id(request.component)
    if not root_id then return nil, root_error end
    local component_roots: {[string]: inventory.Root} = {}
    local component_versions: {[string]: string} = {}
    local newest: {[string]: boolean} = {}
    local third_party_roots: {[string]: string} = {}
    local existing: inventory.Root? = nil
    local roots: {graph.Edge} = {}
    for _, root in ipairs(installed.roots) do
        if self_update and inventory.host_component(root) then
            if component_roots[root.component] then return nil, "component has multiple host roots: " .. root.component end
            component_roots[root.component] = root
            local selected = root.version
            for _, item in ipairs(installed.modules) do
                if item.component == root.component and item.version ~= "" then selected = item.version; break end
            end
            if not semver.parse(selected) then return nil, "host component has no exact installed version: " .. root.id end
            component_versions[root.component] = selected
            roots[#roots + 1] = {component = root.component, version = ">=" .. selected .. " || =" .. request.version, parameters = root.parameters}
        elseif root.managed then
            if root.component == request.component then
                if existing then return nil, "component has multiple roots; host configuration needs review" end
                existing = root
            elseif controlled[root.component] then
                local selected = root.version
                if self_update and not inventory.host_component(root) then
                    for _, item in ipairs(installed.modules) do
                        if item.component == root.component and item.version ~= "" then selected = item.version; break end
                    end
                    third_party_roots[root.component] = selected
                end
                roots[#roots + 1] = {component = root.component, version = selected, parameters = root.parameters}
            end
        elseif self_update and root.component == "bee/bee" and root.owner == "" then
            if existing then return nil, "Bee has multiple deployment roots; host configuration needs review" end
            existing = root
        end
    end
    local standalone_selection = self_update and not existing and installed.deployment == request.component
    if self_update then
        if not existing and not standalone_selection then return nil, "Bee deployment root is not installed" end
        if existing then root_id = existing.id end
        local parameters: {requirements.Parameter} = existing and existing.parameters or {}
        if #request.parameters > 0 and canonical.encode(request.parameters) ~= canonical.encode(parameters) then
            return nil, "self-update must preserve the host deployment parameters"
        end
        if #request.parameters == 0 and #parameters > 0 then
            return nil, "self-update requires the host deployment parameters"
        end
    end
    for _, item in ipairs(installed.modules) do
        if item.component == request.component and not controlled[item.component] and (item.entries > 0 or item.version ~= "") then
            return nil, "component is managed by the host deployment"
        end
    end
    if existing and existing.managed then root_id = existing.id end
    if existing and existing.id ~= root_id then return nil, "component is managed by host configuration at " .. existing.id end
    if request.action == "install" and existing then return nil, "component already has an installed root; choose update" end
    if request.action ~= "install" and not existing and not standalone_selection then return nil, "component has no installed Hub root" end
    if request.action == "uninstall" then
        for _, item in ipairs(installed.modules) do
            if item.component == request.component and #item.used_by > 0 then
                return nil, "component is still required by " .. table.concat(item.used_by, ", ")
            end
        end
    else
        roots[#roots + 1] = {component = request.component, version = request.version, parameters = request.parameters}
    end
    -- Resident modules can reference a root controlled by this installer.
    -- Their constraints remain part of the plan even though their owners are
    -- not themselves candidates for replacement.
    for _, raw_entry in ipairs(raw_state.entries) do
        local entry = bounds.object(raw_entry)
        local owned = entry and bounds.object(entry.registry)
        local data = entry and bounds.object(entry.data)
        local selected_root = false
        if entry then
            for _, root in ipairs(installed.roots) do
                if root.id == entry.id and (root.managed or (self_update and inventory.host_component(root))) then selected_root = true; break end
            end
        end
        if not selected_root and entry and owned and data and entry.kind == "ns.dependency" and type(owned.owner) == "string"
            and owned.owner ~= "" and not controlled[owned.owner] and type(data.component) == "string"
            and controlled[data.component] then
            local reference, reference_error = graph.edge(data)
            if not reference then return nil, reference_error end
            roots[#roots + 1] = reference
        end
    end
    local selections: {[string]: string} = {}
    for _, item in ipairs(installed.modules) do
        if item.version ~= "" then selections[item.component] = item.version end
    end
    if self_update and installed.selected then
        local artifact, artifact_error = source.artifact(request.component, request.version)
        if not artifact then return nil, artifact_error end
        for _, entry in ipairs(artifact.entries) do
            if entry.kind == "ns.dependency" then
                local edge, edge_error = graph.edge(entry.data)
                if not edge then return nil, edge_error end
                if entry.meta.type == "bee.component_selection" then
                    return nil, "Bee self-update must leave component selection to host roots: " .. entry.id
                end
            end
        end
    end
    local removed_components: {[string]: boolean} = {}
    if self_update then
        local resolution = bounds.object(raw_state.resolution)
        local lock = resolution and bounds.object(resolution.lock)
        if lock and type(lock.modules) == "table" then
            for _, raw in ipairs(lock.modules) do
                local item = bounds.object(raw)
                if item and type(item.name) == "string" and not selections[item.name] then
                    removed_components[item.name] = true
                end
            end
        end
    end
    local retained_reasons: {[string]: string} = {}
    local rejected_versions: {[string]: string} = {}
    local candidate_source = source
    if self_update and installed.selected then
        local core, core_error = source.artifact(request.component, request.version)
        if not core then return nil, core_error end
        local cached: {[string]: inspection.Inspection} = {}
        candidate_source = {
            artifact = function(component: string, version: string): (inspection.Inspection?, string?)
                local key = component .. "@" .. version
                if cached[key] then return cached[key], nil end
                return source.artifact(component, version)
            end,
            versions = function(component: string, page: integer): ({string}?, boolean?, string?)
                local listed, more, problem = source.versions(component, page)
                local root = component_roots[component]
                if not root then return listed, more, problem end
                local current = component_versions[component]
                if not current then return nil, nil, "host component has no installed version: " .. component end
                if not listed or more == nil then
                    retained_reasons[component] = problem or "component release catalog unavailable"
                    return {current}, false, nil
                end
                local allowed: {string} = {}
                for _, version in ipairs(listed) do
                    if not semver.parse(version) then return nil, nil, component .. " has an invalid version" end
                    if (semver.compare(version, current) or -1) > 0
                        and semver.matches(version, ">=" .. current .. " || =" .. request.version) then
                        local artifact, artifact_error = source.artifact(component, version)
                        local incompatible: string? = artifact_error or "component artifact unavailable"
                        if artifact then
                            cached[component .. "@" .. version] = artifact
                            incompatible = native_compat.check({core, artifact}, baked_identity)
                                or installer_error({artifact}, raw_state.entries)
                            for _, entry in ipairs(artifact.entries) do
                                if entry.kind == "ns.dependency" then
                                    local edge, edge_error = graph.edge(entry.data)
                                    if not edge then return nil, nil, edge_error end
                                    local third_party = third_party_roots[edge.component]
                                    if third_party and not semver.matches(third_party, edge.version, true) then
                                        incompatible = component .. " requires third-party root " .. edge.component .. " " .. edge.version
                                    elseif removed_components[edge.component] then
                                        incompatible = component .. " requires removed component " .. edge.component
                                    elseif edge.component == "bee/bee" and not semver.matches(request.version, edge.version, true) then
                                        incompatible = component .. " requires bee/bee " .. edge.version
                                    end
                                end
                            end
                        end
                        if incompatible then
                            if not rejected_versions[component] or (semver.compare(version, rejected_versions[component]) or 0) > 0 then
                                retained_reasons[component], rejected_versions[component] = incompatible, version
                            end
                        else allowed[#allowed + 1] = version end
                    end
                end
                -- The captured installed artifact remains available even if its
                -- release is no longer listed by the Hub.
                if page == 1 then allowed[#allowed + 1] = current end
                return allowed, more, nil
            end,
        }
        for component in pairs(component_roots) do newest[component] = true end
    end
    local resolved, graph_error = graph.resolve(roots, candidate_source, selections, newest)
    if not resolved then return nil, graph_error end
    for _, item in ipairs(resolved.packages) do
        if removed_components[item.component] then return nil, "Bee self-update would reinstall removed component: " .. item.component end
    end
    if request.action == "uninstall" then
        local required_by: {string} = {}
        for _, item in ipairs(resolved.packages) do
            for _, dependency in ipairs(item.dependencies) do
                if dependency.component == request.component then required_by[#required_by + 1] = item.component; break end
            end
        end
        if #required_by > 0 then
            table.sort(required_by)
            return nil, "component is still required by " .. table.concat(required_by, ", ")
        end
    end
    if self_update then
        local active_error = installer_error(resolved.packages, raw_state.entries)
        if active_error then return nil, active_error end
        local compatibility_error = native_compat.check(resolved.packages, baked_identity)
        if compatibility_error then return nil, compatibility_error end
    end
    local owners: {[string]: string} = {}
    for _, raw_entry in ipairs(raw_state.entries) do
        local entry = bounds.object(raw_entry)
        if not entry then return nil, "invalid resident entry" end
        local owned = bounds.object(entry.registry)
        local id = bounds.id(entry.id)
        if not owned or not id then return nil, "missing resident ownership" end
        local owner = owned.owner
        if owner == nil then owner = "" end
        if type(owner) ~= "string" then return nil, "invalid resident ownership" end
        owners[id] = owner
    end
    if owners[root_id] ~= nil and not existing then return nil, "dependency destination is already occupied" end
    local by_name: {[string]: inventory.Module} = {}
    for _, item in ipairs(installed.modules) do by_name[item.component] = item end
    local modules: {Module} = {}
    local migrations: {Migration} = {}
    local starts: {string} = {}
    local capabilities: {string} = {}
    local policy_changes: {PolicyChange} = {}
    local proposed_policies: {[string]: boolean} = {}
    local changed_components: {[string]: boolean} = {}
    local missing: {string} = {}
    local remaining: {[string]: boolean} = {}
    for _, item in ipairs(resolved.packages) do
        remaining[item.component] = true
        local old = by_name[item.component]
        local previous = old and old.version or ""
        if old and not controlled[item.component] and (semver.compare(previous, item.version) or 1) ~= 0 then
            return nil, "dependency would replace a host-deployment module: " .. item.component
        end
        local change = previous == "" and "install" or ((semver.compare(previous, item.version) or 1) == 0 and "keep" or "update")
        local same_digest = item.digest == "" or (old and old.digest ~= "" and old.digest == item.digest:lower():gsub("^sha256:", ""))
        if change ~= "keep" or item.component == request.component or not same_digest then
            for _, id in ipairs(item.requirements.missing) do missing[#missing + 1] = id end
        end
        local reason: string? = nil
        if change == "keep" and component_roots[item.component] then
            local constraints: {string} = {}
            for _, parent in ipairs(resolved.packages) do
                for _, edge in ipairs(parent.dependencies) do
                    if edge.component == item.component then constraints[#constraints + 1] = parent.component .. " requires " .. edge.version end
                end
            end
            for _, root in ipairs(installed.roots) do
                if root.component == item.component and not inventory.host_component(root) then
                    constraints[#constraints + 1] = root.id .. " requires " .. root.version
                end
            end
            table.sort(constraints)
            reason = retained_reasons[item.component]
            if #constraints > 0 then
                reason = (reason and (reason .. "; ") or "") .. table.concat(constraints, ", ")
            end
            if not reason then reason = "no newer compatible version published for bee/bee " .. request.version end
        end
        modules[#modules + 1] = {component = item.component, version = item.version, previous_version = previous, reason = reason,
            digest = item.digest, change = change, entries = #item.entries, requirements = item.requirements}
        if change ~= "keep" then
            if not self_update and protected[item.component] and old then
                return nil, "dependency would replace protected boot/installer component: " .. item.component .. "; required by " .. protected[item.component]
            end
            changed_components[item.component] = true
        end
        for _, entry in ipairs(item.entries) do
            local owner = owners[entry.id]
            if owner ~= nil and owner ~= item.component then return nil, "package would replace another owner's entry: " .. entry.id end
            if POLICY_KINDS[entry.kind] then
                capabilities[#capabilities + 1] = entry.id
                proposed_policies[entry.id] = true
                if change ~= "keep" then
                    policy_changes[#policy_changes + 1] = policy_change(entry.id, item.component,
                        owner == item.component and "update" or "add", entry.data)
                end
            end
            if change ~= "keep" then
                local data = bounds.object(entry.data)
                local lifecycle = data and bounds.object(data.lifecycle)
                if lifecycle and lifecycle.auto_start == true then starts[#starts + 1] = entry.id end
                if entry.meta.type == "migration" then
                    local target, timestamp = bounds.id(entry.meta.target_db), bounds.line(entry.meta.timestamp, 160)
                    if not target or not timestamp then return nil, "migration has unresolved target or timestamp: " .. entry.id end
                    migrations[#migrations + 1] = {id = entry.id, component = item.component, target_db = target, timestamp = timestamp}
                end
            end
        end
    end
    for _, item in ipairs(installed.modules) do
        if not remaining[item.component] then
            local remove = controlled[item.component] == true
            modules[#modules + 1] = {component = item.component, version = remove and "" or item.version, previous_version = item.version,
                digest = "", change = remove and "remove" or "keep", entries = item.entries, requirements = {requirements = {}, missing = {}}}
            if remove then
                if protected[item.component] then return nil, "dependency change would remove protected boot/installer component: " .. item.component end
                changed_components[item.component] = true
            end
        end
    end
    for _, raw_entry in ipairs(raw_state.entries) do
        local entry = bounds.object(raw_entry)
        local id = entry and bounds.id(entry.id) or nil
        local owner = id and owners[id] or nil
        if entry and id and owner and changed_components[owner] and POLICY_KINDS[tostring(entry.kind)]
            and not proposed_policies[id] then
            policy_changes[#policy_changes + 1] = policy_change(id, owner, "remove", entry.data)
        end
    end
    local targets: {[string]: boolean} = {}
    for _, raw in ipairs(raw_state.entries) do
        local entry = bounds.object(raw)
        local id = entry and bounds.id(entry.id) or nil
        if id and not changed_components[owners[id]] then targets[id] = true end
    end
    for _, item in ipairs(resolved.packages) do for _, entry in ipairs(item.entries) do targets[entry.id] = true end end
    for _, root in ipairs(installed.conversion and installed.conversion.roots or {}) do
        if request.action ~= "uninstall" or root.id ~= root_id then targets[root.id] = true end
    end
    for _, item in ipairs(resolved.packages) do
        local problem = target_error(item.requirements, targets)
        if problem then return nil, problem end
    end
    for _, raw in ipairs(raw_state.entries) do
        local entry = bounds.object(raw)
        local id = entry and bounds.id(entry.id) or nil
        if entry and id and entry.kind == "ns.requirement" and not changed_components[owners[id]] then
            local holes, problem = requirements.read({{id = id, kind = "ns.requirement", data = entry.data}}, {})
            if not holes then return nil, problem end
            local target_problem = target_error(holes, targets)
            if target_problem then return nil, target_problem end
        end
    end
    if request.action == "uninstall" then
        local removed: {[string]: boolean} = {}
        for _, item in ipairs(modules) do if item.change == "remove" then removed[item.component] = true end end
        for _, raw_entry in ipairs(raw_state.entries) do
            local entry = bounds.object(raw_entry)
            local meta = entry and bounds.object(entry.meta) or nil
            local id = entry and bounds.id(entry.id) or nil
            local owner = id and owners[id] or nil
            if entry and id and meta and meta.type == "migration" and owner and removed[owner] then
                local target, timestamp = bounds.id(meta.target_db), bounds.line(meta.timestamp, 160)
                if not target or not timestamp then return nil, "removed migration has unresolved target or timestamp: " .. tostring(entry.id) end
                migrations[#migrations + 1] = {id = id, component = owner, target_db = target, timestamp = timestamp}
            end
        end
    end
    table.sort(modules, function(a: Module, b: Module): boolean return a.component < b.component end)
    table.sort(migrations, function(a: Migration, b: Migration): boolean return a.id < b.id end)
    table.sort(policy_changes, function(a: PolicyChange, b: PolicyChange): boolean return a.id < b.id end)
    table.sort(starts); table.sort(capabilities)
    table.sort(missing)
    local root_operation = request.action == "uninstall" and "delete" or (existing and "update" or "create")
    local plan: Plan = {request = request, base_revision = revision, root_id = root_id, root_operation = root_operation,
        digest = "", modules = modules,
        missing = missing, migrations = migrations, starts = starts, capabilities = capabilities,
        policy_changes = policy_changes, ready = #missing == 0, conversion = installed.conversion}
    local encoded, encode_error = canonical.encode(plan, 1048576)
    if not encoded then return nil, encode_error end
    local digest, digest_error = hash.sha256(encoded)
    if not digest then return nil, tostring(digest_error) end
    plan.digest = digest
    return {plan = plan, resolved = resolved, installed = installed}, nil
end
return M
