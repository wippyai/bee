-- MIT. Two actual runtime boots prove durable profile projections and receipts.
local funcs = require("funcs")
local security = require("security")
local logger = require("logger")
local system = require("system")
local bounds = require("bounds")

type Object = {[string]: unknown}
local WORKSPACE = "saved-profile-restart-workspace"
local SAVED = "saved-profile"
local DELETED = "deleted-profile"

local function principal(actor: string, write: boolean): funcs.Executor
    local policies: {security.Policy} = {
        assert(security.policy("bee.saved_profiles_probe:call_policy")),
        assert(security.policy("bee.saved_profiles_probe:read_policy")),
    }
    if write then policies[#policies + 1] = assert(security.policy("bee.saved_profiles_probe:write_policy")) end
    return funcs.new():with_actor(security.new_actor(actor)):with_scope(security.new_scope(policies))
end

local function call(client: funcs.Executor, request: unknown): Object
    local raw, err = client:call("bee.harness.profiles:call", request)
    assert(not err, tostring(err))
    local reply = bounds.object(raw)
    assert(reply, "malformed profile reply")
    return reply
end

local function value(reply: Object): Object
    assert(reply.ok == true, tostring(reply.code) .. ": " .. tostring(reply.message))
    local result = bounds.object(reply.value)
    assert(result, "missing profile value")
    return result
end

local function profile(title: string): Object
    return {title = title, definition_ref = "bee:codex", options = {mode = "offline"}, mcp_tools = {}, instructions = "persisted profile"}
end

local function native_node(): string
    local node, err = system.node.id()
    assert(not err and node and node ~= "", tostring(err or "missing native node identity"))
    return node
end

local function main(phase: string?, expected_node: string?)
    local writer = principal("profile-writer", true)
    local reader = principal("profile-reader", false)
    local node = native_node()
    if phase == "first" then
        local saved = {operation = "put", workspace_id = WORKSPACE, profile_id = SAVED,
            expected_revision = 0, idempotency_key = "saved-put", profile = profile("Persisted")}
        assert(value(call(writer, saved)).revision == 1, "saved profile revision")
        local deleted = {operation = "put", workspace_id = WORKSPACE, profile_id = DELETED,
            expected_revision = 0, idempotency_key = "deleted-put", profile = profile("Retired")}
        assert(value(call(writer, deleted)).revision == 1, "deleted profile initial revision")
        local remove = {operation = "remove", workspace_id = WORKSPACE, profile_id = DELETED,
            expected_revision = 1, idempotency_key = "deleted-remove"}
        assert(value(call(writer, remove)).revision == 2, "deleted profile tombstone revision")
        logger:info("SAVED_PROFILE_FIRST_BOOT_PASS node=" .. node)
        return
    end
    assert(phase == "second", "unexpected probe phase")
    assert(expected_node == node, "native node identity changed across restart")
    local saved = value(call(reader, {operation = "get", workspace_id = WORKSPACE, profile_id = SAVED}))
    assert(saved.revision == 1 and saved.tombstone == false, "saved profile revision or state was lost")
    local saved_profile = bounds.object(saved.profile)
    assert(saved_profile and saved_profile.title == "Persisted", "saved profile value was lost")
    local tombstone = value(call(reader, {operation = "get", workspace_id = WORKSPACE, profile_id = DELETED}))
    assert(tombstone.revision == 2 and tombstone.tombstone == true and tombstone.profile == nil, "tombstone was lost across restart")
    local historical = {operation = "put", workspace_id = WORKSPACE, profile_id = DELETED,
        expected_revision = 0, idempotency_key = "deleted-put", profile = profile("Retired")}
    local replay = call(writer, historical)
    assert(replay.ok == true and replay.replayed == true, "historical receipt was not replayed")
    assert(value(call(reader, {operation = "get", workspace_id = WORKSPACE, profile_id = DELETED})).tombstone == true,
        "historical put replay resurrected the deleted profile")
    logger:info("SAVED_PROFILE_SECOND_BOOT_PASS node=" .. node .. " actor=profile-reader")
end

local function reported_main(phase: string?, expected_node: string?)
    local ok, problem = pcall(main, phase, expected_node)
    if not ok then
        logger:error("SAVED_PROFILE_PROBE_FAILED " .. tostring(problem))
        error(problem)
    end
end

return {main = reported_main}
