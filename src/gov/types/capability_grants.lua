-- MIT. Host-owned capability grant values. Portable requirements remain
-- declarations; only generated policy entries installed by activation grant.
local bounds = require("bounds")
local canonical = require("canonical")
local hash = require("hash")
local capability_model = require("capability_model")
local files = require("capability_files")
local gateway = require("capability_gateway")

local M = {}
M.SCHEMA = "bee.governance-capability-grants@1"
M.PREFIX = "bee.gov.grants:"
-- Previously activated overlays retain their measured policy and record IDs.
-- Decode those exact IDs without rewriting approval-bound policy bytes.
local PRIOR_PREFIX = "bee.governance.grants:"
type Object = {[string]: unknown}
type Proposal = {capabilities: {capability_model.Grant}, policies: {Object}, bindings: {Object},
    volumes: {Object}, databases: {Object}, executors: {Object}, folder: Object?, thread_access: string, digest: string}
type Installed = {schema_revision: string, overlay_owner: string, workspace_id: string, application: string,
    capabilities: {capability_model.Grant}, bindings: {Object}, policies: {Object}, thread_access: string, digest: string,
    approval_id: string, revision: integer, artifact_digest: string?, version: string?, volumes: {Object}?,
    databases: {Object}?, executors: {Object}?, folder: Object?, record_digest: string}
type Change = {before: capability_model.Grant?, after: capability_model.Grant?}
type Review = {added: {Change}, widened: {Change}, narrowed: {Change}, removed: {Change}, changed: {Change},
    requires_approval: boolean, revocation: capability_model.Revocation,
    lines: {string}, resolved: {string}, delta: {string}}

local function sha(raw: unknown): string?
    if type(raw) ~= "string" or #raw ~= 64 or not raw:match("^[0-9a-f]+$") then return nil end
    return raw
end
local function list(raw: unknown, limit: integer): {unknown}?
    local rows = bounds.dense_list(raw, limit, "capability grant values")
    return rows
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

-- Host-composed package applications admit through the shared package
-- ceiling; each generated body repeats its reviewed static policy exactly.
-- Other catalog entries remain review vocabulary until their resource and
-- owner boundaries arrive in later slices.
local SESSIONS_EXPRESSION = '(action == "contract.get" && resource in ["bee.threads.sessions:contract", "bee.threads.sessions:catalog"]) || (action == "contract.open" && resource in ["bee.threads.sessions:contract", "bee.threads.sessions:catalog", "bee.threads.sessions.binding:owner_binding", "bee.threads.sessions.binding:catalog_binding"]) || (action == "contract.call" && resource in ["open", "run", "send", "get", "list", "history", "await", "join", "cancel", "close"]) || (action == "funcs.call" && resource in ["bee.threads.sessions.binding:open", "bee.threads.sessions.binding:run", "bee.threads.sessions.binding:send", "bee.threads.sessions.binding:get", "bee.threads.sessions.binding:list", "bee.threads.sessions.binding:history", "bee.threads.sessions.binding:await", "bee.threads.sessions.binding:join", "bee.threads.sessions.binding:cancel", "bee.threads.sessions.binding:close", "bee.threads.sessions.binding:catalog"])'

local function plain(actions: {string}, resources: unknown, comment: string, id: string): Object
    return {id = id, kind = "security.policy", meta = {comment = comment},
        data = {policy = {actions = actions, resources = resources, effect = "allow"}}}
end

local function package_policy(grant: Object, id: string, app: string): Object?
    if grant.capability == "hive.view" and grant.operation == "hive.view"
        and grant.resource == "cluster" then
        return plain({"system.read"}, {"cluster"}, "Host-generated Hive membership view grant", id)
    end
    if grant.capability == "desktop.application_stop" and grant.operation == "desktop.application_stop"
        and grant.resource == "applications" then
        return plain({"system.read"}, {"hosts", "memory", "goroutines", "supervisor"},
            "Host-generated host process inspection grant", id)
    end
    if grant.capability == "hub.manage" and grant.operation == "hub.manage"
        and grant.resource == "components" then
        return plain({"bee.hub.read", "bee.hub.manage"}, "*", "Host-generated Hub management grant", id)
    end
    if app == "bee.apps.library:app" and grant.capability == "hub.self_update"
        and grant.operation == "hub.self_update" and grant.resource == "bee/bee" then
        return plain({"bee.hub.self_update"}, {"bee/bee"}, "Host-generated Bee deployment self-update grant", id)
    end
    if grant.capability == "gov.delivery.manage" and grant.operation == "gov.delivery.manage"
        and grant.resource == "overlays" then
        return plain({"bee.gov.delivery.manage"}, "*", "Host-generated delivery management grant", id)
    end
    if grant.capability == "gov.delivery.activate" and grant.operation == "gov.delivery.activate"
        and grant.resource == "overlays" then
        return plain({"bee.gov.delivery.activate"}, "*", "Host-generated delivery activation grant", id)
    end
    return nil
end

-- The capabilities whose generated enforcement is a policy expression: the
-- runtime pairs their actions with the approved resources and request
-- metadata only through one.
local EXPRESSION_CAPABILITIES: {[string]: boolean} = {["agents.launch"] = true, ["process.exec"] = true}
function M.expression(capability: unknown): boolean
    return type(capability) == "string" and EXPRESSION_CAPABILITIES[capability] == true
end

-- Each installable catalog entry materializes into generated host entries: a
-- policy plus the host-created volume, database or executor it authorizes. A
-- Hive exposure grant materializes into an exposure-scope policy over exactly
-- the approved operations; other review-vocabulary entries have no app grant.
type Generated = {policy: Object, volume: Object?, database: Object?, executor: Object?}
local function only(generated: Object): (Generated?, string?)
    return {policy = generated}, nil
end
local function policy(owner: string, grant: capability_model.Grant, id: string, folder: unknown, app: string): (Generated?, string?)
    local scope = grant.scope
    if grant.capability == "threads.read" and grant.operation == "threads.read"
        and grant.resource == "threads" and scope.scope == "owned" then
        return only({id = id, kind = "security.policy", meta = {comment = "Host-generated owned thread read grant"},
            data = {policy = {actions = {"funcs.call"},
                resources = {"bee.threads.binding:get", "bee.threads.binding:list",
                    "bee.threads.binding:read_after"}, effect = "allow"}}})
    end
    if (grant.capability == "workspace.files.read" or grant.capability == "workspace.files.write")
        and (grant.operation == "files.read" or grant.operation == "files.write")
        and grant.resource == "workspace" and type(scope.subpath) == "string" then
        local writable = grant.capability == "workspace.files.write"
        local volume, volume_error = files.volume(owner, folder, scope.subpath, writable)
        local generated, policy_error = volume and files.file_policy(owner, folder, scope.subpath, writable, id) or nil
        if not volume or not generated then
            return nil, volume_error or policy_error or "workspace file grant is not installable"
        end
        return {policy = generated, volume = volume}, nil
    end
    if grant.capability == "app.database" and grant.operation == "database.use"
        and grant.resource == scope.name and type(scope.name) == "string" then
        local database, database_error = files.database(owner, scope.name)
        local generated, policy_error = database and files.database_policy(owner, scope.name, id) or nil
        if not database or not generated then
            return nil, database_error or policy_error or "application database grant is not installable"
        end
        return {policy = generated, database = database}, nil
    end
    if grant.capability == "process.exec" and grant.operation == "process.exec"
        and type(scope.subpath) == "string" then
        local executor, executor_error = files.executor(owner, folder, scope.subpath, grant.resource)
        local generated, policy_error = executor and files.process_policy(owner, folder, scope.subpath,
            grant.resource, id) or nil
        if not executor or not generated then
            return nil, executor_error or policy_error or "process grant is not installable"
        end
        return {policy = generated, executor = executor}, nil
    end
    if grant.capability == "threads.message" and grant.operation == "threads.message"
        and grant.resource == "threads" and scope.scope == "children" then
        return only({id = id, kind = "security.policy", meta = {comment = "Host-generated child thread message grant"},
            data = {policy = {actions = {"funcs.call"},
                resources = {"bee.threads.binding:send", "bee.threads.binding:notify"},
                effect = "allow"}}})
    end
    if grant.capability == "agents.launch" and grant.operation == "agents.launch"
        and grant.resource == "managed_agents" then
        local definitions = capability_model.strings(scope.definitions)
        if not definitions then return nil, "resolved agent definition list is malformed" end
        local names: {string} = {}
        for _, ref in ipairs(definitions) do
            if not ref:match("^[A-Za-z0-9_.:-]+$") then return nil, "resolved agent definition name is malformed" end
            names[#names + 1] = '"' .. ref .. '"'
        end
        table.sort(names)
        local expression = SESSIONS_EXPRESSION .. ' || (action == "bee.harness.launch" && resource in [' .. table.concat(names, ", ") .. '])'
        return only({id = id, kind = "security.policy.expr",
            meta = {comment = "Host-generated managed agent session grant"},
            data = {policy = {actions = {"contract.get", "contract.open", "contract.call", "funcs.call", "bee.harness.launch"},
                resources = "*", expression = expression, effect = "allow"}}})
    end
    -- Agent tools run as the application: its scope may call exactly the
    -- approved tool functions, and the gateway reaches them only through it.
    if grant.capability == "agent.tools" and grant.operation == "agent.tools" then
        local tools = capability_model.strings(scope.tools)
        if not tools then return nil, "resolved agent tool list is malformed" end
        return only(plain({"funcs.call"}, tools, "Host-generated agent tool grant", id))
    end
    -- The runtime cannot pair a contract binding with its method or an HTTP
    -- method with its origin, so these grants let the application call the
    -- host gateway, which checks the exact approved scope from this record.
    if grant.capability == "contract.call" and grant.operation == "contract.call" then
        return only({id = id, kind = "security.policy", meta = {comment = "Host-generated contract gateway grant"},
            data = {policy = {actions = {"funcs.call"}, resources = {gateway.CONTRACT_CALL},
                effect = "allow"}}})
    end
    if grant.capability == "http.api" and grant.operation == "http.request" then
        return only({id = id, kind = "security.policy", meta = {comment = "Host-generated HTTP gateway grant"},
            data = {policy = {actions = {"funcs.call"}, resources = {gateway.HTTP_REQUEST},
                effect = "allow"}}})
    end
    if grant.capability == "hive.call" and grant.operation == "hive.call" then
        return only(plain({"funcs.call"}, {"bee.hive.binding:call"}, "Host-generated Hive call grant", id))
    end
    if grant.capability == "hive.expose" and grant.operation == "hive.expose" then
        local mode = grant.resource
        local operations = capability_model.strings(scope.operations)
        if not operations then return nil, "resolved Hive operation list is malformed" end
        return only({id = id, kind = "security.policy",
            meta = {comment = "Host-generated Hive operation exposure grant"},
            data = {groups = {"bee.security.hive:hive_exposure_scope"},
                policy = {actions = {"hive.expose." .. (mode)},
                    resources = operations, effect = "allow"}}})
    end
    if next(scope) == nil then
        local generated = package_policy(grant, id, app)
        if generated then return only(generated) end
    end
    return nil, "capability has no application-installable enforcement"
end

-- Runtime requests use the same host policy generator as installation before
-- they can reach approval. A synthetic workspace lets file templates be
-- checked without creating entries or needing a destination workspace.
function M.installable(operations: {capability_model.Grant}): (boolean?, string?)
    if #operations ~= 1 then return nil, "capability template needs unsupported policy count" end
    local folder: Object = {root_ref = "bee.resources:capability_check", directory = ".", subpath = ""}
    local generated, realize_error = policy("capability_check", operations[1],
        M.PREFIX .. "policy.check", folder, "capability_check:app")
    if not generated then return nil, realize_error or "capability has no application-installable enforcement" end
    return true, nil
end

-- The workspace folder is part of the measured set whenever a volume is
-- rooted in it, so a moved workspace cannot reuse a grant for its old tree.
local function digest_shape(capabilities: {Object}, bindings: {Object}, policies: {Object},
    volumes: {Object}, databases: {Object}, executors: {Object}, folder: unknown): Object
    local shape: Object = {capabilities = capabilities, bindings = bindings, policies = policies,
        thread_access = "none"}
    if #volumes > 0 then shape.volumes = volumes end
    if #executors > 0 then shape.executors = executors end
    if #volumes > 0 or #executors > 0 then shape.folder = folder end
    if #databases > 0 then shape.databases = databases end
    return shape
end

-- folder is the host-resolved workspace folder file grants are rooted in.
function M.propose(vocabulary: capability_model.Vocabulary, owner_raw: unknown, app_raw: unknown,
    requirements_raw: unknown, prior: boolean?, folder: unknown?): (Proposal?, string?)
    local owner, app = bounds.id(owner_raw), bounds.id(app_raw)
    local rows = list(requirements_raw, 8)
    if not owner or not app or not rows then return nil, "capability proposal identity is invalid" end
    local capacity: integer = #rows > 0 and #rows or 1
    local capabilities: {capability_model.Grant} = table.create(capacity, 0)
    local policies: {Object} = table.create(capacity, 0)
    local bindings: {Object} = table.create(capacity, 0)
    local volumes: {Object} = table.create(1, 0)
    local databases: {Object} = table.create(1, 0)
    local executors: {Object} = table.create(1, 0)
    local volume_ids: {[string]: boolean} = {}
    local database_ids: {[string]: boolean} = {}
    local executor_ids: {[string]: boolean} = {}
    local requirement_of: {[capability_model.Grant]: string} = {}
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(rows) do
        local item = bounds.object(raw)
        local request = item and bounds.object(item.capability_request) or nil
        local requirement_id = item and bounds.id(item.id) or nil
        local targets = item and list(item.targets, 1) or nil
        if not item or not request or not requirement_id or seen[requirement_id]
            or not targets or #targets ~= 1
            or item.value ~= nil or item.expected_kind ~= "security.policy"
            or request.path ~= ".security.policies +=" then
            return nil, "capability requirement is not a measured app policy append"
        end
        local capability = capability_model.identity(request.capability)
        if not capability then return nil, "capability request identity is invalid" end
        -- A Hive exposure grant joins the supervisor scope instead of an
        -- application, so its target is one of its own operations. The
        -- resolver already contained the named operations to the artifact.
        if capability == "hive.expose" then
            if request.target ~= targets[1] then
                return nil, "Hive exposure requirement target differs from its grant"
            end
        elseif targets[1] ~= app or request.target ~= app then
            return nil, "capability requirement is not a measured app policy append"
        end
        local catalog_revision, template_revision = capability_model.revisions(vocabulary, capability)
        if not catalog_revision or not template_revision or request.catalog_revision ~= catalog_revision
            or request.template_revision ~= template_revision then
            return nil, "capability template changed since resolution"
        end
        local resolved, resolve_error = capability_model.resolve(vocabulary, capability, request.parameters)
        if not resolved then return nil, resolve_error end
        local resolved_operations = resolved
        if #resolved_operations ~= 1 then return nil, "capability template needs unsupported policy count" end
        local id = policy_id(owner, requirement_id, prior and PRIOR_PREFIX or nil)
        if not id then return nil, "measure generated policy identity" end
        local generated, policy_error = policy(owner, resolved_operations[1], id, folder, app)
        if not generated then return nil, policy_error end
        local volume, database, executor = generated.volume, generated.database, generated.executor
        seen[requirement_id] = true
        requirement_of[resolved_operations[1]] = requirement_id
        capabilities[#capabilities + 1] = resolved_operations[1]
        policies[#policies + 1] = generated.policy
        bindings[#bindings + 1] = {requirement_id = requirement_id, policy_id = id}
        if volume then
            local volume_id = (volume).id
            if not volume_ids[volume_id] then
                volume_ids[volume_id] = true
                volumes[#volumes + 1] = volume
            end
        end
        if database then
            local database_id = (database).id
            if not database_ids[database_id] then
                database_ids[database_id] = true
                databases[#databases + 1] = database
            end
        end
        if executor then
            local executor_id = (executor).id
            if not executor_ids[executor_id] then
                executor_ids[executor_id] = true
                executors[#executors + 1] = executor
            end
        end
    end
    -- Capabilities follow their bindings' requirement order, so a record
    -- pairs each grant with the requirement that asked for it.
    table.sort(capabilities, function(a: capability_model.Grant, b: capability_model.Grant): boolean
        return requirement_of[a] < requirement_of[b]
    end)
    table.sort(policies, function(a: Object, b: Object): boolean return tostring(a.id) < tostring(b.id) end)
    table.sort(bindings, function(a: Object, b: Object): boolean
        return tostring(a.requirement_id) < tostring(b.requirement_id)
    end)
    table.sort(volumes, function(a: Object, b: Object): boolean return tostring(a.id) < tostring(b.id) end)
    table.sort(databases, function(a: Object, b: Object): boolean return tostring(a.id) < tostring(b.id) end)
    table.sort(executors, function(a: Object, b: Object): boolean return tostring(a.id) < tostring(b.id) end)
    local rooted: Object? = nil
    if #volumes > 0 or #executors > 0 then rooted = bounds.object(folder) end
    local set_digest = digest(digest_shape(capabilities, bindings, policies, volumes, databases, executors, rooted))
    if not set_digest then return nil, "measure capability proposal" end
    return {capabilities = capabilities, policies = policies, bindings = bindings,
        volumes = volumes, databases = databases, executors = executors, folder = rooted,
        thread_access = "none", digest = set_digest}, nil
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
    if #proposal.volumes > 0 then stored.volumes = proposal.volumes end
    if #proposal.executors > 0 then stored.executors = proposal.executors end
    if #proposal.volumes > 0 or #proposal.executors > 0 then stored.folder = proposal.folder end
    if #proposal.databases > 0 then stored.databases = proposal.databases end
    return {id = id, kind = "registry.entry", meta = {type = M.SCHEMA}, data = stored}, nil
end

function M.decode(raw: unknown, owner_raw: unknown, workspace_raw: unknown,
    app_raw: unknown, vocabulary: capability_model.Vocabulary): (Installed?, string?)
    local item = bounds.object(raw)
    local owner, workspace, app = bounds.id(owner_raw), bounds.id(workspace_raw), bounds.id(app_raw)
    if not owner or not workspace or not app then return nil, "installed capability grant identity is invalid" end
    local data = item and bounds.object(item.data) or nil
    local expected = M.record_id(owner)
    local prior_id = M.prior_record_id(owner)
    local meta = item and bounds.object(item.meta) or nil
    local approval_id = data and bounds.id(data.approval_id) or nil
    local revision = data and bounds.count(data.revision) or nil
    local stored_application = data and bounds.id(data.application) or nil
    local stored_digest = data and sha(data.digest) or nil
    if not item or not data or not meta then
        return nil, "installed capability grant record is malformed"
    end
    if meta.type ~= M.SCHEMA or (item.id ~= expected and item.id ~= prior_id)
        or item.kind ~= "registry.entry" or data.schema_revision ~= M.SCHEMA
        or data.overlay_owner ~= owner or data.workspace_id ~= workspace or data.thread_access ~= "none" then
        return nil, "installed capability grant record is malformed"
    end
    if not stored_application or stored_application ~= app then
        return nil, "installed capability grant application is malformed"
    end
    if not approval_id or revision == nil or revision < 1 or not stored_digest then
        return nil, "installed capability grant record is malformed"
    end
    local capabilities, bindings, policies = list(data.capabilities, 128), list(data.bindings, 128), list(data.policies, 128)
    local volumes = list(data.volumes or {}, 8)
    local databases = list(data.databases or {}, 8)
    local executors = list(data.executors or {}, 8)
    if not capabilities or not bindings or not policies or not volumes or not databases or not executors
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
    for _, raw_executor in ipairs(executors) do
        local executor = bounds.object(raw_executor)
        local id = executor and bounds.text(executor.id, 160) or nil
        if not executor or not id or id:sub(1, #files.EXECUTOR_PREFIX) ~= files.EXECUTOR_PREFIX
            or executor.kind ~= "exec.native" then
            return nil, "installed capability executor is malformed"
        end
    end
    local actual = digest(digest_shape(capabilities, bindings,
        policies, volumes, databases, executors, data.folder))
    if actual ~= stored_digest then return nil, "installed capability digest differs from the stored set" end
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
                template_revision = grant.template_revision,
                catalog_revision = capability_model.revisions(vocabulary, grant.capability),
                target = app_raw, path = ".security.policies +="}}
    end
    local resolved, resolve_error = M.propose(vocabulary, owner, app, reproduced, item.id == prior_id,
        data.folder)
    if not resolved or resolved.digest ~= stored_digest then
        return nil, resolve_error or "installed capability digest differs from host templates"
    end
    local artifact_digest = data.artifact_digest == nil and nil or sha(data.artifact_digest)
    if data.artifact_digest ~= nil and not artifact_digest then
        return nil, "installed grant artifact digest is invalid"
    end
    local version = data.version == nil and nil or bounds.id(data.version)
    if data.version ~= nil and not version then
        return nil, "installed grant version is invalid"
    end
    local measured_record = digest(data)
    if not measured_record then return nil, "measure installed grant record" end
    local installed: Installed = {schema_revision = M.SCHEMA, overlay_owner = owner, workspace_id = workspace,
        application = stored_application, capabilities = resolved.capabilities, bindings = resolved.bindings,
        policies = resolved.policies, thread_access = "none", digest = stored_digest,
        approval_id = approval_id, revision = revision,
        artifact_digest = artifact_digest, version = version, record_digest = measured_record}
    if data.volumes ~= nil then installed.volumes = resolved.volumes end
    if data.databases ~= nil then installed.databases = resolved.databases end
    if data.executors ~= nil then installed.executors = resolved.executors end
    if data.folder ~= nil then installed.folder = resolved.folder end
    return installed, nil
end

-- The generated host entries a live installed record stands for, in the
-- shape activation composes into the application's overlay.
function M.installed(record_raw: unknown, record: Installed): Object
    local entry: Object = {}
    for key, value in pairs((record_raw)) do if key ~= "registry" then entry[key] = value end end
    return {policies = record.policies, bindings = record.bindings, volumes = record.volumes,
        databases = record.databases, executors = record.executors, record = entry}
end

-- A registry record is live only while its generated policies, volumes,
-- databases, executors and requirement defaults are installed beside it. An
-- orphaned record cannot authorize reuse.
function M.live(record: Object, lookup: (string) -> unknown): (boolean, string?)
    for _, raw_policy in ipairs(record.policies) do
        local expected = bounds.object(raw_policy)
        local id = expected and bounds.id(expected.id) or nil
        local current = id and bounds.object(lookup(id)) or nil
        if not expected or not current then return false, "installed grant policy is absent" end
        local clean: Object = {}
        for key, value in pairs(current) do if key ~= "registry" then clean[key] = value end end
        if digest(clean) ~= digest(expected) then return false, "installed grant policy differs from approval" end
    end
    for _, field in ipairs({"volumes", "databases", "executors"}) do
        for _, raw_entry in ipairs((record[field] or {})) do
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
    for _, raw_binding in ipairs(record.bindings) do
        local binding = bounds.object(raw_binding)
        local requirement = binding and bounds.object(lookup(binding.requirement_id)) or nil
        local data = requirement and bounds.object(requirement.data) or nil
        if not requirement or requirement.kind ~= "ns.requirement" or not data
            or data.default ~= binding.policy_id then
            return false, "installed requirement binding differs from approval"
        end
    end
    return true, nil
end

function M.diff(vocabulary: capability_model.Vocabulary, installed: Installed?, proposal: Proposal): (Review?, string?)
    local old = installed and installed.capabilities or table.create(1, 0)
    local compared, compare_error = capability_model.compare(old, proposal.capabilities)
    if not compared then return nil, compare_error end
    local lines: {string} = {}
    for _, category in ipairs({"added", "widened", "narrowed", "changed"}) do
        for _, raw_change in ipairs(compared[category]) do
            local change = raw_change
            local value = change.after
            local rendered, render_error = capability_model.render(vocabulary, {value})
            if not rendered then return nil, render_error end
            lines[#lines + 1] = category .. ": " .. tostring(rendered[1])
        end
    end
    for _, grant in ipairs(compared.revocation.grants) do
        local scope, scope_error = canonical.encode(grant.scope)
        if not scope then return nil, tostring(scope_error or "measure revoked capability scope") end
        lines[#lines + 1] = "revoked: " .. grant.capability .. " " .. grant.operation
            .. " on " .. grant.resource .. " " .. scope
    end
    local flows, flow_error = capability_model.render(vocabulary, proposal.capabilities)
    if not flows then return nil, flow_error end
    for _, line in ipairs(flows) do
        if line:find(" may be sent to ", 1, true) then lines[#lines + 1] = line end
    end
    local review: Review = {added = compared.added, widened = compared.widened,
        narrowed = compared.narrowed, removed = compared.removed, changed = compared.changed,
        requires_approval = compared.requires_approval, revocation = compared.revocation,
        lines = lines, resolved = flows, delta = lines}
    return review, nil
end

return M
