-- MIT. The typed request that starts a managed agent, shared by the
-- application agents library, the gateway's thread_launch tool and the
-- harness that admits it: a launch definition or saved profile, a brief, a
-- retry key and the optional workspace, working directory, thread and
-- placement. It is pure; decoding a request admits nothing, and every
-- choice takes effect only where the definition and its host launch policy
-- allow it.
local bounds = require("bounds")
local M = {}
M.MAX_BRIEF_BYTES = 16384
M.MAX_KEY_BYTES = 64
M.PLACEMENTS = {"native", "docker"}
-- The working directory: a resource associated in the workspace, or a folder
-- (path, default the root itself) under a root the host admits.
type Workdir = {resource: string?, root_ref: string?, path: string?}
-- The thread: an existing one the caller may write to, or a new one titled.
type Thread = {thread_id: string?, title: string?}
-- workspace_id names the workspace to launch into; absent, it is the caller's
-- own. A saved profile selects preferences for its own definition_ref.
type Launch = {definition_ref: string, brief: string, idempotency_key: string, workspace_id: string?,
    saved_profile_id: string?, saved_profile_revision: integer?, workdir: Workdir?, thread: Thread?, placement: string?,
    agent_ref: string?, owner_component_revision: integer?, spec_digest: string?}
local function fields(value: unknown, allowed: {string}): string?
    return bounds.fields(value, allowed)
end
function M.decode(value: unknown): (Launch?, string?)
    local object = bounds.object(value)
    if not object then return nil, "request must be an object" end
    local unknown = fields(object, {"definition_ref", "brief", "idempotency_key", "workspace_id", "saved_profile_id", "saved_profile_revision", "workdir", "thread", "placement", "agent_ref", "owner_component_revision", "owner_revision", "spec_digest", "expected_spec_digest"})
    if unknown then return nil, unknown end
    local definition_ref = bounds.id(object.definition_ref)
    if not definition_ref then return nil, "definition_ref is not an identifier" end
    local brief = bounds.text(object.brief, M.MAX_BRIEF_BYTES)
    if not brief or brief == "" then return nil, "brief must be nonempty bounded text" end
    local idempotency_key = bounds.id(object.idempotency_key)
    if not idempotency_key or #idempotency_key > M.MAX_KEY_BYTES then return nil, "idempotency_key is not a bounded identifier" end
    local workspace_id: string? = nil
    if object.workspace_id ~= nil then
        local id = bounds.id(object.workspace_id)
        if not id or #id ~= 32 or id:find("[^0-9a-f]") then return nil, "workspace_id must be a workspace identity" end
        workspace_id = id
    end
    local saved_profile_id: string? = nil
    local saved_profile_revision: integer? = nil
    if object.saved_profile_id ~= nil or object.saved_profile_revision ~= nil then
        saved_profile_id, saved_profile_revision = bounds.id(object.saved_profile_id), bounds.count(object.saved_profile_revision)
        if not saved_profile_id or not saved_profile_revision or saved_profile_revision < 1 then return nil, "a saved profile needs saved_profile_id and a positive saved_profile_revision" end
    end
    local workdir: Workdir? = nil
    if object.workdir ~= nil then
        local declared = bounds.object(object.workdir)
        if not declared then return nil, "workdir must be an object" end
        local extra = fields(declared, {"resource", "root_ref", "path"})
        if extra then return nil, "workdir: " .. extra end
        if declared.resource ~= nil then
            local resource = bounds.id(declared.resource)
            if not resource or declared.root_ref ~= nil or declared.path ~= nil then return nil, "workdir names either a resource or a root_ref and path" end
            workdir = {resource = resource}
        else
            local root_ref = bounds.id(declared.root_ref)
            if not root_ref then return nil, "workdir names either a resource or a root_ref and path" end
            local path, path_error = bounds.subpath(declared.path == nil and "" or declared.path)
            if not path then return nil, "workdir.path: " .. tostring(path_error) end
            workdir = {root_ref = root_ref, path = path}
        end
    end
    local thread: Thread? = nil
    if object.thread ~= nil then
        local declared = bounds.object(object.thread)
        if not declared then return nil, "thread must be an object" end
        local extra = fields(declared, {"thread_id", "title"})
        if extra then return nil, "thread: " .. extra end
        if declared.thread_id ~= nil then
            local thread_id = bounds.id(declared.thread_id)
            if not thread_id or declared.title ~= nil then return nil, "thread names either a thread_id or a title" end
            thread = {thread_id = thread_id}
        else
            local title = bounds.line(declared.title, bounds.MAX_TITLE_BYTES)
            if not title then return nil, "thread names either a thread_id or a title" end
            thread = {title = title}
        end
    end
    local placement: string? = nil
    if object.placement ~= nil then
        placement = bounds.member(object.placement, M.PLACEMENTS)
        if not placement then return nil, "placement must be native or docker" end
    end
    local agent_ref: string? = nil
    if object.agent_ref ~= nil then
        agent_ref = bounds.id(object.agent_ref)
        if not agent_ref then return nil, "agent_ref is not an identifier" end
    end
    local owner_component_revision: integer? = nil
    local rev_raw = object.owner_component_revision ~= nil and object.owner_component_revision or object.owner_revision
    if rev_raw ~= nil then
        local count = bounds.count(rev_raw)
        if not count or count < 1 then return nil, "owner_component_revision must be a positive integer" end
        owner_component_revision = count
    end
    local spec_digest: string? = nil
    local digest_raw = object.spec_digest ~= nil and object.spec_digest or object.expected_spec_digest
    if digest_raw ~= nil then
        local digest = bounds.text(digest_raw, 64)
        if not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then
            return nil, "spec_digest must be a lowercase SHA-256 hex digest"
        end
        spec_digest = digest
    end
    return {definition_ref = definition_ref, brief = brief, idempotency_key = idempotency_key, workspace_id = workspace_id,
        saved_profile_id = saved_profile_id, saved_profile_revision = saved_profile_revision, workdir = workdir, thread = thread, placement = placement,
        agent_ref = agent_ref, owner_component_revision = owner_component_revision, spec_digest = spec_digest}, nil
end
return M
