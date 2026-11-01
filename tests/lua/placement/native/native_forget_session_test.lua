-- MIT. Forgetting a removed session removes the files placement materialized
-- for it and their records, and nothing else in its home.
local test = require("test")
local store = require("store")
local homes = require("homes")
local hash = require("hash")
local native_fixture = require("native_fixture")

local function materialize(session_ref: string, relative: string, content: string): string
    local key = assert(homes.session_key(native_fixture.OWNER, session_ref))
    local home = assert(homes.os_path(assert(homes.ensure_session(key)) .. "/home"))
    native_fixture.shell("mkdir -p \"$(dirname '" .. home .. "/" .. relative .. "')\" && printf '" .. content .. "' > '" .. home .. "/" .. relative .. "'")
    local db = assert(store.open())
    local bound = store.bind_session_file(db, native_fixture.OWNER, session_ref, relative, assert(hash.sha256(content)))
    db:release()
    if bound then error(bound) end
    return home
end
local function recorded(session_ref: string): integer
    local db = assert(store.open())
    local rows = assert(db:query("SELECT COUNT(*) AS count FROM bee_placement_session_files WHERE owner_id = ? AND session_ref = ?", {native_fixture.OWNER, session_ref}))
    db:release()
    return math.floor(tonumber(rows[1].count) or -1)
end
local function present(home: string, relative: string): boolean
    return native_fixture.shell("test -e '" .. home .. "/" .. relative .. "' && printf yes || true") == "yes"
end

local function forget_tests()
    test.describe("Native placement forget_session", function()
        test.it("removes the materialized session files with their records and keeps the agent's own files", function()
            local session_ref = native_fixture.fresh("removed-session")
            local other_ref = native_fixture.fresh("kept-session")
            local home = materialize(session_ref, ".codex/config.toml", "model = fixture")
            native_fixture.shell("printf transcript > '" .. home .. "/.codex/history.jsonl'")
            local other_home = materialize(other_ref, ".codex/config.toml", "model = other")
            local forgotten = native_fixture.value(native_fixture.call(native_fixture.OWNER, "forget_session", {session = session_ref, thread_id = "thread-forget", owner_id = native_fixture.OWNER}))
            test.eq(forgotten.files, 1)
            test.eq(recorded(session_ref), 0)
            test.is_false(present(home, ".codex/config.toml"))
            test.is_true(present(home, ".codex/history.jsonl"))
            test.eq(recorded(other_ref), 1)
            test.is_true(present(other_home, ".codex/config.toml"))
            local again = native_fixture.value(native_fixture.call(native_fixture.OWNER, "forget_session", {session = session_ref, thread_id = "thread-forget", owner_id = native_fixture.OWNER}))
            test.eq(again.files, 0)
        end)
        test.it("answers only the session's owner", function()
            local session_ref = native_fixture.fresh("owned-session")
            materialize(session_ref, ".codex/config.toml", "model = owned")
            local refused = native_fixture.call("bee.test.intruder", "forget_session", {session = session_ref, thread_id = "thread-forget", owner_id = native_fixture.OWNER})
            test.is_false(refused.ok)
            test.eq(refused.error and refused.error.code, "FORBIDDEN")
            test.eq(recorded(session_ref), 1)
        end)
        test.it("refuses while an unfinished attempt holds the session home", function()
            local session_ref = native_fixture.fresh("held-session")
            materialize(session_ref, ".codex/config.toml", "model = held")
            local request = native_fixture.retained_launch(native_fixture.OWNER, session_ref, "held")
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            local refused = native_fixture.call(native_fixture.OWNER, "forget_session", {session = session_ref, thread_id = "thread-forget", owner_id = native_fixture.OWNER})
            test.is_false(refused.ok)
            test.eq(refused.error and refused.error.code, "CONFLICT")
            test.eq(recorded(session_ref), 1)
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "stop", {attempt_id = request.attempt_id}))
        end)
    end)
end

return {forget = native_fixture.suite(forget_tests)}
