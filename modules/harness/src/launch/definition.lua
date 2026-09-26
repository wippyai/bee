-- MIT. Launch definitions: registry entries of type bee.launch_definition
-- that name a driver profile, a launch policy, defaults and the overrides a
-- caller may make. Decoded exactly, measured by digest, never executed here.
local hash = require("hash")
local registry = require("registry")
local bounds = require("bounds")
local canonical = require("canonical")
local M = {}
M.SCHEMA = "bee.launch-definition@1"
M.TYPE = "bee.launch_definition"
M.MODES = {"window", "session", "batch"}
M.OVERRIDES = {"mode", "workdir", "thread", "brief", "placement"}
type WorkdirKind = "caller_workspace" | "declared_resource" | "required"
type ThreadKind = "new" | "caller" | "named"
type WorkdirPolicy = {kind: WorkdirKind, resource_ref: string?}
type ThreadPolicy = {kind: ThreadKind, thread_ref: string?}
type Definition = {
    ref: string,
    digest: string,
    launch_id: string,
    title: string,
    command_names: {string},
    binding_ref: string,
    profile_id: string,
    policy_ref: string,
    agent_ref: string?,
    default_mode: string,
    allowed_overrides: {string},
    workdir_policy: WorkdirPolicy,
    thread_policy: ThreadPolicy,
    session_resource: string?,
    credentials: {string},
    presentation: {start_menu: boolean, fullscreen: boolean, reuse: string},
    -- The host explicitly admits this definition's gateway tools even where
    -- they exceed the launching parent's policy; without it a child launch is
    -- refused when its tools are not a subset of the parent's.
    allow_wider_tools: boolean,
    -- The host records that this definition's CLI runs without a usable
    -- workdir confinement: no sandbox or permission flag Bee can select
    -- restricts it. An orchestrator launches it only through the explicit
    -- agent_launch_unconfined allow-list on its own launch policy.
    unconfined: boolean,
}
local function decode_workdir(value: unknown): (WorkdirPolicy?, string?)
    local object = bounds.object(value == nil and {kind = "caller_workspace"} or value)
    if not object then return nil, "workdir_policy must be an object" end
    local unknown_field = bounds.fields(object, {"kind", "resource_ref"})
    if unknown_field then return nil, "workdir_policy: " .. unknown_field end
    local kind = bounds.member(object.kind, {"caller_workspace", "declared_resource", "required"})
    if not kind then return nil, "workdir_policy.kind is not caller_workspace, declared_resource or required" end
    local resource_ref: string? = nil
    if object.resource_ref ~= nil then
        resource_ref = bounds.id(object.resource_ref)
        if not resource_ref then return nil, "workdir_policy.resource_ref is not an identifier" end
    end
    if kind == "declared_resource" and not resource_ref then return nil, "workdir_policy.declared_resource names a resource_ref" end
    local workdir_kind = kind :: WorkdirKind
    return {kind = workdir_kind, resource_ref = resource_ref}, nil
end
local function decode_thread(value: unknown): (ThreadPolicy?, string?)
    local object = bounds.object(value == nil and {kind = "new"} or value)
    if not object then return nil, "thread_policy must be an object" end
    local unknown_field = bounds.fields(object, {"kind", "thread_ref"})
    if unknown_field then return nil, "thread_policy: " .. unknown_field end
    local kind = bounds.member(object.kind, {"new", "caller", "named"})
    if not kind then return nil, "thread_policy.kind is not new, caller or named" end
    local thread_ref: string? = nil
    if object.thread_ref ~= nil then
        thread_ref = bounds.id(object.thread_ref)
        if not thread_ref then return nil, "thread_policy.thread_ref is not an identifier" end
    end
    if kind == "named" and not thread_ref then return nil, "thread_policy.named names a thread_ref" end
    local thread_kind = kind :: ThreadKind
    return {kind = thread_kind, thread_ref = thread_ref}, nil
end
function M.decode(ref: string, entry: {[string]: unknown}): (Definition?, string?)
    local meta = bounds.object(entry.meta) or {}
    if meta.type ~= M.TYPE then return nil, ref .. " is not a launch definition" end
    local data = bounds.object(entry.data)
    if not data then return nil, ref .. " has no data" end
    local unknown_field = bounds.fields(data, {"schema_revision", "launch_id", "title", "command_names", "binding_ref", "profile_id", "policy_ref", "agent_ref", "default_mode",
        "allowed_overrides", "workdir_policy", "thread_policy", "session_resource", "credentials", "presentation",
        "allow_wider_tools", "unconfined"})
    if unknown_field then return nil, ref .. ": " .. unknown_field end
    if data.schema_revision ~= M.SCHEMA then return nil, ref .. ": schema_revision must be " .. M.SCHEMA end
    local launch_id, binding_ref, profile_id, policy_ref = bounds.id(data.launch_id), bounds.id(data.binding_ref), bounds.id(data.profile_id), bounds.id(data.policy_ref)
    if not launch_id then return nil, ref .. ": launch_id is not an identifier" end
    if not binding_ref then return nil, ref .. ": binding_ref is not an identifier" end
    if not profile_id then return nil, ref .. ": profile_id is not an identifier" end
    if not policy_ref then return nil, ref .. ": policy_ref is not an identifier" end
    local title = bounds.text(data.title, 256)
    if not title or title == "" then return nil, ref .. ": title must be nonempty text" end
    local agent_ref: string? = nil
    if data.agent_ref ~= nil then
        agent_ref = bounds.id(data.agent_ref)
        if not agent_ref then return nil, ref .. ": agent_ref is not an identifier" end
    end
    local commands, commands_error = bounds.ids(data.command_names == nil and {} or data.command_names, true)
    if not commands then return nil, ref .. ": command_names: " .. tostring(commands_error) end
    local mode = bounds.member(data.default_mode, M.MODES)
    if not mode then return nil, ref .. ": default_mode must be window, session or batch" end
    local overrides, overrides_error = bounds.ids(data.allowed_overrides == nil and {} or data.allowed_overrides, true)
    if not overrides then return nil, ref .. ": allowed_overrides: " .. tostring(overrides_error) end
    for _, override in ipairs(overrides) do
        if not bounds.member(override, M.OVERRIDES) then return nil, ref .. ": allowed_overrides names " .. override .. ", which is not an override" end
    end
    local workdir, workdir_error = decode_workdir(data.workdir_policy)
    if not workdir then return nil, ref .. ": " .. tostring(workdir_error) end
    local thread, thread_error = decode_thread(data.thread_policy)
    if not thread then return nil, ref .. ": " .. tostring(thread_error) end
    local session_resource: string? = nil
    if data.session_resource ~= nil then
        session_resource = bounds.id(data.session_resource)
        if not session_resource then return nil, ref .. ": session_resource is not an identifier" end
    end
    local credentials, credentials_error = bounds.ids(data.credentials == nil and {} or data.credentials, true)
    if not credentials then return nil, ref .. ": credentials: " .. tostring(credentials_error) end
    local presentation = bounds.object(data.presentation == nil and {} or data.presentation)
    if not presentation then return nil, ref .. ": presentation must be an object" end
    local presentation_field = bounds.fields(presentation, {"start_menu", "fullscreen", "reuse"})
    if presentation_field then return nil, ref .. ": presentation: " .. presentation_field end
    local reuse = bounds.member(presentation.reuse == nil and "never" or presentation.reuse, {"action", "never"})
    if not reuse then return nil, ref .. ": presentation.reuse must be action or never" end
    if data.allow_wider_tools ~= nil and type(data.allow_wider_tools) ~= "boolean" then
        return nil, ref .. ": allow_wider_tools must be a boolean"
    end
    if data.unconfined ~= nil and type(data.unconfined) ~= "boolean" then
        return nil, ref .. ": unconfined must be a boolean"
    end
    local encoded, encode_error = canonical.encode(data)
    if not encoded then return nil, ref .. ": " .. tostring(encode_error) end
    local digest, hash_error = hash.sha256(encoded)
    if hash_error or not digest then return nil, ref .. ": digest failed" end
    return {ref = ref, digest = digest, launch_id = launch_id, title = title, command_names = commands, binding_ref = binding_ref, profile_id = profile_id,
        policy_ref = policy_ref, agent_ref = agent_ref, default_mode = mode, allowed_overrides = overrides, workdir_policy = workdir, thread_policy = thread, session_resource = session_resource, credentials = credentials,
        presentation = {start_menu = presentation.start_menu == true, fullscreen = presentation.fullscreen == true, reuse = reuse},
        allow_wider_tools = data.allow_wider_tools == true, unconfined = data.unconfined == true}, nil
end
function M.load(ref: string): (Definition?, string?)
    local entry, err = registry.get(ref)
    if err or not entry then return nil, "launch definition " .. ref .. " is not in the registry" end
    return M.decode(ref, entry)
end
function M.allows(definition: Definition, override: string): boolean
    for _, allowed in ipairs(definition.allowed_overrides) do
        if allowed == override then return true end
    end
    return false
end
return M
