-- MIT. Real public function dispatch, explicit principals, and a durable second boot.
local funcs = require("funcs")
local security = require("security")
local logger = require("logger")
local sql = require("sql")
type Object = {[string]: unknown}
local function principal(actor: string, write: boolean): funcs.Executor
    local call_policy = assert(security.policy("bee.sync_probe:call_policy"))
    local read_policy = assert(security.policy("bee.sync_probe:read_policy"))
    local policies = {call_policy, read_policy}
    if write then policies[#policies + 1] = assert(security.policy("bee.sync_probe:write_policy")) end
    return funcs.new():with_actor(security.new_actor(actor)):with_scope(security.new_scope(policies))
end
local function call(client: funcs.Executor, method: string, request: unknown): Object
    local result, err = client:call("bee.node.binding:" .. method, request)
    assert(not err, method .. ": " .. tostring(err))
    assert(type(result) == "table", "node returned malformed reply")
    return result :: Object
end
local function value(result: Object): Object
    assert(result.ok == true, tostring(result.code) .. ": " .. tostring(result.message))
    assert(type(result.value) == "table", "node returned no value")
    return result.value :: Object
end
local function main()
    local writer = principal("node-metadata-user", true)
    local reader = principal("node-metadata-reader", false)
    local description = value(call(writer, "describe", {}))
    local request = {expected_revision = 0, idempotency_key = "initial-description",
        metadata = {display_name = "Build worker", description = "Private CI host", labels = {role = "build", region = "local"}}}
    if description.revision == 0 then
        local denied = call(reader, "update_metadata", request)
        assert(denied.ok == false and denied.code == "DENIED", "reader changed metadata")
        local first = call(writer, "update_metadata", request)
        assert(value(first).revision == 1, "first update revision")
        local replay = call(writer, "update_metadata", request)
        assert(replay.ok == true and replay.replayed == true, "retry did not replay")
        local conflict = call(writer, "update_metadata", {expected_revision = 0, idempotency_key = "stale",
            metadata = {display_name = "Stale"}})
        assert(conflict.ok == false and conflict.code == "CONFLICT", "stale update was accepted")
        local changed_key = call(writer, "update_metadata", {expected_revision = 1, idempotency_key = "initial-description",
            metadata = {display_name = "Conflicting retry"}})
        assert(changed_key.ok == false and changed_key.code == "CONFLICT", "retry key was reused for other content")
        local bad = call(writer, "update_metadata", {expected_revision = 1, idempotency_key = "bad",
            metadata = {display_name = "Bad", permissions = {"admin"}}})
        assert(bad.ok == false and bad.code == "INVALID", "metadata accepted authority fields")
        local snapshot = value(call(reader, "snapshot", {}))
        assert(snapshot.cursor == 1, "rejections or replay appended events")
        local events = value(call(reader, "read_after", {cursor = 0, limit = 64}))
        assert(events.next_cursor == 1, "catch-up cursor")
        logger:info("NODE_SYNC_FIRST_BOOT_PASS")
    else
        assert(description.revision == 1, "restart changed revision")
        local metadata = description.metadata :: Object
        assert(metadata.display_name == "Build worker", "restart lost metadata")
        local replay = call(writer, "update_metadata", request)
        assert(replay.ok == true and replay.replayed == true, "restart lost retry receipt")
        local updated = call(writer, "update_metadata", {expected_revision = 1, idempotency_key = "after-restart",
            metadata = {display_name = "Build worker 2", labels = {role = "build"}}})
        assert(value(updated).revision == 2, "post-restart update failed")
        logger:info("NODE_SYNC_SECOND_BOOT_PASS")
    end
    local defaults = value(call(reader, "get_appearance", {}))
    local appearance_writer = funcs.new():with_actor(security.new_actor("appearance-user")):
        with_scope(security.new_scope({assert(security.policy("bee.sync_probe:call_policy")),
            assert(security.policy("bee.sync_probe:read_policy")), assert(security.policy("bee.sync_probe:appearance_policy"))}))
    local appearance_request = {expected_revision = 0, idempotency_key = "initial-description",
        preferences = {theme = "classic", background = "solid", taskbar = "labels"}}
    local denied_appearance = call(writer, "update_appearance", appearance_request)
    assert(denied_appearance.ok == false and denied_appearance.code == "DENIED", "metadata permission changed node appearance")
    if defaults.revision == 0 then
        assert(value(call(appearance_writer, "update_appearance", appearance_request)).revision == 1)
        local conflict = call(appearance_writer, "update_appearance", {expected_revision = 0, idempotency_key = "stale-appearance",
            preferences = {theme = "dos", background = "solid", taskbar = "labels"}})
        assert(conflict.ok == false and conflict.code == "CONFLICT", "stale appearance write accepted")
    else
        assert(defaults.revision == 1, "restart changed appearance revision")
        local preferences = defaults.preferences :: Object
        assert(preferences.theme == "classic" and preferences.background == "solid", "restart lost node defaults")
    end
    local replay_appearance = call(appearance_writer, "update_appearance", appearance_request)
    assert(replay_appearance.ok == true and replay_appearance.replayed == true, "appearance retry did not replay")
    local malformed = call(appearance_writer, "update_appearance", {expected_revision = 1, idempotency_key = "invalid-appearance",
        preferences = {theme = "unknown", background = "solid", taskbar = "labels"}})
    assert(malformed.ok == false and malformed.code == "INVALID", "unknown theme accepted")
    -- The public caller has no direct store access even though methods can open it.
    local restricted = funcs.new():with_actor(security.new_actor("node-metadata-user")):
        with_scope(security.new_scope({assert(security.policy("bee.sync_probe:call_policy"))}))
    local access, access_error = restricted:call("bee.sync_probe:direct_db", {})
    assert(not access_error and access == false, "public principal opened the owner's database")
    local unavailable = call(restricted, "describe", {})
    assert(unavailable.ok == false and unavailable.code == "DENIED", "unprivileged principal read metadata")
end
return {main = main}
