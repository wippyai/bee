-- MIT. Focused native configuration test cases.
local test = require("test")
local bounds = require("bounds")
local principals = require("principals")
local registry = require("registry")
local configuration = require("configuration")
local configuration_protocol = require("configuration_protocol")
local preferences = require("preferences")
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

local M = {}
function M.define()
    for _, ending in ipairs({"attempt", "session", "retire", "delete", "revoke"}) do
        test.it("clears retained folder trust on " .. ending, function()
            local profile = native_fixture.fresh("trust-profile")
            local db = assert(store.open())
            local grant = assert(authority.save(db, native_fixture.OWNER, profile, profile, 1,
                {driver_binding_ref = "bee.drivers.codex.binding:binding", provider = {options = {folder_trust = "approved-workdir"}}},
                "person", false, "2026-10-01T00:00:00.000Z"))
            db:release()
            local request = native_fixture.retained_launch(native_fixture.OWNER, profile, "trust")
            request.configuration_digest = nil
            request.policy_ref = "bee.tests.placement.native:trust_launch_policy"
            request.preferences = {options = {folder_trust = "approved-workdir"}, authority_grant_id = grant.grant_id}
            local workdir = native_fixture.fresh("approved")
            native_fixture.shell(quote.line({"mkdir", "-p", assert(resources.directory(native_fixture.ROOT)) .. "/" .. workdir .. "/.git"}))
            db = assert(store.open())
            local scoped: grants.Grant = {grant_id = native_fixture.fresh("scoped-trust"), domain = grant.domain, owner_node = grant.owner_node,
                workspace_id = grant.workspace_id, requester_id = grant.requester_id, granted_by = grant.granted_by, subject = grant.subject,
                scope = {type = "exact", parameters = {parent_grant_id = grant.grant_id,
                    canonical_workdir = assert(resources.directory(native_fixture.ROOT)) .. "/" .. workdir,
                    configuration = {driver_binding_ref = "bee.drivers.codex.binding:binding", provider = {options = {folder_trust = "approved-workdir"}}}}},
                terms = grant.terms, provenance = grant.provenance, metadata = {profile_id = profile, folder_profile_grant = grant.grant_id},
                state = "active", revision = 1, used = 0, reserved = 0, created_at = grant.created_at}
            assert(not grants.create(db, scoped)); db:release()
            local grants_list = principals.objects(request.resources)
            request.resources = grants_list
            for _, resource in ipairs(grants_list) do if resource.name == "project" then resource.subpath = workdir end end
            local launch = assert(bounds.object(request.launch))
            launch.provider_home = {provider = "codex", private = true, variable = "CODEX_HOME", directory = ".codex", files = {}}
            launch.argv = {"-c", [[grep -q 'trust_level.*trusted' "$CODEX_HOME/config.toml" || exit 7; ]] ..
                ((ending == "attempt" or ending == "session") and "exit 0" or "exec sleep 30")}
            local data = assert(bounds.object(assert(registry.get("bee.tests.placement.native:trust_launch_policy")).data))
            local effective = assert(preferences.apply(data, request.preferences, assert(descriptors.load("bee.drivers.codex.descriptor:cli")), native_fixture.native_placement()))
            request.configuration_digest = assert(configuration_protocol.digest("bee.drivers.codex.binding:binding",
                {placement = native_fixture.native_placement(), fixture = true, provider_ref = "bee.tests.placement.native:codex_test_provider", provider = assert(registry.get("bee.tests.placement.native:codex_test_provider")),
                    option_values = effective.prepare_options}, "bee.drivers.codex.binding:configure"))
            local independent = native_fixture.retained_launch(native_fixture.OWNER, native_fixture.fresh("independent"), "independent")
            local independent_after = native_fixture.retained_launch(native_fixture.OWNER, native_fixture.fresh("independent-after"), "independent-after")
            local planned_digest = independent.configuration_digest
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            local started = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
            assert(not started.start_failure, started.start_failure)
            local other = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", independent))
            local other_started = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = other.attempt_id}))
            assert(not other_started.start_failure, other_started.start_failure)
            test.is_true(native_fixture.wait_for(function()
                local status = native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = other.attempt_id}))
                return assert(bounds.object(status.attempt)).execution_state == "exited"
            end, 8000))
            test.eq(native_fixture.provider_configuration_digest(), planned_digest)
            local other_home = assert(homes.ensure_session(assert(homes.session_key(native_fixture.OWNER, assert(bounds.id(independent.session_ref))))))
            test.neq(other_home, assert(homes.ensure_session(assert(homes.session_key(native_fixture.OWNER, profile)))))
            local other_path = assert(homes.os_path(other_home .. "/home/.codex/config.toml"))
            local other_config = native_fixture.shell(quote.line({"cat", other_path}))
            test.is_nil((other_config:find("trust_level", 1, true)))
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
            local after = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", independent_after))
            test.eq(independent_after.configuration_digest, planned_digest)
            test.eq(native_fixture.shell(quote.line({"cat", other_path})), other_config)
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = other.attempt_id}))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "stop", {attempt_id = after.attempt_id}))
            for _, project in pairs(assert(bounds.object(root.projects))) do test.is_nil(assert(bounds.object(project)).trust_level) end
        end)
    end
    test.it("reuses folder consent on a second isolated launch and asks outside its scope", function()
        local profile = native_fixture.fresh("folder-consent-profile")
        local root = assert(resources.directory(native_fixture.ROOT))
        local folder = native_fixture.fresh("folder-consent")
        native_fixture.shell(quote.line({"mkdir", "-p", root .. "/" .. folder .. "/.git", root .. "/" .. folder .. "-other/.git"}))
        local db = assert(store.open())
        local base = assert(authority.save(db, native_fixture.OWNER, profile, profile, 1,
            {driver_binding_ref = "bee.drivers.codex.binding:binding", provider = {options = {folder_trust = "approved-workdir"}}}, "person", false, "2026-10-01T00:00:00.000Z"))
        local consent: grants.Grant = {grant_id = native_fixture.fresh("folder-consent-grant"), domain = "profile_choices",
            owner_node = base.owner_node, workspace_id = base.workspace_id, requester_id = base.requester_id,
            granted_by = base.granted_by, subject = base.subject,
            scope = {type = "exact", parameters = {profile_id = profile, parent_grant_id = base.grant_id,
                canonical_workdir = root .. "/" .. folder, configuration = {driver_binding_ref = "bee.drivers.codex.binding:binding", provider = {options = {folder_trust = "approved-workdir"}}}}},
            terms = {kind = "until_revoked", time_basis = "absolute"}, provenance = {kind = "consent", source = "saved_profile"},
            metadata = {profile_id = profile, folder_profile_grant = base.grant_id}, state = "active", revision = 1, used = 0, reserved = 0, created_at = base.created_at}
        assert(not grants.create(db, consent)); db:release()
        for index, path in ipairs({folder, folder, folder .. "-other", folder}) do
            if index == 4 then
                db = assert(store.open()); assert(not grants.revoke(db, consent, 1, "person", 1790000000000)); db:release()
            end
            local request = native_fixture.retained_launch(native_fixture.OWNER, profile, "folder-consent")
            request.policy_ref = "bee.tests.placement.native:trust_launch_policy"
            request.preferences = {options = {folder_trust = index == 1 and "approved-workdir" or "ask"}, authority_grant_id = base.grant_id}
            local granted = principals.objects(request.resources); request.resources = granted
            for _, resource in ipairs(granted) do if resource.name == "project" then resource.subpath = path end end
            local launch = assert(bounds.object(request.launch))
            launch.provider_home = {provider = "codex", private = true, variable = "CODEX_HOME", directory = ".codex", files = {}}
            launch.argv = {"-c", [[if grep -q 'trust_level.*trusted' "$CODEX_HOME/config.toml"; then exit 0; else exit 7; fi]]}
            local data = assert(bounds.object(assert(registry.get(request.policy_ref)).data))
            local effective = assert(preferences.apply(data, request.preferences, assert(descriptors.load("bee.drivers.codex.descriptor:cli")), native_fixture.native_placement()))
            request.configuration_digest = assert(configuration_protocol.digest("bee.drivers.codex.binding:binding",
                {placement = native_fixture.native_placement(), fixture = true, provider_ref = "bee.tests.placement.native:codex_test_provider", provider = assert(registry.get("bee.tests.placement.native:codex_test_provider")), option_values = effective.prepare_options},
                "bee.drivers.codex.binding:configure"))
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            local started = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
            assert(not started.start_failure, started.start_failure)
            test.is_true(native_fixture.wait_for(function()
                return assert(bounds.object(native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt)).execution_state == "exited"
            end, 8000))
            local ended = assert(bounds.object(native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt))
            test.eq(assert(bounds.object(ended.exit)).code, index < 3 and 0 or 7)
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = prepared.attempt_id}))
        end
    end)
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
            local cli = assert(descriptors.load("bee.drivers." .. driver .. ".descriptor:cli"))
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
        local muse = assert(descriptors.load("bee.drivers.muse.descriptor:cli"))
        local field = assert(bounds.object(assert(bounds.object(muse.options.fields)).folder_trust))
        test.eq(assert(bounds.object(field.trust)).flag, "--trust-workspace")
    end)

end
return M
