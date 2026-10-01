-- SPDX-License-Identifier: MIT
local test = require("test")
local bounds = require("bounds")
local migration = require("migration")
local protocol = require("protocol")
local sync = require("sync")
local uuid = require("uuid")
type Object = {[string]: unknown}
local function binding(ref: string): string?
    if ref == "bee:codex" then return "bee.driver.codex:binding" end
    return nil
end
local function value(result: sync.Result): Object
    if not result.ok then error(result.message or "Sync operation failed") end
    return bounds.object(result.value) or {}
end
local function define_tests()
    test.describe("Persisted v2 profile migration", function()
        test.it("moves provider fields, instructions, Docker and supervision without putting revisions in the profile", function()
            local converted = migration.convert({title = "Coding", definition_ref = "bee:codex", options = {model = "small", sandbox = "workspace-write"},
                config_profile = "work", instructions = "End with BEE-PROFILE-OK", mcp_tools = {"thread_read"},
                bee = {permission_answers = "ask"}, placement_profile_ref = "bee.placement.docker:coding",
                budget = {max_turns = 4, max_tokens = 100}, progress_quiet_ms = 1000}, binding)
            local profile, err = protocol.profile(converted)
            if not profile then error(err or "Conversion failed") end
            test.eq(profile.schema_revision, "bee.agent-profile@2")
            test.eq(profile.provider.model, "small")
            test.eq((profile.provider.options or {}).sandbox, "workspace-write")
            test.eq((profile.provider.options or {}).config_profile, "work")
            test.eq(profile.provider.system_prompt_append, "End with BEE-PROFILE-OK")
            test.eq(profile.bee.permission_answers, "ask")
            test.eq(profile.budgets and profile.budgets.turn and profile.budgets.turn.provider_steps, 4)
            test.eq(profile.supervision and profile.supervision.quiet_period_ms, 1000)
            test.is_nil(converted.revision)
        end)
        test.it("retains unmappable values and a repair draft while refusing launch decoding", function()
            for _, source in ipairs({
                {title = "Missing definition", definition_ref = "missing", mystery = {keep = "all of this"}},
                {title = "Conflict", definition_ref = "bee:codex", config_profile = "a", options = {config_profile = "b"}},
            }) do
                local diagnostic = migration.convert(source, binding)
                test.eq(diagnostic.schema_revision, migration.DIAGNOSTIC)
                test.eq(diagnostic.source, source)
                test.is_true(bounds.object(diagnostic.draft) ~= nil)
                test.is_nil(protocol.profile(diagnostic))
            end
        end)
        test.it("retains native placement when the former home cannot be established", function()
            local source = {title = "Native", definition_ref = "bee:codex", placement_profile_ref = "bee.placement:native"}
            local diagnostic = migration.convert(source, binding)
            test.eq(diagnostic.schema_revision, migration.DIAGNOSTIC)
            test.eq(diagnostic.source, source)
            local mapped = migration.convert(source, binding, nil, function(_: string, _: string?): migration.NativeHome? return "machine" end)
            local profile = assert(protocol.profile(mapped))
            local placement = profile.placement
            if not placement or placement.kind ~= "native" then error("Native placement is missing") end
            test.eq(placement.home, "machine")
        end)
        test.it("diagnoses conflicting legacy budget aliases instead of dropping a value", function()
            local source = {title = "Limits", definition_ref = "bee:codex", budget = {max_turns = 3, provider_steps = 8}}
            local diagnostic = migration.convert(source, binding)
            test.eq(diagnostic.schema_revision, migration.DIAGNOSTIC)
            test.eq(diagnostic.source, source)
        end)
        test.it("migrates once in the existing store, preserving CAS, tombstones, receipts and other owners", function()
            local id = uuid.v7()
            if not id then error("Fixture id unavailable") end
            local store, err = sync.open({resource = "bee.sync:sync_test_db", owner = "profiles-" .. id})
            if not store then error(err or "Store unavailable") end
            local function append(feed: string, key: string, source: unknown, tombstone: boolean): sync.Result
                return store:append({feed = feed, projection_key = key, event_id = key, idempotency_key = key,
                    event_type = "profile", expected_revision = 0, projection_value = source, tombstone = tombstone,
                    payload = {source = source}})
            end
            local source: Object = {title = "Saved", definition_ref = "bee:codex", options = {effort = "low"}}
            test.is_true(append("harness.profiles:test", "saved", source, false).ok)
            test.is_true(append("harness.profiles:test", "deleted", nil, true).ok)
            test.is_true(append("other:test", "unrelated", {unchanged = true}, false).ok)
            local before = value(store:snapshot("harness.profiles:test", 1))
            local foreign, foreign_error = sync.open({resource = "bee.sync:sync_test_db", owner = "foreign-" .. id})
            if not foreign then error(foreign_error or "Foreign store unavailable") end
            test.is_true(foreign:append({feed = "harness.profiles:test", projection_key = "saved", event_id = "saved", idempotency_key = "saved", event_type = "profile", expected_revision = 0, projection_value = source, payload = {}}).ok)
            local calls = 0
            local function transform(raw: unknown): (unknown?, string?)
                calls = calls + 1
                return migration.convert(raw, binding), nil
            end
            test.is_true(store:migrate("harness.profiles:", migration.ID, transform).ok)
            local stored = value(store:projection("harness.profiles:test", "saved"))
            test.eq(stored.revision, 1)
            test.eq(store:snapshot("harness.profiles:test", 1, before.next_key, before.cursor).code, "RESET_REQUIRED")
            test.eq((bounds.object(value(foreign:projection("harness.profiles:test", "saved")).value) or {}).title, "Saved")
            test.is_true(foreign:close())
            local profile = bounds.object(stored.value)
            test.eq(profile and profile.schema_revision, protocol.SCHEMA)
            test.is_true(value(store:projection("harness.profiles:test", "deleted")).tombstone)
            test.is_true(append("harness.profiles:test", "saved", source, false).replayed)
            test.is_true(store:migrate("harness.profiles:", migration.ID, transform).replayed)
            test.eq(calls, 1)
            test.is_true((bounds.object(value(store:projection("other:test", "unrelated")).value) or {}).unchanged)
            test.is_true(store:close())
        end)
        test.it("preserves oversized repair diagnostics and replaces them with one CAS", function()
            local id = assert(uuid.v7())
            local store = assert(sync.open({resource = "bee.sync:sync_test_db", owner = "large-" .. id}))
            local source = {title = "Repair", definition_ref = "missing:definition", instructions = string.rep("x", 8000)}
            test.is_true(store:append({feed = "harness.profiles:large", projection_key = "repair", event_id = "create", idempotency_key = "create", event_type = "profile", expected_revision = 0, projection_value = source, payload = {}}).ok)
            test.is_true(store:migrate("harness.profiles:", migration.ID, function(raw: unknown): (unknown?, string?) return migration.convert(raw, binding), nil end).ok)
            local stored = value(store:projection("harness.profiles:large", "repair"))
            local diagnostic = assert(bounds.object(stored.value))
            local retained = assert(bounds.object(diagnostic.source))
            test.eq(retained.instructions, source.instructions)
            test.eq(stored.revision, 1)
            local repaired = assert(protocol.profile({schema_revision = protocol.SCHEMA, name = "Fixed", definition_ref = "bee:codex", driver_binding_ref = "bee.driver.codex:binding", provider = {}, bee = {}}))
            test.is_true(store:append({feed = "harness.profiles:large", projection_key = "repair", event_id = "repair", idempotency_key = "repair", event_type = "profile", expected_revision = 1, projection_value = repaired, payload = {}}).ok)
            test.eq(value(store:projection("harness.profiles:large", "repair")).revision, 2)
            test.is_true(store:close())
        end)
        test.it("rolls back the complete migration and its ledger when a transform fails", function()
            local id = uuid.v7()
            if not id then error("Fixture id unavailable") end
            local store, err = sync.open({resource = "bee.sync:sync_test_db", owner = "rollback-" .. id})
            if not store then error(err or "Store unavailable") end
            for _, key in ipairs({"a", "b"}) do
                test.is_true(store:append({feed = "profiles:test", projection_key = key, event_id = key, idempotency_key = key,
                    event_type = "profile", payload = {}, projection_value = {old = true}, expected_revision = 0}).ok)
            end
            local calls = 0
            local result = store:migrate("profiles:", "v2", function(_: unknown): (unknown?, string?)
                calls = calls + 1
                if calls == 2 then return nil, "Unmappable storage" end
                return {changed = true}, nil
            end)
            test.is_false(result.ok)
            test.is_true((bounds.object(value(store:projection("profiles:test", "a")).value) or {}).old)
            test.is_true(store:migrate("profiles:", "v2", function(_: unknown): (unknown?, string?) return {changed = true}, nil end).ok)
            test.is_true(store:close())
        end)
    end)
end
return test.run_cases(define_tests)
