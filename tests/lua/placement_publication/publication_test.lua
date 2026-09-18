-- SPDX-License-Identifier: MIT
local test = require("test")
local process = require("process")
local time = require("time")
local json = require("json")
local store = require("store")
local request = require("request")
local types = require("types")
local materialization = require("materialization")
local homes = require("homes")
local counter = 0
local function fresh(): string
    counter = counter + 1
    return "publication-" .. tostring(time.now():unix_nano()) .. "-" .. tostring(counter)
end
local function launch(session: string): types.LaunchRequest
    local id = fresh()
    local value: types.LaunchRequest = {idempotency_key = id, attempt_id = id,
        owner_id = "bee.test.publication", owner_incarnation = 1, action_id = id,
        binding_ref = "bee.driver.codex:binding", policy_ref = "bee.test:policy", profile_id = "publication",
        binding_digest = string.rep("b", 64), profile_digest = string.rep("c", 64),
        launch = {executable = "sh", argv = {}, environment = {}, readiness = "none", home_ref = "session"},
        session_ref = session, resources = {{name = "session", grant_ref = "test-session", root_ref = "bee.placement.native:root",
            subpath = "", access = "write", purpose = "session"}}, environment = {}, environment_refs = {}, projections = {}, required_cleanup = "process_group",
        required_exit_observation = "independent", timeouts = {start_ms = 1000, stop_grace_ms = 100, drain_ms = 1000, retain_ms = 1000},
        delivery = {arguments = {}, files = {{revision = "fixture@1", path = "config.json", content = "approved",
            digest = string.rep("d", 64), provider_ref = "bee.test:provider"}}}}
    return value
end
local function intend(db, value: types.LaunchRequest): store.Result
    local digest, digest_error = request.digest(value)
    if not digest then error(digest_error or "digest") end
    local encoded, encode_error = json.encode(value)
    if not encoded then error(tostring(encode_error)) end
    return store.intend(db, value, digest, encoded, {capability = "process_group", exit_observation = "independent"})
end
local function claim(db, value: types.LaunchRequest, runner: string): string
    local intended = intend(db, value)
    if not intended.ok or not intended.attempt then error(intended.message or "intent") end
    local id = intended.attempt.attempt_id
    local result = store.transition(db, id, {expected_execution = "intended", execution = "starting", fields = {runner_pid = runner},
        evidence = {kind = "test.claimed", detail = "materialization fixture"}})
    if not result.ok then error(result.message or "claim") end
    return id
end
local function define_tests()
    test.describe("Retained configuration publication outcomes", function()
        test.it("keeps a published but unsynced attempt uncertain and prevents successor admission", function()
            homes.reset()
            local db, open_error = store.open()
            if not db then error(open_error or "store") end
            local session = fresh()
            local value = launch(session)
            local id = claim(db, value, process.pid())
            local prepared, failure = materialization.prepare(db, value, id, 0)
            test.is_nil(prepared)
            test.eq(failure, "configuration published; durability requires inspection")
            test.eq(homes.publications, 1)
            local attempt = store.attempt(db, id)
            if not attempt then db:release(); error("attempt disappeared") end
            test.eq(attempt.execution_state, "uncertain")
            test.eq(attempt.cleanup_state, "pending")
            local blocked = intend(db, launch(session))
            test.is_false(blocked.ok)
            test.eq(blocked.code, "CONFLICT")
            local page = store.evidence(db, id, 0, 64)
            if not page then db:release(); error("evidence unavailable") end
            local found = false
            for _, item in ipairs(page.evidence) do
                if item.kind == "configuration.uncertain" then found = true end
                test.is_false(item.kind == "child.started")
            end
            test.is_true(found)
            db:release()
        end)
        test.it("rejects a stale runner before creating or publishing any configuration", function()
            for _, foreign in ipairs({true, false}) do
                homes.reset()
                local db, open_error = store.open()
                if not db then error(open_error or "store") end
                local value = launch(fresh())
                local id = claim(db, value, foreign and "foreign-runner" or process.pid())
                if not foreign then
                    local changed = store.transition(db, id, {execution = "uncertain", evidence = {kind = "test.retired", detail = "retired before publication"}})
                    if not changed.ok then db:release(); error(changed.message or "retire") end
                end
                local before = store.attempt(db, id)
                if not before then db:release(); error("attempt unavailable") end
                local prepared, failure = materialization.prepare(db, value, id, 0)
                test.is_nil(prepared)
                test.eq(failure, "attempt no longer owns configuration materialization")
                test.eq(homes.publications, 0)
                test.eq(homes.creations, 0)
                local after = store.attempt(db, id)
                if not after then db:release(); error("attempt unavailable") end
                test.eq(after.evidence_count, before.evidence_count)
                db:release()
            end
        end)
    end)
end
return test.run_cases(define_tests)
