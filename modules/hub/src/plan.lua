-- MIT. Hub plans describe one dependency-root change against a captured
-- registry revision. Confirmation covers the request and measured artifacts.
local bounds = require("bounds")
local canonical = require("canonical")
local hash = require("hash")
local graph = require("graph")
local inventory = require("inventory")
local requirements = require("requirements")
local semver = require("semver")
local M = {}
type Request = {action: string, component: string, version: string, parameters: {requirements.Parameter}, migration_policy: string}
type Module = {component: string, version: string, previous_version: string, digest: string,
    change: string, entries: integer, requirements: requirements.Result}
type Migration = {id: string, component: string, target_db: string, timestamp: string}
-- One security policy the plan adds, replaces with a new package version, or
-- removes with its departing package, summarized from the policy definition.
type PolicyChange = {id: string, component: string, change: string, actions: {string}, resources: {string},
    expression: boolean}
type Plan = {request: Request, base_revision: integer, root_id: string, digest: string,
    modules: {Module}, missing: {string}, migrations: {Migration}, starts: {string}, capabilities: {string},
    policy_changes: {PolicyChange}, ready: boolean}
type Prepared = {plan: Plan, resolved: graph.Result, installed: inventory.Result}

local POLICY_KINDS: {[string]: boolean} = {["security.policy"] = true, ["security.policy.expr"] = true}

local function names(raw: unknown): {string}
    if type(raw) == "string" then return {raw} end
    local result: {string} = {}
    if type(raw) ~= "table" then return result end
    for _, item in ipairs(raw :: {unknown}) do
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

function M.prepare(state: unknown, revision: integer, request: Request, source: graph.Source): (Prepared?, string?)
    local installed, inventory_error = inventory.decode(state, revision)
    if not installed then return nil, inventory_error end
    local controlled = inventory.dependency_members(installed)
    local raw_state = bounds.object(state)
    if not raw_state or type(raw_state.entries) ~= "table" then return nil, "invalid captured registry" end
    local root_id, root_error = M.root_id(request.component)
    if not root_id then return nil, root_error end
    local existing: inventory.Root? = nil
    local roots: {graph.Edge} = {}
    for _, root in ipairs(installed.roots) do
        if root.id:sub(1, 13) == "bee.hub.deps:" then
            if root.component == request.component then
                if existing then return nil, "component has multiple roots; host configuration needs review" end
                existing = root
            elseif controlled[root.component] then
                roots[#roots + 1] = {component = root.component, version = root.version, parameters = root.parameters}
            end
        end
    end
    for _, item in ipairs(installed.modules) do
        if item.component == request.component and not controlled[item.component] and (item.entries > 0 or item.version ~= "") then
            return nil, "component is managed by the host deployment"
        end
    end
    if existing and existing.id ~= root_id then return nil, "component is managed by host configuration at " .. existing.id end
    if request.action == "install" and existing then return nil, "component already has an installed root; choose update" end
    if request.action ~= "install" and not existing then return nil, "component has no installed Hub root" end
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
        if entry and owned and data and entry.kind == "ns.dependency" and type(owned.owner) == "string"
            and owned.owner ~= "" and not controlled[owned.owner] and type(data.component) == "string"
            and controlled[data.component] then
            local reference, reference_error = graph.edge(data)
            if not reference then return nil, reference_error end
            roots[#roots + 1] = reference
        end
    end
    local resolved, graph_error = graph.resolve(roots, source)
    if not resolved then return nil, graph_error end
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
    local remaining: {[string]: boolean} = {}
    for _, item in ipairs(resolved.packages) do
        remaining[item.component] = true
        local old = by_name[item.component]
        local previous = old and old.version or ""
        if old and not controlled[item.component] and (semver.compare(previous, item.version) or 1) ~= 0 then
            return nil, "dependency would replace a host-deployment module: " .. item.component
        end
        local change = previous == "" and "install" or ((semver.compare(previous, item.version) or 1) == 0 and "keep" or "update")
        modules[#modules + 1] = {component = item.component, version = item.version, previous_version = previous,
            digest = item.digest, change = change, entries = #item.entries, requirements = item.requirements}
        if change ~= "keep" then changed_components[item.component] = true end
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
            if remove then changed_components[item.component] = true end
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
    local plan: Plan = {request = request, base_revision = revision, root_id = root_id, digest = "", modules = modules,
        missing = resolved.missing, migrations = migrations, starts = starts, capabilities = capabilities,
        policy_changes = policy_changes, ready = #resolved.missing == 0}
    local encoded, encode_error = canonical.encode(plan)
    if not encoded then return nil, encode_error end
    local digest, digest_error = hash.sha256(encoded)
    if not digest then return nil, tostring(digest_error) end
    plan.digest = digest
    return {plan = plan, resolved = resolved, installed = installed}, nil
end
return M
