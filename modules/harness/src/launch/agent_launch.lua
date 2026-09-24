-- MIT. The bounded request an agent or an application makes to start a
-- managed agent, the host-named allow-list that decides which launch
-- definitions a managed agent may start, and the run identities its status,
-- wait and cancel name. It is pure: it reads no store, starts nothing and
-- grants nothing. Every choice a request makes is admitted only where the
-- definition and its host launch policy allow it.
local hash = require("hash")
local bounds = require("bounds")
local M = {}
M.MAX_BRIEF_BYTES = 16384
M.MAX_KEY_BYTES = 64
M.MAX_WAIT_MS = 60000
M.PLACEMENTS = {"native", "docker"}
-- The working directory: a resource associated in the workspace, or a folder
-- (path, default the root itself) under a root the host admits.
type Workdir = {resource: string?, root_ref: string?, path: string?}
-- The thread: an existing one the caller may write to, or a new one titled.
type Thread = {thread_id: string?, title: string?}
-- workspace_id names the workspace to launch into; absent, it is the caller's
-- own. A saved profile selects preferences for its own definition_ref.
type Request = {definition_ref: string, brief: string, idempotency_key: string, workspace_id: string?,
    saved_profile_id: string?, saved_profile_revision: integer?, workdir: Workdir?, thread: Thread?, placement: string?}
type Run = {thread_id: string, attempt_id: string}
-- The action a caller's own scope must grant on a workspace other than its
-- binding's before it may launch there.
M.LAUNCH_ACTION = "bee.workspaces.launch"
-- The action a host grants an application on a launch definition before the
-- application may start it.
M.APPLICATION_ACTION = "bee.harness.launch"
M.MAX_ANSWER_BYTES = 16384
local function fields(value: unknown, allowed: {string}): string?
    return bounds.fields(value, allowed)
end
function M.decode_request(value: unknown): (Request?, string?)
    local object = bounds.object(value)
    if not object then return nil, "request must be an object" end
    local unknown = fields(object, {"definition_ref", "brief", "idempotency_key", "workspace_id", "saved_profile_id", "saved_profile_revision", "workdir", "thread", "placement"})
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
    return {definition_ref = definition_ref, brief = brief, idempotency_key = idempotency_key, workspace_id = workspace_id,
        saved_profile_id = saved_profile_id, saved_profile_revision = saved_profile_revision, workdir = workdir, thread = thread, placement = placement}, nil
end
-- A run the caller started: its thread and attempt.
function M.decode_run(value: unknown, allowed: {string}): (Run?, string?)
    local object = bounds.object(value)
    if not object then return nil, "request must be an object" end
    local unknown = fields(object, allowed)
    if unknown then return nil, unknown end
    local thread_id, attempt_id = bounds.id(object.thread_id), bounds.id(object.attempt_id)
    if not thread_id then return nil, "thread_id is not an identifier" end
    if not attempt_id then return nil, "attempt_id is not an identifier" end
    return {thread_id = thread_id, attempt_id = attempt_id}, nil
end
-- Whether the caller's own launch policy admits starting this definition at
-- all. A definition absent from the host-owned list is refused by name. The
-- launch runs in the caller's own workspace unless the caller names another
-- its own scope may launch into.
function M.permitted(policy: {[string]: unknown}, definition_ref: string): (boolean, string?)
    local object = bounds.object(policy)
    if not object then return false, "launch policy is unavailable" end
    local rows = object.agent_launch
    if type(rows) ~= "table" then return false, nil end
    for _, raw in ipairs(rows) do
        if bounds.id(raw) == definition_ref then return true, nil end
    end
    return false, nil
end
-- The child's durable request identity: the caller's own action and the
-- retry key, so the same call replays the same child action and attempt and a
-- different brief under the same key conflicts instead of starting twice.
function M.request_id(action_id: string, idempotency_key: string): (string?, string?)
    local digest, hash_error = hash.sha256(action_id .. "\n" .. idempotency_key)
    if hash_error or not digest then return nil, "request identity failed" end
    return "agent-launch:" .. digest:sub(1, 32), nil
end
return M
