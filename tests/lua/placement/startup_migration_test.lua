-- SPDX-License-Identifier: MIT
local test = require("test")
local database = require("database")
local ledger = require("ledger")
local migrations = require("migrations")
local request = require("request")
local store = require("store")
local json = require("json")
local bounds = require("bounds")
local function run()
    test.describe("Placement supervised-startup migration", function()
        test.it("upgrades a revision-ten store without changing its prior ledger or admitted identity", function()
            local old: {ledger.Migration} = {}
            for _, migration in ipairs(migrations.all()) do if migration.id < 11 then old[#old + 1] = migration end end
            local resource = "bee.placement.native:startup_legacy_db"
            local db = assert(database.open({resource = resource, ledger = store.LEDGER, migrations = old}))
            local admitted = assert(request.decode({idempotency_key = "legacy", owner_id = "bee.test.legacy", owner_incarnation = 1,
                action_id = "legacy", attempt_id = "legacy", binding_ref = "bee.placement.native:fixture_agent_binding",
                policy_ref = "bee.placement.native:test_launch_policy_without_provider", profile_id = "batch",
                binding_digest = string.rep("a", 64), profile_digest = string.rep("a", 64),
                launch = {executable = "sh", argv = {"true"}, environment = {}, working_directory_ref = "project", readiness = "none"},
                resources = {{name = "project", grant_ref = "grant-1", root_ref = "bee.placement.native:project_fixture", subpath = "", access = "write", purpose = "project"}},
                environment = {}, required_cleanup = "direct_process", required_exit_observation = "eof_gated"}))
            admitted.delivery = {arguments = {}, files = {}}
            local digest = assert(request.digest(admitted))
            local legacy = assert(bounds.object(assert(json.decode(assert(json.encode(admitted))))))
            assert(bounds.object(legacy.timeouts)).start_ms = 1
            assert(store.intend(db, admitted, digest, assert(json.encode(legacy)), {capability = "direct_process", exit_observation = "eof_gated"}, nil, {kind = "docker"}).ok)
            assert(store.transition(db, "legacy", {execution = "uncertain", evidence = {kind = "child.start_failed", detail = "daemon refused containers/create"}}).ok)
            local legacy_exited: {[string]: unknown} = {}
            for key, value in pairs(legacy) do legacy_exited[key] = value end
            legacy_exited.attempt_id = "legacy-exited"
            legacy_exited.action_id = "legacy-exited"
            legacy_exited.idempotency_key = "legacy-exited"
            local legacy_request = assert(request.decode({idempotency_key = "legacy-exited", owner_id = admitted.owner_id, owner_incarnation = 1,
                action_id = "legacy-exited", attempt_id = "legacy-exited", binding_ref = admitted.binding_ref, policy_ref = admitted.policy_ref,
                profile_id = admitted.profile_id, binding_digest = admitted.binding_digest, profile_digest = admitted.profile_digest,
                launch = admitted.launch, resources = admitted.resources, environment = {}, required_cleanup = "direct_process", required_exit_observation = "eof_gated"}))
            assert(store.intend(db, legacy_request, digest, assert(json.encode(legacy_exited)), {capability = "direct_process", exit_observation = "eof_gated"}, nil, {kind = "docker"}).ok)
            assert(store.transition(db, "legacy-exited", {execution = "exited", fields = {exit_source = "runner"},
                evidence = {kind = "child.start_failed", detail = "legacy start refusal without an exit"}}).ok)
            local genuine = assert(request.decode({idempotency_key = "genuine-exit", owner_id = admitted.owner_id, owner_incarnation = 1,
                action_id = "genuine-exit", attempt_id = "genuine-exit", binding_ref = admitted.binding_ref, policy_ref = admitted.policy_ref,
                profile_id = admitted.profile_id, binding_digest = admitted.binding_digest, profile_digest = admitted.profile_digest,
                launch = admitted.launch, resources = admitted.resources, environment = {}, required_cleanup = "direct_process", required_exit_observation = "eof_gated"}))
            genuine.delivery = {arguments = {}, files = {}}
            assert(store.intend(db, genuine, digest, assert(json.encode(genuine)), {capability = "direct_process", exit_observation = "eof_gated"}, nil, {kind = "docker"}).ok)
            assert(store.transition(db, "genuine-exit", {execution = "uncertain", evidence = {kind = "child.start_failed", detail = "initial daemon refusal"}}).ok)
            assert(store.transition(db, "genuine-exit", {execution = "exited", fields = {exit_source = "reconcile"},
                evidence = {kind = "docker.exited", detail = "daemon later observed exact stopped container with unknown exit code"}}).ok)
            local before = assert(ledger.rows(db, store.LEDGER))
            db:release()
            db = assert(database.open({resource = resource, ledger = store.LEDGER, migrations = migrations.all()}))
            local after = assert(ledger.rows(db, store.LEDGER))
            test.eq(#after, #before + 2)
            test.eq(after[11].id, 11)
            test.eq(after[11].name, "supervised_startup")
            test.eq(after[12].id, 12)
            test.eq(after[12].name, "hive_component_references")
            for index, row in ipairs(before) do test.eq(after[index].checksum, row.checksum); test.eq(after[index].id, row.id) end
            local row = assert(store.row(db, "legacy"))
            test.eq(row.request_digest, digest)
            local persisted = assert(bounds.object(assert(json.decode(row.request_json))))
            test.is_nil(assert(bounds.object(persisted.timeouts)).start_ms)
            test.not_nil(store.request(row))
            local failed = assert(store.attempt(db, "legacy"))
            test.eq(failed.execution_state, "start_failed")
            test.eq(failed.start_failure, "daemon refused containers/create")
            test.is_nil(failed.exit)
            test.is_nil(failed.exit_source)
            local repaired = assert(store.attempt(db, "legacy-exited"))
            test.eq(repaired.execution_state, "start_failed")
            test.eq(repaired.start_failure, "legacy start refusal without an exit")
            test.is_nil(repaired.exit)
            test.is_nil(repaired.exit_source)
            local observed = assert(store.attempt(db, "genuine-exit"))
            test.eq(observed.execution_state, "exited")
            test.eq(observed.exit_source, "reconcile")
            assert(ledger.apply(db, store.LEDGER, migrations.all()))
            test.eq(#assert(ledger.rows(db, store.LEDGER)), #after)
            db:release()
        end)
    end)
end
return {run = test.run_cases(run)}
