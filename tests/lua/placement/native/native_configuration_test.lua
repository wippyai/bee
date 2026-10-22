-- MIT. Native placement configuration regressions.
local test = require("test")
local bounds = require("bounds")
local principals = require("principals")
local time = require("time")
local registry = require("registry")
local service = require("service")
local configuration = require("configuration")
local configuration_protocol = require("configuration_protocol")
local preferences = require("preferences")
local hash = require("hash")
local json = require("json")
local toml = require("toml")
local store = require("store")
local homes = require("homes")
local quote = require("quote")
local native_fixture = require("native_fixture")
local trust = require("trust")
local descriptors = require("descriptors")
local resources = require("resources")
local grants = require("grants")
local authority = require("authority")

local function configuration_tests()
    test.describe("Native placement configuration", function()
        require("native_trust_cases").define()
        test.it("creates and replays an admitted empty provider configuration", function()
            local key = assert(homes.session_key(native_fixture.OWNER, native_fixture.fresh("empty-provider")))
            local path = assert(homes.ensure_session(key))
            local written, err, replay = homes.write_protected(path, ".grok/config.toml", "", {}, true)
            test.is_nil(err); test.not_nil(written); test.eq(replay, false)
            local os_path = assert(homes.os_path(assert(written)))
            test.eq(native_fixture.shell("wc -c < " .. os_path), "0\n")
            local reused, reuse_error, reused_flag = homes.write_protected(path, ".grok/config.toml", "", {}, true)
            test.eq(reused, written); test.is_nil(reuse_error); test.eq(reused_flag, true)
            local changed, changed_error = homes.write_protected(path, ".grok/config.toml", "changed", {}, true)
            test.is_nil(changed); test.eq(changed_error, "retained configuration differs from host-approved content")
        end)
        local measured = native_fixture.value(service.capabilities())
        local capability = tostring(measured.capability)
        local observation = tostring(measured.exit_observation)
        test.it("prepares the planner's default options without a configuration conflict", function()
            local policy = assert(registry.get(native_fixture.NO_PROVIDER_POLICY))
            local policy_data = assert(bounds.object(policy.data))
            local native = native_fixture.native_placement()
            local compiled = assert(preferences.apply(policy_data, {}, assert(descriptors.load("bee.drivers.claude.descriptor:cli")), native))
            local options = assert(preferences.decode_prepare_options(compiled.prepare_options))
            test.eq(options.permission_mode, "manual")
            local digest = assert(configuration_protocol.digest("bee.drivers.claude.binding:binding", {placement = native, option_values = options, context = "window", fixture = true}, "bee.drivers.claude.binding:configure"))
            local request = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            request.policy_ref = native_fixture.NO_PROVIDER_POLICY
            request.binding_ref = "bee.drivers.claude.binding:binding"
            request.configuration_context = "window"
            request.configuration_digest = digest
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            test.eq(prepared.execution_state, "intended")
        end)
        test.it("refuses a stale host configuration digest and retries only the matching plan", function()
            local provider = registry.get("bee.tests.placement.native:codex_test_provider")
            if not provider then error("provider entry") end
            local rendered = assert(configuration.projection(assert(configuration.decode("bee.tests.placement.native:codex_test_provider", provider))))
            local request = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            request.policy_ref = native_fixture.POLICY
            request.binding_ref = "bee.drivers.codex.binding:binding"
            request.configuration_digest = string.rep("0", 64)
            local refused = native_fixture.call(native_fixture.OWNER, "prepare", request)
            test.eq(refused.error and refused.error.code, "CONFLICT")
            test.is_true(tostring(refused.error and refused.error.message):find("inputs changed", 1, true) ~= nil)
            test.eq(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = request.attempt_id}).error and native_fixture.call(native_fixture.OWNER, "status", {attempt_id = request.attempt_id}).error.code, "NOT_FOUND")
            request.configuration_digest = native_fixture.provider_configuration_digest()
            -- A digest from another host selection is a plan conflict, even
            -- where the replacement policy has no provider of its own.
            request.policy_ref = native_fixture.NO_PROVIDER_POLICY
            request.binding_ref = "bee.drivers.claude.binding:binding"
            local unselected = native_fixture.call(native_fixture.OWNER, "prepare", request)
            test.eq(unselected.error and unselected.error.code, "CONFLICT")
            test.is_true(tostring(unselected.error and unselected.error.message):find("inputs changed", 1, true) ~= nil)
            request.policy_ref = "bee.tests.placement.native:codex_test_provider"
            local foreign = native_fixture.call(native_fixture.OWNER, "prepare", request)
            test.eq(foreign.error and foreign.error.code, "DENIED")
            test.is_true(tostring(foreign.error and foreign.error.message):find("not a host launch policy", 1, true) ~= nil)
            request.policy_ref = native_fixture.POLICY
            request.binding_ref = "bee.drivers.codex.binding:binding"
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            test.eq(prepared.execution_state, "intended")
            local db, open_error = store.open()
            if not db then error(open_error or "store") end
            local row, row_error = store.row(db, prepared.attempt_id)
            if not row then db:release(); error(row_error or "stored request") end
            local frozen, frozen_error = store.request(row)
            db:release()
            if not frozen then error(frozen_error or "frozen request") end
            test.eq(#(frozen.delivery and frozen.delivery.files or {}), 1)
            test.eq((frozen.delivery and frozen.delivery.files[1].digest), rendered.digest)
            -- A matching idempotency retry returns the existing intent and
            -- does not replace the owner-recorded driver delivery.
            test.eq(native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request)).attempt_id, prepared.attempt_id)
            local replay_db, replay_open_error = store.open()
            if not replay_db then error(replay_open_error or "store") end
            local replay_row, replay_row_error = store.row(replay_db, prepared.attempt_id)
            if not replay_row then replay_db:release(); error(replay_row_error or "replayed stored request") end
            local replayed, replay_error = store.request(replay_row)
            replay_db:release()
            if not replayed then error(replay_error or "replayed frozen request") end
            test.eq(replayed.delivery and replayed.delivery.files[1].digest, rendered.digest)
            test.eq(replayed.delivery and replayed.delivery.files[1].content, rendered.content)
            local started = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
            test.is_true(started.execution_state == "running" or started.execution_state == "exited")
            test.is_nil(started.start_failure)
            time.sleep("500ms")
            local recorded = native_fixture.kinds(prepared.attempt_id)
            test.is_true(native_fixture.has(recorded, "configuration.materialized"))
            local page = native_fixture.value(native_fixture.call(native_fixture.OWNER, "evidence", {attempt_id = prepared.attempt_id, limit = 64}))
            for _, item in ipairs(principals.objects(page.evidence)) do
                if item.kind == "configuration.materialized" then
                    test.is_true(tostring(item.detail):find("digest " .. rendered.digest, 1, true) ~= nil)
                    test.is_nil((tostring(item.detail):find("/home", 1, true)))
                end
            end
        end)
        test.it("rejects malformed persisted delivery before creating a home or starting a child", function()
            local request = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            request.policy_ref = native_fixture.POLICY
            request.binding_ref = "bee.drivers.codex.binding:binding"
            request.configuration_digest = native_fixture.provider_configuration_digest()
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            local db, open_error = store.open()
            if not db then error(open_error or "store") end
            local row, row_error = store.row(db, prepared.attempt_id)
            if not row then db:release(); error(row_error or "stored request") end
            local original = row.request_json
            local decoded = assert(bounds.object(assert(json.decode(original))))
            local delivery = assert(bounds.object(decoded.delivery))
            local file = (principals.objects(delivery.files))[1]
            local corruptions: {{[string]: unknown}} = {
                {arguments = {"bad\0argument"}, files = {}},
                {arguments = {}, files = {file, file}},
                {arguments = {}, files = {{revision = file.revision, path = "../escape", content = file.content, digest = file.digest, provider_ref = file.provider_ref}}},
                {arguments = {}, files = {{revision = file.revision, path = file.path, content = "changed", digest = file.digest, provider_ref = file.provider_ref}}},
                {arguments = {}, files = {}, unsupported = true},
            }
            local home_key = assert(homes.attempt_key(native_fixture.OWNER, prepared.attempt_id))
            for index, damaged in ipairs(corruptions) do
                decoded.delivery = damaged
                local encoded = assert(json.encode(decoded))
                local _, write_error = db:execute("UPDATE bee_placement_attempts SET request_json = ? WHERE attempt_id = ?", {encoded, prepared.attempt_id})
                if write_error then db:release(); error("corrupt fixture row: " .. tostring(write_error)) end
                local damaged_row = assert(store.row(db, prepared.attempt_id))
                local persisted, persisted_error = store.request(damaged_row)
                test.is_nil(persisted, "persisted delivery corruption " .. tostring(index) .. " was accepted")
                test.not_nil(persisted_error)
                local refused = native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id})
                test.eq(refused.error and refused.error.code, "STORAGE")
                test.is_false(homes.attempt_exists(home_key))
                test.eq(#native_fixture.kinds(prepared.attempt_id), 1)
            end
            local _, restore_error = db:execute("UPDATE bee_placement_attempts SET request_json = ? WHERE attempt_id = ?", {original, prepared.attempt_id})
            if restore_error then db:release(); error("restore fixture request: " .. tostring(restore_error)) end
            local restored_row = assert(store.row(db, prepared.attempt_id))
            local restored, restored_error = store.request(restored_row)
            db:release()
            if not restored then error(restored_error or "restored request") end
            test.eq(restored.delivery and restored.delivery.files[1].digest, file.digest)
        end)
        test.it("rejects a persisted delivery that overlaps retained login identity", function()
            local request = native_fixture.retained_launch(native_fixture.OWNER, native_fixture.fresh("persisted-login-overlap"), "overlap")
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            local db, open_error = store.open()
            if not db then error(open_error or "store") end
            local row, row_error = store.row(db, prepared.attempt_id)
            if not row then db:release(); error(row_error or "stored request") end
            local decoded = assert(bounds.object(assert(json.decode(row.request_json))))
            local delivery = assert(bounds.object(decoded.delivery))
            local file = (principals.objects(delivery.files))[1]
            file.path = ".bee-retained-login-ready.json"
            local encoded = assert(json.encode(decoded))
            local _, write_error = db:execute("UPDATE bee_placement_attempts SET request_json = ? WHERE attempt_id = ?", {encoded, prepared.attempt_id})
            db:release()
            if write_error then error("corrupt overlap fixture: " .. tostring(write_error)) end

            local started = native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id})
            test.is_true(started.ok)
            test.eq(native_fixture.attempt_of(started).execution_state, "start_failed")
            test.eq(native_fixture.attempt_of(started).start_failure, "configuration overlaps retained login identity")
            test.is_true(native_fixture.has(native_fixture.kinds(prepared.attempt_id), "configuration.refused"))
            local home_key = assert(homes.attempt_key(native_fixture.OWNER, prepared.attempt_id))
            test.is_false(homes.attempt_exists(home_key))
        end)
        test.it("refuses a missing configuration when the host policy selects a provider before recording intent", function()
            local request = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            request.policy_ref = native_fixture.POLICY
            request.binding_ref = "bee.drivers.codex.binding:binding"
            local refused = native_fixture.call(native_fixture.OWNER, "prepare", request)

            local db, open_error = store.open()
            if not db then error(open_error or "store") end
            if type(request.attempt_id) ~= "string" then error("invalid fixture request.attempt_id") end
            local attempt, read_error = store.attempt(db, request.attempt_id)
            db:release()
            if read_error then error(read_error) end
            test.is_nil(attempt)
            test.is_false(refused.ok)
            test.eq(refused.error and refused.error.code, "DENIED")
            test.is_true(tostring(refused.error and refused.error.message):find("selected configuration digest", 1, true) ~= nil)
        end)
        test.it("refuses caller forged delivery before recording intent", function()
            local request = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            request.delivery = {arguments = {}, files = {}}
            local refused = native_fixture.call(native_fixture.OWNER, "prepare", request)
            test.is_false(refused.ok)
            test.eq(refused.error and refused.error.code, "INVALID")
            test.is_true(tostring(refused.error and refused.error.message):find("delivery", 1, true) ~= nil)
            local absent = native_fixture.call(native_fixture.OWNER, "status", {attempt_id = request.attempt_id})
            test.eq(absent.error and absent.error.code, "NOT_FOUND")
        end)
        test.it("atomically admits one competing retained-session intent", function()
            local session_ref = native_fixture.fresh("contended-session")
            local first = native_fixture.retained_launch(native_fixture.OWNER, session_ref, "contender-one")
            local second = native_fixture.retained_launch(native_fixture.OWNER, session_ref, "contender-two")
            local a, a_error = native_fixture.caller(native_fixture.OWNER, principals.workspace(first)):async("bee.placement.native.binding:prepare", first)
            local b, b_error = native_fixture.caller(native_fixture.OWNER, principals.workspace(second)):async("bee.placement.native.binding:prepare", second)
            if a_error or not a or b_error or not b then error("start prepare race: " .. tostring(a_error or b_error)) end
            local first_reply, second_reply = principals.reply(native_fixture.await(a)), principals.reply(native_fixture.await(b))
            local replies = {first_reply, second_reply}
            local admitted = 0
            local refused = 0
            for _, reply in ipairs(replies) do
                if reply.ok then
                    admitted = admitted + 1
                else
                    test.eq(reply.error and reply.error.code, "CONFLICT")
                    refused = refused + 1
                end
            end
            test.eq(admitted, 1)
            test.eq(refused, 1)
            local rejected = first_reply.ok and second or first
            local db, open_error = store.open()
            if not db then error(open_error or "open store") end
            if type(rejected.attempt_id) ~= "string" then error("invalid fixture rejected.attempt_id") end
            local absent, read_error = store.attempt(db, rejected.attempt_id)
            db:release()
            if read_error then error(read_error) end
            test.is_nil(absent)

            -- An overlapping retry is not a second holder: both replies name
            -- the one recorded intent, with no additional receipt.
            local replay = native_fixture.retained_launch(native_fixture.OWNER, native_fixture.fresh("replay-session"), "same-request")
            local first_retry, first_retry_error = native_fixture.caller(native_fixture.OWNER, principals.workspace(replay)):async("bee.placement.native.binding:prepare", replay)
            local second_retry, second_retry_error = native_fixture.caller(native_fixture.OWNER, principals.workspace(replay)):async("bee.placement.native.binding:prepare", replay)
            if first_retry_error or not first_retry or second_retry_error or not second_retry then error("start replay race: " .. tostring(first_retry_error or second_retry_error)) end
            local replay_a, replay_b = native_fixture.attempt_of(principals.reply(native_fixture.await(first_retry))), native_fixture.attempt_of(principals.reply(native_fixture.await(second_retry)))
            test.eq(replay_a.attempt_id, replay.attempt_id)
            test.eq(replay_b.attempt_id, replay.attempt_id)
            if type(replay.attempt_id) ~= "string" then error("invalid fixture replay.attempt_id") end
            local receipt = native_fixture.kinds(replay.attempt_id)
            test.eq(#receipt, 1)
            test.eq(receipt[1], "intent.recorded")
        end)
        require("native_retained_configuration_cases").define()
        require("native_login_cases").define()
    end)
end


return {configuration = native_fixture.suite(configuration_tests)}
