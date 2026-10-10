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
        for _, ending in ipairs({"attempt", "session", "retire", "delete", "revoke"}) do
            test.it("clears retained folder trust on " .. ending, function()
                local profile = native_fixture.fresh("trust-profile")
                local db = assert(store.open())
                local grant = assert(authority.save(db, native_fixture.OWNER, profile, profile, 1,
                    {driver_binding_ref = "bee.driver.codex.binding:binding", provider = {options = {folder_trust = "approved-workdir"}}},
                    "person", false, "2026-10-01T00:00:00.000Z"))
                db:release()
                local request = native_fixture.retained_launch(native_fixture.OWNER, profile, "trust")
                request.configuration_digest = nil
                request.policy_ref = "bee.placement.native:trust_launch_policy"
                request.preferences = {options = {folder_trust = "approved-workdir"}, authority_grant_id = grant.grant_id}
                local workdir = native_fixture.fresh("approved")
                native_fixture.shell(quote.line({"mkdir", "-p", assert(resources.directory(native_fixture.ROOT)) .. "/" .. workdir .. "/.git"}))
                local grants_list = principals.objects(request.resources)
                request.resources = grants_list
                for _, resource in ipairs(grants_list) do if resource.name == "project" then resource.subpath = workdir end end
                local launch = assert(bounds.object(request.launch))
                launch.provider_home = {provider = "codex", private = true, variable = "CODEX_HOME", directory = ".codex", files = {}}
                launch.argv = {"-c", [[grep -q 'trust_level.*trusted' "$CODEX_HOME/config.toml" || exit 7; ]] ..
                    ((ending == "attempt" or ending == "session") and "exit 0" or "exec sleep 30")}
                local data = assert(bounds.object(assert(registry.get("bee.placement.native:trust_launch_policy")).data))
                local effective = assert(preferences.apply(data, request.preferences, assert(descriptors.load("bee.driver.codex.descriptor:cli"))))
                request.configuration_digest = assert(configuration_protocol.digest("bee.driver.codex.binding:binding",
                    {fixture = true, provider_ref = "bee.placement.native:codex_test_provider", provider = assert(registry.get("bee.placement.native:codex_test_provider")),
                        option_values = effective.prepare_options}, "bee.driver.codex.binding:configure"))
                local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
                local started = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
                assert(not started.start_failure, started.start_failure)
                if ending == "revoke" or ending == "retire" or ending == "delete" then
                    test.eq(started.execution_state, "running")
                    db = assert(store.open())
                    local tx = assert(db:begin())
                    local err: string? = nil
                    if ending == "revoke" then err = grants.revoke(tx, grant, grant.revision, "person", 1790000000000)
                    else err = authority.retire(tx, native_fixture.OWNER, profile, profile, "person") end
                    if err then tx:rollback() else assert(tx:commit()) end
                    db:release()
                    test.is_nil(err)
                end
                test.is_true(native_fixture.wait_for(function()
                    local status = native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id}))
                    return assert(bounds.object(status.attempt)).execution_state == "exited"
                end, 8000))
                if ending == "attempt" or ending == "session" then
                    local status = native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id}))
                    test.eq(assert(bounds.object(assert(bounds.object(status.attempt)).exit)).code, 0)
                end
                native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = prepared.attempt_id}))
                local home = assert(homes.ensure_session(assert(homes.session_key(native_fixture.OWNER, profile))))
                local observed = native_fixture.shell(quote.line({"cat", assert(homes.os_path(home .. "/home/.codex/config.toml"))}))
                local root = assert(bounds.object(toml.decode(observed)))
                test.not_nil(root.model)
                for _, project in pairs(assert(bounds.object(root.projects))) do test.is_nil(assert(bounds.object(project)).trust_level) end
            end)
        end
        test.it("resolves symlinks and refuses trust outside the approved workdir and repository scope", function()
            local root = assert(resources.directory(native_fixture.ROOT)) .. "/" .. native_fixture.fresh("trust")
            native_fixture.shell(quote.line({"mkdir", "-p", root .. "/approved/.git", root .. "/outside", root .. "/repo/.git", root .. "/repo/child"}))
            native_fixture.shell(quote.line({"ln", "-s", root .. "/outside", root .. "/approved/escape"}))
            native_fixture.shell(quote.line({"ln", "-s", root .. "/approved", root .. "/alias"}))
            local executor = "bee.placement.native.env:placement_executor"
            test.eq(assert(trust.admit(root .. "/alias", {root .. "/approved"}, executor, true)), root .. "/approved")
            local escaped, escape_error = trust.admit(root .. "/approved/escape", {root .. "/approved"}, executor, true)
            test.is_nil(escaped); test.not_nil(escape_error)
            local widened, widening_error = trust.admit(root .. "/repo/child", {root .. "/repo/child"}, executor, true)
            test.is_nil(widened); test.not_nil(widening_error)
            test.eq(assert(trust.admit(root .. "/repo", {root .. "/repo"}, executor, true)), root .. "/repo")
            native_fixture.shell(quote.line({"touch", root .. "/approved/.mcp.json"}))
            local configured, config_error = trust.admit(root .. "/approved", {root .. "/approved"}, executor, true, {".mcp.json"})
            test.is_nil(configured); test.not_nil(config_error)
        end)
        test.it("renders trust using only declared isolated destinations", function()
            local workdir = "/approved/folder"
            for _, driver in ipairs({"claude", "codex"}) do
                local cli = assert(descriptors.load("bee.driver." .. driver .. ".descriptor:cli"))
                local field = assert(bounds.object(assert(bounds.object(cli.options.fields)).folder_trust))
                local mapping = assert(bounds.object(field.trust))
                local content = assert(trust.render(mapping, workdir, nil))
                local key = assert(homes.session_key(native_fixture.OWNER, native_fixture.fresh("trust-" .. driver)))
                local path = assert(homes.ensure_session(key))
                local written = assert(homes.publish_configuration(path, tostring(mapping.file), content, {}))
                local observed = native_fixture.shell(quote.line({"cat", assert(homes.os_path(written))}))
                test.eq(observed, content)
                if driver == "claude" then
                    test.eq(mapping.file, ".claude/.claude.json")
                    local project = assert(bounds.object(assert(bounds.object(assert(bounds.object(json.decode(content))).projects))[workdir]))
                    test.eq(project.hasTrustDialogAccepted, true)
                    local cleared = assert(bounds.object(json.decode(assert(trust.render(mapping, nil, content)))))
                    local untrusted = assert(bounds.object(assert(bounds.object(cleared.projects))[workdir]))
                    test.is_nil(untrusted.hasTrustDialogAccepted)
                    local empty = assert(bounds.object(json.decode(assert(trust.render(mapping, nil, nil)))))
                    test.eq(json.encode(empty.projects), "{}")
                else
                    local project = assert(bounds.object(assert(bounds.object(assert(bounds.object(toml.decode(content))).projects))[workdir]))
                    test.eq(project.trust_level, "trusted")
                end
            end
            local muse = assert(descriptors.load("bee.driver.muse.descriptor:cli"))
            local field = assert(bounds.object(assert(bounds.object(muse.options.fields)).folder_trust))
            test.eq(assert(bounds.object(field.trust)).flag, "--trust-workspace")
        end)

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
            local compiled = assert(preferences.apply(policy_data, {}, assert(descriptors.load("bee.driver.claude.descriptor:cli"))))
            local options = assert(preferences.decode_prepare_options(compiled.prepare_options))
            test.eq(options.permission_mode, "manual")
            local digest = assert(configuration_protocol.digest("bee.driver.claude.binding:binding", {option_values = options, context = "window", fixture = true}, "bee.driver.claude.binding:configure"))
            local request = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            request.policy_ref = native_fixture.NO_PROVIDER_POLICY
            request.binding_ref = "bee.driver.claude.binding:binding"
            request.configuration_context = "window"
            request.configuration_digest = digest
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            test.eq(prepared.execution_state, "intended")
        end)
        test.it("refuses a stale host configuration digest and retries only the matching plan", function()
            local provider = registry.get("bee.placement.native:codex_test_provider")
            if not provider then error("provider entry") end
            local rendered = assert(configuration.projection(assert(configuration.decode("bee.placement.native:codex_test_provider", provider))))
            local request = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            request.policy_ref = native_fixture.POLICY
            request.binding_ref = "bee.driver.codex.binding:binding"
            request.configuration_digest = string.rep("0", 64)
            local refused = native_fixture.call(native_fixture.OWNER, "prepare", request)
            test.eq(refused.error and refused.error.code, "CONFLICT")
            test.is_true(tostring(refused.error and refused.error.message):find("inputs changed", 1, true) ~= nil)
            test.eq(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = request.attempt_id}).error and native_fixture.call(native_fixture.OWNER, "status", {attempt_id = request.attempt_id}).error.code, "NOT_FOUND")
            request.configuration_digest = native_fixture.provider_configuration_digest()
            -- A digest from another host selection is a plan conflict, even
            -- where the replacement policy has no provider of its own.
            request.policy_ref = native_fixture.NO_PROVIDER_POLICY
            request.binding_ref = "bee.driver.claude.binding:binding"
            local unselected = native_fixture.call(native_fixture.OWNER, "prepare", request)
            test.eq(unselected.error and unselected.error.code, "CONFLICT")
            test.is_true(tostring(unselected.error and unselected.error.message):find("inputs changed", 1, true) ~= nil)
            request.policy_ref = "bee.placement.native:codex_test_provider"
            local foreign = native_fixture.call(native_fixture.OWNER, "prepare", request)
            test.eq(foreign.error and foreign.error.code, "DENIED")
            test.is_true(tostring(foreign.error and foreign.error.message):find("not a host launch policy", 1, true) ~= nil)
            request.policy_ref = native_fixture.POLICY
            request.binding_ref = "bee.driver.codex.binding:binding"
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
            request.binding_ref = "bee.driver.codex.binding:binding"
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
            request.binding_ref = "bee.driver.codex.binding:binding"
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
        test.it("retains structured private provider state across cleaned turn attempts", function()
            local session_ref = native_fixture.fresh("private-turn-session")
            for _, marker in ipairs({"first", "second"}) do
                local request = native_fixture.retained_launch(native_fixture.OWNER, session_ref, marker)
                local declared = assert(bounds.object(request.launch))
                declared.provider_home = {provider = "codex", private = true, variable = "CODEX_HOME", directory = ".codex", files = {{path = ".codex/history", kind = "state", optional = true, write_back = false}}}
                local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
                native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
                test.is_true(native_fixture.wait_for(function()
                    return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt).execution_state == "exited"
                end, 8000))
                native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = prepared.attempt_id}))
            end
            local key = assert(homes.session_key(native_fixture.OWNER, session_ref))
            local session_path = assert(homes.ensure_session(key))
            local home_path = assert(homes.os_path(session_path .. "/home"))
            test.eq(native_fixture.shell("cat " .. quote.posix(home_path .. "/marker")), "first\nsecond\n")
        end)
        test.it("retains a selected session home and publishes changed configuration", function()
            local session_ref = native_fixture.fresh("session")
            local first = native_fixture.retained_launch(native_fixture.OWNER, session_ref, "first")
            local first_configuration = native_fixture.provider_configuration().content
            local first_prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", first))
            -- The same admitted request is a replay, including while it is
            -- the retained home's only holder.
            test.eq(native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", first)).attempt_id, first_prepared.attempt_id)
            local competing = native_fixture.retained_launch(native_fixture.OWNER, session_ref, "competing")
            local blocked = native_fixture.call(native_fixture.OWNER, "prepare", competing)
            test.eq(blocked.error and blocked.error.code, "CONFLICT")
            test.is_true(tostring(blocked.error and blocked.error.message):find("retained session is still held", 1, true) ~= nil)
            test.is_nil(native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = first_prepared.attempt_id})).start_failure)
            test.is_true(native_fixture.wait_for(function()
                return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = first_prepared.attempt_id})).attempt).execution_state == "exited"
            end, 8000))
            -- Exit alone is not release: cleanup has to prove its scope.
            local exited_holder = native_fixture.call(native_fixture.OWNER, "prepare", native_fixture.retained_launch(native_fixture.OWNER, session_ref, "exited-holder"))
            test.eq(exited_holder.error and exited_holder.error.code, "CONFLICT")
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = first_prepared.attempt_id}))
            native_fixture.update_codex_provider("https://gateway.example.net/v2", "gpt-5-refresh")
            local second_configuration = native_fixture.provider_configuration().content
            local second = native_fixture.retained_launch(native_fixture.OWNER, session_ref, "second")
            local second_prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", second))
            test.is_nil(native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = second_prepared.attempt_id})).start_failure)
            test.is_true(native_fixture.wait_for(function()
                return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = second_prepared.attempt_id})).attempt).execution_state == "exited"
            end, 8000))
            -- Restore the fixture provider after the changed retained launch
            -- has started; later tests must see the original host selection.
            native_fixture.update_codex_provider("https://gateway.example.net/v1", "gpt-5")
            local key, key_error = homes.session_key(native_fixture.OWNER, session_ref)
            if not key then error(tostring(key_error)) end
            local session_path, session_error = homes.ensure_session(key)
            if not session_path then error(tostring(session_error)) end
            local home_path, home_error = homes.os_path(session_path .. "/home")
            if not home_path then error(tostring(home_error)) end
            test.eq(native_fixture.shell("cat " .. home_path .. "/marker"), "first\nsecond\n")
            local sum = native_fixture.shell("sha256sum " .. home_path .. "/.codex/config.toml"):match("^([0-9a-f]+)")
            test.eq(sum, assert(hash.sha256(second_configuration)))
            local second_evidence = native_fixture.kinds(second_prepared.attempt_id)
            test.is_true(native_fixture.has(second_evidence, "configuration.materialized"))
            local first_home, first_home_error = homes.attempt_key(native_fixture.OWNER, first_prepared.attempt_id)
            if not first_home then error(tostring(first_home_error)) end
            local second_home, second_home_error = homes.attempt_key(native_fixture.OWNER, second_prepared.attempt_id)
            if not second_home then error(tostring(second_home_error)) end
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = second_prepared.attempt_id}))
            test.is_false(homes.attempt_exists(first_home))
            test.is_false(homes.attempt_exists(second_home))
            test.eq(native_fixture.shell("cat " .. home_path .. "/marker"), "first\nsecond\n")

            local other_owner = "bee.test.session_other"
            local other = native_fixture.retained_launch(other_owner, session_ref, "other")
            local other_prepared = native_fixture.attempt_of(native_fixture.call(other_owner, "prepare", other))
            local other_started = native_fixture.attempt_of(native_fixture.call(other_owner, "start", {attempt_id = other_prepared.attempt_id}))
            test.is_true(other_started.execution_state == "running" or other_started.execution_state == "exited")
            test.is_nil(other_started.start_failure)
            test.is_true(native_fixture.wait_for(function()
                return (native_fixture.value(native_fixture.call(other_owner, "status", {attempt_id = other_prepared.attempt_id})).attempt).execution_state == "exited"
            end, 8000))
            local other_key, other_key_error = homes.session_key(other_owner, session_ref)
            if not other_key then error(tostring(other_key_error)) end
            test.neq(other_key, key)
            local other_path, other_path_error = homes.ensure_session(other_key)
            if not other_path then error(tostring(other_path_error)) end
            local other_home, other_home_error = homes.os_path(other_path .. "/home")
            if not other_home then error(tostring(other_home_error)) end
            test.eq(native_fixture.shell("cat " .. other_home .. "/marker"), "other\n")

            test.neq(second_configuration, first_configuration)
            test.eq(native_fixture.shell("cat " .. home_path .. "/.codex/config.toml"), second_configuration)

            local direct_key, direct_key_error = homes.session_key(native_fixture.OWNER, native_fixture.fresh("session"))
            if not direct_key then error(tostring(direct_key_error)) end
            local direct_path, direct_path_error = homes.ensure_session(direct_key)
            if not direct_path then error(tostring(direct_path_error)) end
            local created: {[string]: boolean} = {}
            local written, write_error = homes.write_protected(direct_path, ".codex/config.toml", "approved", created, true)
            if not written then error(tostring(write_error)) end
            local replayed, replay_error, replay = homes.write_protected(direct_path, ".codex/config.toml", "approved", {}, true)
            if not replayed then error(tostring(replay_error)) end
            test.eq(replay, true)
            local changed, changed_error = homes.write_protected(direct_path, ".codex/config.toml", "changed", {}, true)
            test.is_nil(changed)
            test.eq(changed_error, "retained configuration differs from host-approved content")
            local unowned_key, unowned_key_error = homes.session_key(native_fixture.OWNER, native_fixture.fresh("session"))
            if not unowned_key then error(tostring(unowned_key_error)) end
            local unowned_path, unowned_path_error = homes.ensure_session(unowned_key)
            if not unowned_path then error(tostring(unowned_path_error)) end
            local made_parent, made_parent_error = homes.write_protected(unowned_path, ".codex/other.toml", "approved", {}, true)
            if not made_parent then error(tostring(made_parent_error)) end
            local adopted, adopted_error = homes.write_protected(unowned_path, ".codex/config.toml", "approved", {}, true)
            test.is_nil(adopted)
            test.eq(adopted_error, "configuration parent already exists")
            local missing = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            missing.session_ref = native_fixture.fresh("session")
            local missing_launch = assert(bounds.object(missing.launch))
            missing_launch.home_ref = "session"
            local denied = native_fixture.call(native_fixture.OWNER, "prepare", missing)
            test.eq(denied.error and denied.error.code, "INVALID")
            test.eq(denied.error and denied.error.message, "launch.home_ref names no resource")
        end)
        test.it("creates nested configuration parents without adopting existing ancestors", function()
            local key, key_error = homes.session_key(native_fixture.OWNER, native_fixture.fresh("nested-config"))
            if not key then error(tostring(key_error)) end
            local path, path_error = homes.ensure_session(key)
            if not path then error(tostring(path_error)) end
            local created: {[string]: boolean} = {}
            local written, write_error = homes.write_protected(path, ".gemini/config/mcp_config.json", "approved", created, true)
            test.not_nil(written)
            test.is_nil(write_error)
            local sibling, sibling_error = homes.write_protected(path, ".gemini/GEMINI.md", "instructions", created, true)
            test.not_nil(sibling)
            test.is_nil(sibling_error)
            local replayed, replay_error, replay = homes.write_protected(path, ".gemini/config/mcp_config.json", "approved", {}, true)
            test.not_nil(replayed)
            test.is_nil(replay_error)
            test.is_true(replay == true)
            local refused, refused_error = homes.write_protected(path, ".gemini/new/config.json", "unapproved", {}, true)
            test.is_nil(refused)
            test.eq(refused_error, "configuration parent already exists")
        end)
        test.it("publishes bounded host configuration while preserving retained provider files", function()
            local key = assert(homes.session_key(native_fixture.OWNER, native_fixture.fresh("published-config")))
            local session = assert(homes.ensure_session(key))
            local home = assert(homes.os_path(session .. "/home"))
            local login = '{"access_token":"provider-refresh"}'
            local conversation = "conversation-state\nuser-owned\n"
            test.eq(native_fixture.shell("mkdir -p " .. quote.posix(home .. "/.codex/conversations")), "")
            test.eq(native_fixture.shell("printf %s " .. quote.posix(login) .. " > " .. quote.posix(home .. "/.codex/auth.json")), "")
            test.eq(native_fixture.shell("printf %s " .. quote.posix(conversation) .. " > " .. quote.posix(home .. "/.codex/conversations/thread.json")), "")

            local first = "[gateway]\nendpoint = \"https://gateway.example/v1\"\n"
            local published, publish_error, uncertain = homes.publish_configuration(session, ".codex/config.toml", first, {})
            if not published then error(tostring(publish_error)) end
            test.is_nil(publish_error)
            test.is_false(uncertain == true)
            test.eq(native_fixture.shell("cat " .. quote.posix(home .. "/.codex/config.toml")), first)
            test.eq(native_fixture.shell("sha256sum " .. quote.posix(home .. "/.codex/config.toml")):match("^([0-9a-f]+)"), assert(hash.sha256(first)))

            -- A host refresh replaces a regular file atomically, while the
            -- provider login and conversation remain harness-owned bytes.
            local replacement = "[gateway]\nendpoint = \"https://gateway.example/v2\"\nheader = \"x-bee: refreshed\"\n"
            local replaced, replace_error, replace_uncertain = homes.publish_configuration(session, ".codex/config.toml", replacement, {})
            if not replaced then error(tostring(replace_error)) end
            test.is_nil(replace_error)
            test.is_false(replace_uncertain == true)
            test.eq(native_fixture.shell("cat " .. quote.posix(home .. "/.codex/config.toml")), replacement)
            test.eq(native_fixture.shell("sha256sum " .. quote.posix(home .. "/.codex/config.toml")):match("^([0-9a-f]+)"), assert(hash.sha256(replacement)))
            test.eq(native_fixture.shell("cat " .. quote.posix(home .. "/.codex/auth.json")), login)
            test.eq(native_fixture.shell("cat " .. quote.posix(home .. "/.codex/conversations/thread.json")), conversation)

            -- A missing target is publishable when its already-existing
            -- parent is a regular directory under the selected home.
            local missing = "[limits]\nmax_retries = 3\n"
            local missing_path, missing_error, missing_uncertain = homes.publish_configuration(session, ".codex/missing.toml", missing, {})
            if not missing_path then error(tostring(missing_error)) end
            test.is_nil(missing_error)
            test.is_false(missing_uncertain == true)
            test.eq(native_fixture.shell("cat " .. quote.posix(home .. "/.codex/missing.toml")), missing)

            local created: {[string]: boolean} = {}
            local deep = "[agent]\nmode = \"retained\"\n"
            local deep_path, deep_error, deep_uncertain = homes.publish_configuration(session, ".bee/config/nested.toml", deep, created)
            if not deep_path then error(tostring(deep_error)) end
            test.is_nil(deep_error)
            test.is_false(deep_uncertain == true)
            test.is_true(created[session .. "/home/.bee"] == true)
            test.is_true(created[session .. "/home/.bee/config"] == true)
            test.eq(native_fixture.shell("cat " .. quote.posix(home .. "/.bee/config/nested.toml")), deep)

            -- Existing nested parents may be reused safely; the target is
            -- still a newly published regular file.
            test.eq(native_fixture.shell("mkdir -p " .. quote.posix(home .. "/.gemini/config")), "")
            local nested = "{\"mcp\":{\"enabled\":true}}\n"
            local nested_path, nested_error, nested_uncertain = homes.publish_configuration(session, ".gemini/config/settings.json", nested, {})
            if not nested_path then error(tostring(nested_error)) end
            test.is_nil(nested_error)
            test.is_false(nested_uncertain == true)
            test.eq(native_fixture.shell("cat " .. quote.posix(home .. "/.gemini/config/settings.json")), nested)
            test.eq(native_fixture.shell("cat " .. quote.posix(home .. "/.codex/auth.json")), login)
            test.eq(native_fixture.shell("cat " .. quote.posix(home .. "/.codex/conversations/thread.json")), conversation)
        end)
        test.it("publishes bounded composed configuration without widening ordinary generated files", function()
            local session = assert(homes.ensure_session(assert(homes.session_key(native_fixture.OWNER, native_fixture.fresh("large-composition")))))
            local content = 'model = "fixture"\n# ' .. string.rep("x", 32768) .. "\n"
            test.is_nil(homes.publish_configuration(session, ".codex/config.toml", content, {}))
            local published, err = homes.publish_configuration(session, ".codex/config.toml", content, {}, true)
            test.not_nil(published)
            test.is_nil(err)
            local home = assert(homes.os_path(session .. "/home"))
            test.eq(native_fixture.shell("sha256sum " .. quote.posix(home .. "/.codex/config.toml")):match("^([0-9a-f]+)"), assert(hash.sha256(content)))
            test.is_nil(homes.publish_configuration(session, ".codex/config.toml", string.rep("x", 131073), {}, true))
            test.eq(native_fixture.shell("sha256sum " .. quote.posix(home .. "/.codex/config.toml")):match("^([0-9a-f]+)"), assert(hash.sha256(content)))
        end)
        test.it("refuses unsafe retained configuration targets and preserves existing bytes", function()
            local function new_session(label: string): (string, string)
                local key = assert(homes.session_key(native_fixture.OWNER, native_fixture.fresh(label)))
                local session = assert(homes.ensure_session(key))
                local home = assert(homes.os_path(session .. "/home"))
                return session, home
            end
            local function refused(session: string, relative: string, content: string): string
                local published, publish_error, uncertain = homes.publish_configuration(session, relative, content, {})
                test.is_nil(published)
                test.not_nil(publish_error)
                test.is_false(uncertain == true)
                return tostring(publish_error)
            end

            local escaped, escaped_home = new_session("published-escape")
            test.eq(refused(escaped, "../escape.toml", "escape"), "configuration path escapes the home")
            test.eq(native_fixture.shell("test ! -e " .. quote.posix(escaped_home .. "/../escape.toml") .. " && printf absent"), "absent")

            local linked_parent, linked_parent_home = new_session("published-link-parent")
            test.eq(native_fixture.shell("mkdir -p " .. quote.posix(linked_parent_home .. "/.real-parent") .. " && ln -s .real-parent " .. quote.posix(linked_parent_home .. "/.linked-parent")), "")
            refused(linked_parent, ".linked-parent/config.toml", "must-not-follow")
            test.eq(native_fixture.shell("test ! -e " .. quote.posix(linked_parent_home .. "/.real-parent/config.toml") .. " && printf absent"), "absent")

            local linked_target, linked_target_home = new_session("published-link-target")
            test.eq(native_fixture.shell("mkdir -p " .. quote.posix(linked_target_home .. "/.codex") .. " && printf protected > " .. quote.posix(linked_target_home .. "/.codex/actual.toml") .. " && ln -s actual.toml " .. quote.posix(linked_target_home .. "/.codex/config.toml")), "")
            refused(linked_target, ".codex/config.toml", "must-not-replace-link")
            test.eq(native_fixture.shell("cat " .. quote.posix(linked_target_home .. "/.codex/actual.toml")), "protected")

            local nonregular, nonregular_home = new_session("published-nonregular")
            test.eq(native_fixture.shell("mkdir -p " .. quote.posix(nonregular_home .. "/.codex/config.toml")), "")
            refused(nonregular, ".codex/config.toml", "must-not-replace-directory")
            test.eq(native_fixture.shell("test -d " .. quote.posix(nonregular_home .. "/.codex/config.toml") .. " && printf directory"), "directory")

            local oversized, oversized_home = new_session("published-oversized")
            test.eq(native_fixture.shell("mkdir -p " .. quote.posix(oversized_home .. "/.codex") .. " && printf keep > " .. quote.posix(oversized_home .. "/.codex/config.toml")), "")
            refused(oversized, ".codex/config.toml", string.rep("x", 16 * 1024 + 1))
            test.eq(native_fixture.shell("cat " .. quote.posix(oversized_home .. "/.codex/config.toml")), "keep")

            -- Exercise the operation's boundary check against the actual
            -- placement root mode, restoring the fixture before assertions.
            local private, private_home = new_session("published-private-root")
            local root = assert(homes.os_path("/"))
            local original_mode = native_fixture.shell("stat -c %a " .. quote.posix(root)):match("^([0-7]+)")
            if not original_mode then error("read placement root mode") end
            test.eq(native_fixture.shell("chmod 0755 " .. quote.posix(root)), "")
            local ok, published, publish_error, uncertain = pcall(homes.publish_configuration, private, ".codex/config.toml", "private-check", {})
            test.eq(native_fixture.shell("chmod " .. original_mode .. " " .. quote.posix(root)), "")
            test.is_true(ok)
            test.is_nil(published)
            test.not_nil(publish_error)
            test.is_false(uncertain == true)
            test.eq(native_fixture.shell("test ! -e " .. quote.posix(private_home .. "/.codex/config.toml") .. " && printf absent"), "absent")
        end)
        test.it("seeds fixed private login destinations and preserves harness-refreshed bytes", function()
            local session_key = assert(homes.session_key(native_fixture.OWNER, native_fixture.fresh("login-session")))
            local session_path = assert(homes.ensure_session(session_key))
            local source = {provider = "codex", format = native_fixture.CODEX_LOGIN_FORMAT, definition_id = "bee.test.codex_login", definition_revision = 1}
            local seeded, seed_error, resumed = homes.retain_login(session_path, source, "initial-login-bytes")
            test.not_nil(seeded)
            test.is_nil(seed_error)
            test.is_false(resumed == true)
            local home = assert(homes.os_path(session_path .. "/home"))
            -- A provider owns the opaque bytes once seeded. This stands in for
            -- a harness refresh between retained launches.
            test.eq(native_fixture.shell("printf refreshed-login-bytes > " .. home .. "/.codex/auth.json"), "")
            local replayed, replay_error, replay = homes.retain_login(session_path, source, "stale-broker-bytes")
            test.not_nil(replayed)
            test.is_nil(replay_error)
            test.is_true(replay == true)
            test.eq(native_fixture.shell("cat " .. home .. "/.codex/auth.json"), "refreshed-login-bytes")
            local claude_key = assert(homes.session_key(native_fixture.OWNER, native_fixture.fresh("claude-login-session")))
            local claude_session = assert(homes.ensure_session(claude_key))
            local claude = assert(homes.retain_login(claude_session,
                {provider = "claude", format = native_fixture.CLAUDE_LOGIN_FORMAT, definition_id = "bee.test.claude_login", definition_revision = 1}, "claude-login-bytes"))
            test.is_true(claude:find("/.claude/.credentials.json", 1, true) ~= nil)
            local claude_home, home_error = homes.os_path(claude_session .. "/home")
            if not claude_home then error(tostring(home_error)) end
            test.eq(native_fixture.shell("cat " .. quote.posix(claude_home .. "/.claude.json")), '{"hasCompletedOnboarding":true}')
            test.eq(native_fixture.shell("printf private-settings > " .. quote.posix(claude_home .. "/.claude.json")), "")
            local _, replay_error = homes.retain_login(claude_session,
                {provider = "claude", format = native_fixture.CLAUDE_LOGIN_FORMAT, definition_id = "bee.test.claude_login", definition_revision = 1}, "stale-login")
            test.is_nil(replay_error)
            test.eq(native_fixture.shell("cat " .. quote.posix(claude_home .. "/.claude.json")), "private-settings")
        end)
        test.it("leaves Claude onboarding to the harness when no machine login is available", function()
            local key, key_error = homes.session_key(native_fixture.OWNER, native_fixture.fresh("claude-no-login"))
            if not key then error(tostring(key_error)) end
            local session_path, session_error = homes.ensure_session(key)
            if not session_path then error(tostring(session_error)) end
            local target, seed_error = homes.retain_login(session_path,
                {provider = "claude", format = native_fixture.CLAUDE_LOGIN_FORMAT, definition_id = "bee.test.claude_login", definition_revision = 1, optional = true}, nil)
            test.not_nil(target)
            test.is_nil(seed_error)
            local home, home_error = homes.os_path(session_path .. "/home")
            if not home then error(tostring(home_error)) end
            test.eq(native_fixture.shell("test ! -e " .. quote.posix(home .. "/.claude.json") .. " && printf absent"), "absent")
        end)
        test.it("retains optional login absence and preserves later private sign-in and sign-out", function()
            local session_key = assert(homes.session_key(native_fixture.OWNER, native_fixture.fresh("optional-login")))
            local session_path = assert(homes.ensure_session(session_key))
            local source = {provider = "codex", format = native_fixture.CODEX_LOGIN_FORMAT, definition_id = "bee.test.optional_login", definition_revision = 1, optional = true}
            local created: {[string]: boolean} = {}
            local target, seed_error = homes.retain_login(session_path, source, nil, created)
            test.not_nil(target)
            test.is_nil(seed_error)
            local home = assert(homes.os_path(session_path .. "/home"))
            test.eq(native_fixture.shell("test ! -e " .. home .. "/.codex/auth.json && printf absent"), "absent")
            -- The immutable driver config can follow the intentionally empty login.
            test.not_nil(homes.write_protected(session_path, ".codex/config.toml", "approved", created, true))
            test.eq(native_fixture.shell("printf private-sign-in > " .. home .. "/.codex/auth.json"), "")
            local _, replay_error, replayed = homes.retain_login(session_path, source, "machine-login")
            test.is_nil(replay_error)
            test.is_true(replayed == true)
            test.eq(native_fixture.shell("cat " .. home .. "/.codex/auth.json"), "private-sign-in")
            test.eq(native_fixture.shell("rm " .. home .. "/.codex/auth.json"), "")
            local _, logout_error = homes.retain_login(session_path, source, "machine-login")
            test.is_nil(logout_error)
            test.eq(native_fixture.shell("test ! -e " .. home .. "/.codex/auth.json && printf absent"), "absent")
            local _, changed_error = homes.retain_login(session_path,
                {provider = "codex", format = native_fixture.CODEX_LOGIN_FORMAT, definition_id = "bee.test.optional_login", definition_revision = 1}, "machine-login")
            test.eq(changed_error, "retained login source changed")
            local _, empty_error = homes.retain_login(session_path, source, "")
            test.eq(empty_error, "login bytes exceed bound")
            local _, required_error = homes.retain_login(session_path,
                {provider = "codex", format = native_fixture.CODEX_LOGIN_FORMAT, definition_id = "bee.test.required_login", definition_revision = 1}, nil)
            test.eq(required_error, "required login bytes missing")
        end)
        test.it("publishes admitted setup when an optional login is absent", function()
            local session_key = assert(homes.session_key(native_fixture.OWNER, native_fixture.fresh("optional-login-setup")))
            local session_path = assert(homes.ensure_session(session_key))
            local format = {schema_revision = "bee.credential-format@1", file = {
                path = ".grok/auth.json", content_format = "json",
                initialize = {{path = ".grok/.bee-global-config.toml", content = "[ui]\ntheme = \"system\"\n", on_missing_login = true}}}}
            local source = {provider = "grok", format = format, definition_id = "bee.test.grok_login", definition_revision = 1, optional = true}
            local created: {[string]: boolean} = {}
            local target, seed_error, replayed = homes.retain_login(session_path, source, nil, created)
            test.not_nil(target)
            test.is_nil(seed_error)
            test.is_false(replayed == true)
            local home = assert(homes.os_path(session_path .. "/home"))
            test.eq(native_fixture.shell("test ! -e " .. home .. "/.grok/auth.json && printf absent"), "absent")
            test.eq(native_fixture.shell("cat " .. home .. "/.grok/.bee-global-config.toml"), "[ui]\ntheme = \"system\"\n")
            local setup_digest = assert(hash.sha256("[ui]\ntheme = \"system\"\n"))
            local base, base_error = homes.read_configuration(session_path, ".grok/.bee-global-config.toml", setup_digest)
            test.eq(base, "[ui]\ntheme = \"system\"\n")
            test.is_nil(base_error)
            local absent, absent_error = homes.read_configuration(session_path, ".grok/missing.toml", setup_digest)
            test.is_nil(absent)
            test.eq(absent_error, "configuration base is missing")
            test.is_nil(homes.read_configuration(session_path, "../escape.toml", setup_digest))
            local changed, changed_error = homes.read_configuration(session_path, ".grok/.bee-global-config.toml", string.rep("a", 64))
            test.is_nil(changed)
            test.eq(changed_error, "configuration base differs from admitted content")
            local _, replay_error, replay = homes.retain_login(session_path, source, nil, {})
            test.is_nil(replay_error)
            test.is_true(replay == true)
        end)
        test.it("refuses changed or incomplete retained login state without exposing bytes", function()
            local session_key = assert(homes.session_key(native_fixture.OWNER, native_fixture.fresh("login-reject-session")))
            local session_path = assert(homes.ensure_session(session_key))
            local source = {provider = "codex", format = native_fixture.CODEX_LOGIN_FORMAT, definition_id = "bee.test.login_source", definition_revision = 1}
            assert(homes.retain_login(session_path, source, "opaque-login-not-in-errors"))
            for _, changed in ipairs({
                {provider = "claude", format = native_fixture.CLAUDE_LOGIN_FORMAT, definition_id = "bee.test.login_source", definition_revision = 1},
                {provider = "codex", format = native_fixture.CODEX_LOGIN_FORMAT, definition_id = "bee.test.other_login_source", definition_revision = 1},
                {provider = "codex", format = native_fixture.CODEX_LOGIN_FORMAT, definition_id = "bee.test.login_source", definition_revision = 2},
            }) do
                local _, changed_error = homes.retain_login(session_path, changed, "different-opaque-login-bytes")
                test.eq(changed_error, "retained login source changed")
                test.is_nil((changed_error:find("opaque-login-not-in-errors", 1, true)))
                test.is_nil((changed_error:find("different-opaque-login-bytes", 1, true)))
            end
            local partial_key = assert(homes.session_key(native_fixture.OWNER, native_fixture.fresh("login-partial-session")))
            local partial_session = assert(homes.ensure_session(partial_key))
            local made, made_error = homes.write_protected(partial_session, ".codex/auth.json", "partial", {[(partial_session .. "/home/.codex")] = true}, true)
            test.not_nil(made)
            test.is_nil(made_error)
            local _, partial_error = homes.retain_login(partial_session, source, "opaque-login-not-in-errors")
            test.eq(partial_error, "retained login is incomplete")
            -- This inspects the live root; the assertion is not inferred from
            -- the fs.directory manifest's requested mode.
            local root = assert(homes.os_path("/"))
            test.eq(native_fixture.shell("stat -c %a " .. root):match("%d+"), "700")
        end)
        test.it("seeds a nested component login without adopting unrelated existing directories", function()
            local key, key_error = homes.session_key(native_fixture.OWNER, native_fixture.fresh("nested-login"))
            if not key then error(tostring(key_error)) end
            local session, session_error = homes.ensure_session(key)
            if not session then error(tostring(session_error)) end
            local format = {schema_revision = "bee.credential-format@1", file = {
                path = ".gemini/antigravity-cli/antigravity-oauth-token", content_format = "opaque",
                initialize = {{path = ".gemini/antigravity-cli/initialized", content = "ready"}}}}
            local source = {provider = "agy", definition_id = "bee.test.nested_login", definition_revision = 1, format = format}
            local created: {[string]: boolean} = {}
            local target, seed_error = homes.retain_login(session, source, "opaque\0login", created)
            if not target then error(tostring(seed_error)) end
            test.is_true(created[session .. "/home/.gemini"] == true)
            test.is_true(created[session .. "/home/.gemini/antigravity-cli"] == true)
            local written, write_error = homes.write_protected(session, ".gemini/config/mcp_config.json", "approved", created, true)
            if not written then error(tostring(write_error)) end
            local _, replay_error, replayed = homes.retain_login(session, source, "stale")
            test.is_nil(replay_error)
            test.is_true(replayed == true)
            local bad_key, bad_key_error = homes.session_key(native_fixture.OWNER, native_fixture.fresh("existing-login-parent"))
            if not bad_key then error(tostring(bad_key_error)) end
            local bad_session, bad_error = homes.ensure_session(bad_key)
            if not bad_session then error(tostring(bad_error)) end
            local made, make_error = homes.write_protected(bad_session, ".gemini/unrelated", "existing", {}, true)
            if not made then error(tostring(make_error)) end
            local refused, refusal = homes.retain_login(bad_session, source, "secret")
            test.is_nil(refused)
            test.eq(refusal, "retained login parent already exists")
            local reserved, reserved_error = homes.decode_login_source({provider = "fixture", definition_id = "fixture", definition_revision = 1,
                format = {schema_revision = "bee.credential-format@1", file = {path = ".bee-retained-login-ready.json", content_format = "opaque"}}})
            test.is_nil(reserved)
            test.eq(reserved_error, "login format overlaps retained identity")
        end)
        test.it("keeps a retained home excluded when its placement is uncertain", function()
            local session_ref = native_fixture.fresh("uncertain-session")
            local first = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", native_fixture.retained_launch(native_fixture.OWNER, session_ref, "uncertain")))
            local db, open_error = store.open()
            if not db then error(open_error or "open store") end
            local uncertain = store.transition(db, first.attempt_id, {execution = "uncertain",
                evidence = {kind = "test.uncertain", detail = "placement outcome is not proven"}})
            db:release()
            test.eq(uncertain.ok, true)
            local blocked = native_fixture.call(native_fixture.OWNER, "prepare", native_fixture.retained_launch(native_fixture.OWNER, session_ref, "must-not-run"))
            test.eq(blocked.error and blocked.error.code, "CONFLICT")
            test.is_true(tostring(blocked.error and blocked.error.message):find("retained session is still held", 1, true) ~= nil)
        end)
    end)
end


return {configuration = native_fixture.suite(configuration_tests)}
