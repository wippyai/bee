-- SPDX-License-Identifier: MIT
local test = require("test")
local time = require("time")
local json = require("json")
local sql = require("sql")
local store = require("store")
local request = require("request")
local types = require("types")
local service = require("service")
local runner_fixture = require("runner_fixture")
local RUNNER = "bee.placement.publication.test:materialization_runner_process"
local counter = 0
local function fresh(): string
    counter = counter + 1
    return "publication-" .. tostring(time.now():unix_nano()) .. "-" .. tostring(counter)
end
local function launch(session: string): types.LaunchRequest
    local id = fresh()
    local value: types.LaunchRequest = {idempotency_key = id, attempt_id = id,
        owner_id = "bee.test.publication", owner_incarnation = 1, action_id = id,
        binding_ref = "bee.driver.codex.binding:binding", policy_ref = "bee.test:policy", profile_id = "publication",
        binding_digest = string.rep("b", 64), profile_digest = string.rep("c", 64),
        launch = {executable = "sh", argv = {}, environment = {}, readiness = "none", home_ref = "session"},
        session_ref = session, resources = {{name = "session", grant_ref = "test-session", root_ref = "bee.placement.native.env:root",
            subpath = "", access = "write", purpose = "session"}}, environment = {}, environment_refs = {}, projections = {}, required_cleanup = "process_group",
        required_exit_observation = "independent", timeouts = {stop_grace_ms = 100, drain_ms = 1000, retain_ms = 1000},
        delivery = {arguments = {}, files = {{revision = "fixture@1", path = "config.json", content = "approved",
            digest = string.rep("d", 64), provider_ref = "bee.test:provider"}}}}
    return value
end
local function intend(db: sql.DB, value: types.LaunchRequest): store.Result
    local digest, digest_error = request.digest(value)
    if not digest then error(digest_error or "digest") end
    local encoded, encode_error = json.encode(value)
    if not encoded then error(tostring(encode_error)) end
    return store.intend(db, value, digest, encoded, {capability = "process_group", exit_observation = "independent"})
end
-- A hosted runner claims the attempt, as its own runner or recording
-- claim_as; a sweep inside the window leaves a present runner's claim.
local function claim(db: sql.DB, value: types.LaunchRequest, claim_as: string?): runner_fixture.Runner
    local intended = intend(db, value)
    if not intended.ok or not intended.attempt then error(intended.message or "intent") end
    local runner = runner_fixture.claim(RUNNER, value, 0, claim_as)
    test.is_true(service.sweep().ok)
    return runner
end
-- Evidence the materialization itself recorded; supervision sweeps add
-- reconcile evidence at their own schedule.
local function own_evidence(db: sql.DB, id: string): integer
    local page = store.evidence(db, id, 0, 256)
    if not page then error("evidence unavailable") end
    local count = 0
    for _, item in ipairs(page.evidence) do
        if not tostring(item.kind):find("^reconcile%.") then count = count + 1 end
    end
    return count
end
local function define_tests()
    test.describe("Retained configuration publication outcomes", function()
        test.it("reports unsynced publication as a startup failure and prevents successor admission", function()
            local db, open_error = store.open()
            if not db then error(open_error or "store") end
            local session = fresh()
            local value = launch(session)
            local runner = claim(db, value)
            local id = runner.attempt_id
            local outcome = runner_fixture.prepare(runner)
            runner_fixture.release(runner)
            test.is_nil(outcome.prepared)
            test.eq(outcome.error, "configuration published; durability requires inspection")
            test.eq(outcome.observed.publications, 1)
            local attempt = store.attempt(db, id)
            if not attempt then db:release(); error("attempt disappeared") end
            test.eq(attempt.execution_state, "start_failed")
            test.eq(attempt.start_failure, "configuration published; durability requires inspection")
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
                    local db, open_error = store.open()
                if not db then error(open_error or "store") end
                local value = launch(fresh())
                local runner = claim(db, value, foreign and "foreign-runner" or nil)
                local id = runner.attempt_id
                if not foreign then
                    local changed = store.transition(db, id, {execution = "uncertain", evidence = {kind = "test.retired", detail = "retired before publication"}})
                    if not changed.ok then db:release(); error(changed.message or "retire") end
                end
                local before = own_evidence(db, id)
                local outcome = runner_fixture.prepare(runner)
                runner_fixture.release(runner)
                test.is_nil(outcome.prepared)
                test.eq(outcome.error, "attempt no longer owns configuration materialization")
                test.eq(outcome.observed.publications, 0)
                test.eq(outcome.observed.creations, 0)
                test.eq(own_evidence(db, id), before)
                db:release()
            end
        end)
    end)
end
return test.run_cases(define_tests)
