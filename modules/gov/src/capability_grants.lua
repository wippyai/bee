-- MIT. Host-owned capability grant values. Portable requirements remain
-- declarations; only generated policy entries installed by activation grant.
local bounds = require("bounds")
local canonical = require("canonical")
local hash = require("hash")
local catalog = require("capability_catalog")
local containment = require("capability_containment")
local files = require("capability_files")
local gateway = require("capability_gateway")

local M = {}
M.SCHEMA = "bee.governance-capability-grants@1"
M.PREFIX = "bee.gov.grants:"
-- Previously activated overlays retain their measured policy and record IDs.
-- Decode those exact IDs without rewriting approval-bound policy bytes.
local PRIOR_PREFIX = "bee.governance.grants:"
type Object = {[string]: unknown}
type Proposal = {capabilities: {Object}, policies: {Object}, bindings: {Object},
    volumes: {Object}, databases: {Object}, folder: Object?, thread_access: string, digest: string}

local function sha(raw: unknown): string?
    if type(raw) ~= "string" or #raw ~= 64 or not raw:match("^[0-9a-f]+$") then return nil end
    return raw
end
local function list(raw: unknown, limit: integer): {unknown}?
    if type(raw) ~= "table" then return nil end
    local count = 0
    for key in pairs(raw :: table) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil end
        count = count + 1
    end
    if count > limit then return nil end
    local capacity: integer = count > 0 and count or 1
    local result: {unknown} = table.create(capacity, 0)
    for index = 1, count do
        if (raw :: table)[index] == nil then return nil end
        result[index] = (raw :: table)[index]
    end
    return result
end
local function digest(value: unknown): string?
    local bytes = canonical.encode(value)
    return bytes and hash.sha256(bytes) or nil
end
local function policy_id(owner: string, requirement: string, prefix: string?): string?
    local suffix = digest({owner = owner, requirement = requirement})
    return suffix and (prefix or M.PREFIX) .. "policy." .. suffix or nil
end
function M.record_id(owner_raw: unknown): string?
    local owner = bounds.id(owner_raw)
    local suffix = owner and hash.sha256(owner) or nil
    return suffix and M.PREFIX .. "record." .. suffix or nil
end
function M.prior_record_id(owner_raw: unknown): string?
    local owner = bounds.id(owner_raw)
    local suffix = owner and hash.sha256(owner) or nil
    return suffix and PRIOR_PREFIX .. "record." .. suffix or nil
end
function M.reserved(raw: unknown): boolean
    return type(raw) == "string" and (raw:sub(1, #M.PREFIX) == M.PREFIX
        or raw:sub(1, #PRIOR_PREFIX) == PRIOR_PREFIX)
end

local function string_list(raw: unknown, pattern: string): {string}?
    if type(raw) ~= "table" then return nil end
    local result: {string} = {}
    local seen: {[string]: boolean} = {}
    for _, item in ipairs(raw :: {unknown}) do
        if type(item) ~= "string" or not (item :: string):match(pattern) or seen[item :: string] then
            return nil
        end
        seen[item :: string] = true
        result[#result + 1] = item :: string
    end
    if #result == 0 or #result > 16 then return nil end
    table.sort(result)
    return result
end

-- Each installable catalog entry materializes into generated host entries: a
-- policy plus the host-created volume or database it authorizes. Hive
-- exposure stays host-published review vocabulary with no app grant.
local function policy(owner: string, grant: Object, id: string, folder: unknown): (Object?, Object?, Object?, string?)
    local scope = bounds.object(grant.scope)
    if not scope then return nil, nil, nil, "capability scope is malformed" end
    if grant.capability == "threads.read" and grant.operation == "threads.read"
        and grant.resource == "threads" and scope.scope == "owned" then
        return {id = id, kind = "security.policy", meta = {comment = "Host-generated owned thread read grant"},
            data = {policy = {actions = {"funcs.call"},
                resources = {"bee.threads.service:get", "bee.threads.service:list",
                    "bee.threads.service:read_after"}, effect = "allow"}}}, nil, nil, nil
    end
    if (grant.capability == "workspace.files.read" or grant.capability == "workspace.files.write")
        and (grant.operation == "files.read" or grant.operation == "files.write")
        and grant.resource == "workspace" and type(scope.subpath) == "string" then
        local writable = grant.capability == "workspace.files.write"
        local volume, volume_error = files.volume(owner, folder, scope.subpath, writable)
        local generated, policy_error = volume and files.file_policy(owner, folder, scope.subpath, writable, id) or nil
        if not volume or not generated then
            return nil, nil, nil, volume_error or policy_error or "workspace file grant is not installable"
        end
        return generated, volume, nil, nil
    end
    if grant.capability == "app.database" and grant.operation == "database.use"
        and grant.resource == scope.name and type(scope.name) == "string" then
        local database, database_error = files.database(owner, scope.name)
        local generated, policy_error = database and files.database_policy(owner, scope.name, id) or nil
        if not database or not generated then
            return nil, nil, nil, database_error or policy_error or "application database grant is not installable"
        end
        return generated, nil, database, nil
    end
    if grant.capability == "threads.message" and grant.operation == "threads.message"
        and grant.resource == "threads" and scope.scope == "children" then
        return {id = id, kind = "security.policy", meta = {comment = "Host-generated child thread message grant"},
            data = {policy = {actions = {"funcs.call"},
                resources = {"bee.threads.service:send", "bee.threads.service:notify"},
                effect = "allow"}}}, nil, nil, nil
    end
    if grant.capability == "agents.launch" and grant.operation == "agents.launch"
        and grant.resource == "managed_agents" then
        local definitions = string_list(scope.definitions, "^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+$")
        if not definitions then
            return nil, nil, nil, "managed agent launch grant names no valid definitions"
        end
        return {id = id, kind = "security.policy",
            meta = {comment = "Host-generated managed agent launch grant"},
            data = {policy = {actions = {"bee.harness.launch"}, resources = definitions,
                effect = "allow"}}}, nil, nil, nil
    end
    -- The runtime cannot pair a contract binding with its method or an HTTP
    -- method with its origin, so these grants let the application call the
    -- host gateway, which checks the exact approved scope from this record.
    if grant.capability == "contract.call" and grant.operation == "contract.call"
        and bounds.id(grant.resource) and string_list(scope.methods, "^[A-Za-z][A-Za-z0-9_]*$") then
        return {id = id, kind = "security.policy", meta = {comment = "Host-generated contract gateway grant"},
            data = {policy = {actions = {"funcs.call"}, resources = {gateway.CONTRACT_CALL},
                effect = "allow"}}}, nil, nil, nil
    end
    if grant.capability == "http.api" and grant.operation == "http.request"
        and type(grant.resource) == "string" and type(scope.path_prefix) == "string"
        and string_list(scope.methods, "^[A-Z]+$") then
        return {id = id, kind = "security.policy", meta = {comment = "Host-generated HTTP gateway grant"},
            data = {policy = {actions = {"funcs.call"}, resources = {gateway.HTTP_REQUEST},
                effect = "allow"}}}, nil, nil, nil
    end
    return nil, nil, nil, "capability has no application-installable enforcement"
end

-- The workspace folder is part of the measured set whenever a volume is
-- rooted in it, so a moved workspace cannot reuse a grant for its old tree.
local function digest_shape(capabilities: {Object}, bindings: {Object}, policies: {Object},
    volumes: {Object}, databases: {Object}, folder: unknown): Object
    local shape: Object = {capabilities = capabilities, bindings = bindings, policies = policies,
        thread_access = "none"}
    if #volumes > 0 then shape.volumes, shape.folder = volumes, folder end
    if #databases > 0 then shape.databases = databases end
    return shape
end

-- folder is the host-resolved workspace folder file grants are rooted in.
function M.propose(vocabulary: catalog.Catalog, owner_raw: unknown, app_raw: unknown,
    requirements_raw: unknown, prior: boolean?, folder: unknown?): (Proposal?, string?)
    local owner, app = bounds.id(owner_raw), bounds.id(app_raw)
    local rows = list(requirements_raw, 8)
    if not owner or not app or not rows then return nil, "capability proposal identity is invalid" end
    local capacity: integer = #rows > 0 and #rows or 1
    local capabilities: {Object} = table.create(capacity, 0)
    local policies: {Object} = table.create(capacity, 0)
    local bindings: {Object} = table.create(capacity, 0)
    local volumes: {Object} = table.create(1, 0)
    local databases: {Object} = table.create(1, 0)
    local volume_ids: {[string]: boolean} = {}
    local database_ids: {[string]: boolean} = {}
    local requirement_of: {[Object]: string} = {}
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(rows) do
        local item = bounds.object(raw)
        local request = item and bounds.object(item.capability_request) or nil
        local requirement_id = item and bounds.id(item.id) or nil
        local targets = item and list(item.targets, 1) or nil
        if not item or not request or not requirement_id or seen[requirement_id]
            or not targets or #targets ~= 1 or targets[1] ~= app
            or item.value ~= nil or item.expected_kind ~= "security.policy"
            or request.target ~= app or request.path ~= ".security.policies +="
            or request.catalog_revision ~= vocabulary.revision then
            return nil, "capability requirement is not a measured app policy append"
        end
        local template = type(request.capability) == "string" and vocabulary.capabilities[request.capability] or nil
        if not template or request.template_revision ~= template.revision then
            return nil, "capability template changed since resolution"
        end
        local resolved, resolve_error = catalog.resolve(vocabulary, request.capability, request.parameters)
        if not resolved then return nil, resolve_error end
        if #resolved ~= 1 then return nil, "capability template needs unsupported policy count" end
        local id = policy_id(owner :: string, requirement_id :: string, prior and PRIOR_PREFIX or nil)
        if not id then return nil, "measure generated policy identity" end
        local generated, volume, database, policy_error = policy(owner :: string, resolved[1], id, folder)
        if not generated then return nil, policy_error end
        seen[requirement_id] = true
        requirement_of[resolved[1]] = requirement_id :: string
        capabilities[#capabilities + 1] = resolved[1]
        policies[#policies + 1] = generated
        bindings[#bindings + 1] = {requirement_id = requirement_id, policy_id = id}
        if volume then
            local volume_id = (volume :: Object).id :: string
            if not volume_ids[volume_id] then
                volume_ids[volume_id] = true
                volumes[#volumes + 1] = volume
            end
        end
        if database then
            local database_id = (database :: Object).id :: string
            if not database_ids[database_id] then
                database_ids[database_id] = true
                databases[#databases + 1] = database
            end
        end
    end
    -- Capabilities follow their bindings' requirement order, so a record
    -- pairs each grant with the requirement that asked for it.
    table.sort(capabilities, function(a: Object, b: Object): boolean
        return requirement_of[a] < requirement_of[b]
    end)
    table.sort(policies, function(a: Object, b: Object): boolean return tostring(a.id) < tostring(b.id) end)
    table.sort(bindings, function(a: Object, b: Object): boolean
        return tostring(a.requirement_id) < tostring(b.requirement_id)
    end)
    table.sort(volumes, function(a: Object, b: Object): boolean return tostring(a.id) < tostring(b.id) end)
    table.sort(databases, function(a: Object, b: Object): boolean return tostring(a.id) < tostring(b.id) end)
    local rooted: Object? = nil
    if #volumes > 0 then rooted = bounds.object(folder) end
    local set_digest = digest(digest_shape(capabilities, bindings, policies, volumes, databases, rooted))
    if not set_digest then return nil, "measure capability proposal" end
    return {capabilities = capabilities, policies = policies, bindings = bindings,
        volumes = volumes, databases = databases, folder = rooted, thread_access = "none", digest = set_digest}, nil
end

function M.record(owner_raw: unknown, workspace_raw: unknown, app_raw: unknown,
    proposal: Proposal, approval_raw: unknown, revision_raw: unknown,
    artifact_raw: unknown?, version_raw: unknown?, prior: boolean?): (Object?, string?)
    local owner, workspace, app = bounds.id(owner_raw), bounds.id(workspace_raw), bounds.id(app_raw)
    local approval_id, revision = bounds.id(approval_raw), bounds.count(revision_raw)
    local id = prior and M.prior_record_id(owner) or M.record_id(owner)
    if not owner or not workspace or not app or not approval_id or not revision or revision < 1
        or not id or not sha(proposal.digest) then return nil, "capability grant record is invalid" end
    local artifact_digest = artifact_raw == nil and nil or sha(artifact_raw)
    local version = version_raw == nil and nil or bounds.id(version_raw)
    if (artifact_raw ~= nil and not artifact_digest) or (version_raw ~= nil and not version) then
        return nil, "capability grant artifact identity is invalid"
    end
    local stored: Object = {schema_revision = M.SCHEMA, overlay_owner = owner, workspace_id = workspace,
        application = app, capabilities = proposal.capabilities, bindings = proposal.bindings,
        policies = proposal.policies, thread_access = proposal.thread_access,
        digest = proposal.digest, approval_id = approval_id, revision = revision,
        artifact_digest = artifact_digest, version = version}
    if #proposal.volumes > 0 then stored.volumes, stored.folder = proposal.volumes, proposal.folder end
    if #proposal.databases > 0 then stored.databases = proposal.databases end
    return {id = id, kind = "registry.entry", meta = {type = M.SCHEMA}, data = stored}, nil
end

function M.decode(raw: unknown, owner_raw: unknown, workspace_raw: unknown,
    app_raw: unknown, vocabulary: catalog.Catalog): (Object?, string?)
    local item, owner = bounds.object(raw), bounds.id(owner_raw)
    local data = item and bounds.object(item.data) or nil
    local expected = M.record_id(owner)
    local prior_id = M.prior_record_id(owner)
    local meta = item and bounds.object(item.meta) or nil
    if not item or not data or not meta or meta.type ~= M.SCHEMA
        or (item.id ~= expected and item.id ~= prior_id) or item.kind ~= "registry.entry"
        or data.schema_revision ~= M.SCHEMA or data.overlay_owner ~= owner
        or data.workspace_id ~= workspace_raw or data.application ~= app_raw
        or not bounds.id(data.approval_id) or not bounds.count(data.revision)
        or data.revision < 1
        or not sha(data.digest) or data.thread_access ~= "none" then
        return nil, "installed capability grant record is malformed"
    end
    local capabilities, bindings, policies = list(data.capabilities, 128), list(data.bindings, 128), list(data.policies, 128)
    local volumes = list(data.volumes or {}, 8)
    local databases = list(data.databases or {}, 8)
    if not capabilities or not bindings or not policies or not volumes or not databases
        or #capabilities ~= #bindings or #bindings ~= #policies then
        return nil, "installed capability grant set is malformed"
    end
    for _, raw_volume in ipairs(volumes) do
        local volume = bounds.object(raw_volume)
        local id = volume and bounds.text(volume.id, 160) or nil
        if not volume or not id or id:sub(1, #files.VOLUME_PREFIX) ~= files.VOLUME_PREFIX
            or volume.kind ~= "fs.directory" then
            return nil, "installed capability volume is malformed"
        end
    end
    for _, raw_database in ipairs(databases) do
        local database = bounds.object(raw_database)
        local id = database and bounds.text(database.id, 160) or nil
        if not database or not id or id:sub(1, #files.DATABASE_PREFIX) ~= files.DATABASE_PREFIX
            or database.kind ~= "db.sql.sqlite" then
            return nil, "installed capability database is malformed"
        end
    end
    local actual = digest(digest_shape(capabilities :: {Object}, bindings :: {Object},
        policies :: {Object}, volumes :: {Object}, databases :: {Object}, data.folder))
    if actual ~= data.digest then return nil, "installed capability digest differs from the stored set" end
    local capacity: integer = #bindings > 0 and #bindings or 1
    local reproduced: {Object} = table.create(capacity, 0)
    for index, raw_binding in ipairs(bindings) do
        local binding = bounds.object(raw_binding)
        local grant = bounds.object(capabilities[index])
        if not binding or not grant or not bounds.id(binding.requirement_id)
            or not bounds.id(binding.policy_id) then return nil, "installed capability binding is malformed" end
        reproduced[index] = {id = binding.requirement_id, value = nil,
            expected_kind = "security.policy", targets = {app_raw}, capability_request = {
                capability = grant.capability, parameters = grant.parameters,
                template_revision = grant.template_revision, catalog_revision = vocabulary.revision,
                target = app_raw, path = ".security.policies +="}}
    end
    local resolved, resolve_error = M.propose(vocabulary, owner, app_raw, reproduced, item.id == prior_id,
        data.folder)
    if not resolved or resolved.digest ~= data.digest then
        return nil, resolve_error or "installed capability digest differs from host templates"
    end
    if data.artifact_digest ~= nil and not sha(data.artifact_digest) then
        return nil, "installed grant artifact digest is invalid"
    end
    if data.version ~= nil and not bounds.id(data.version) then
        return nil, "installed grant version is invalid"
    end
    local measured_record = digest(data)
    if not measured_record then return nil, "measure installed grant record" end
    local copy: Object = {}
    for field, value in pairs(data) do copy[field] = value end
    copy.record_digest = measured_record
    return copy, nil
end

-- The generated host entries a live installed record stands for, in the
-- shape activation composes into the application's overlay.
function M.installed(record_raw: unknown, record: Object): Object
    local entry: Object = {}
    for key, value in pairs((record_raw :: Object)) do if key ~= "registry" then entry[key] = value end end
    return {policies = record.policies, bindings = record.bindings, volumes = record.volumes,
        databases = record.databases, record = entry}
end

-- A registry record is live only while its generated policies, volumes,
-- databases and requirement defaults are installed beside it. An orphaned
-- record cannot authorize reuse.
function M.live(record: Object, lookup: (string) -> unknown): (boolean, string?)
    for _, raw_policy in ipairs(record.policies :: {unknown}) do
        local expected = bounds.object(raw_policy)
        local id = expected and bounds.id(expected.id) or nil
        local current = id and bounds.object(lookup(id)) or nil
        if not expected or not current then return false, "installed grant policy is absent" end
        local clean: Object = {}
        for key, value in pairs(current) do if key ~= "registry" then clean[key] = value end end
        if digest(clean) ~= digest(expected) then return false, "installed grant policy differs from approval" end
    end
    for _, field in ipairs({"volumes", "databases"}) do
        for _, raw_entry in ipairs((record[field] or {}) :: {unknown}) do
            local expected = bounds.object(raw_entry)
            local id = expected and bounds.id(expected.id) or nil
            local current = id and bounds.object(lookup(id)) or nil
            if not expected or not current then return false, "installed grant resource is absent" end
            local clean: Object = {}
            for key, value in pairs(current) do if key ~= "registry" then clean[key] = value end end
            if digest(clean) ~= digest(expected) then
                return false, "installed grant resource differs from approval"
            end
        end
    end
    for _, raw_binding in ipairs(record.bindings :: {unknown}) do
        local binding = bounds.object(raw_binding)
        local requirement = binding and bounds.object(lookup(binding.requirement_id :: string)) or nil
        local data = requirement and bounds.object(requirement.data) or nil
        if not requirement or requirement.kind ~= "ns.requirement" or not data
            or data.default ~= binding.policy_id then
            return false, "installed requirement binding differs from approval"
        end
    end
    return true, nil
end

function M.diff(vocabulary: catalog.Catalog, installed: Object?, proposal: Proposal): (Object?, string?)
    local old = installed and installed.capabilities or table.create(1, 0)
    local compared, compare_error = containment.compare(old, proposal.capabilities)
    if not compared then return nil, compare_error end
    local lines: {string} = {}
    for _, category in ipairs({"added", "widened", "narrowed", "removed", "changed"}) do
        for _, raw_change in ipairs(compared[category] :: {unknown}) do
            local change = raw_change :: Object
            local value = category == "removed" and change.before or change.after
            local rendered, render_error = catalog.render(vocabulary, {value})
            if not rendered then return nil, render_error end
            lines[#lines + 1] = category .. ": " .. tostring(rendered[1])
        end
    end
    local flows, flow_error = catalog.render(vocabulary, proposal.capabilities)
    if not flows then return nil, flow_error end
    for _, line in ipairs(flows) do
        if line:find(" may be sent to ", 1, true) then lines[#lines + 1] = line end
    end
    compared.lines = lines
    return compared, nil
end

return M
