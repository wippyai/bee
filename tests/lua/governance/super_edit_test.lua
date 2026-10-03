local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local super_edit = require("super_edit")
local security = require("security")
local funcs = require("funcs")
local principal = require("principal")
local registry = require("registry")

local KERNEL = {revision = 1, namespaces = {"bee.gov", "bee.security"}, super_edit = {}, entries = {"bee.security.gov:protected_kernel"}}
local WORKSPACE = "0123456789abcdef0123456789abcdef"
local function settings_scope(): security.Scope
    local policies: {security.Policy} = {}
    for _, id in ipairs({"bee.security:base_app_policy", "bee.security:app_boundary_policy",
        "bee.security:core_spawn_boundary", "bee.security.storage:workspace_storage_boundary"}) do
        policies[#policies + 1] = assert(security.policy(id))
    end
    local admission = assert(registry.get("bee.security:application_admission"))
    local data = assert(bounds.object(admission.data))
    local found = false
    for _, binding in ipairs(principals.objects(data.bindings)) do
        if binding.definition_id == "bee.settings.app:app" then
            found = true
            for _, id in ipairs(principals.strings(binding.policies)) do
                policies[#policies + 1] = assert(security.policy(id))
            end
        end
    end
    assert(found, "Settings admission missing")
    return assert(security.new_scope(policies))
end
local function define_tests()
    test.describe("super-edit host profiles", function()
        test.it("runs the Settings facade under its admitted application boundary", function()
            local identity = assert(principal.value(WORKSPACE, "settings-instance", "bee.settings.app:app", "1", 1))
            local executor = assert(funcs.new():with_actor(assert(security.new_actor(identity.id, identity.metadata)))
                :with_scope(settings_scope()))
            local raw, err = executor:call("bee.gov.binding:super_edit_call", {
                operation = "enable", workspace_id = WORKSPACE, input = "invalid"})
            test.is_nil(err, tostring(err))
            test.eq(assert(bounds.object(raw)).code, "INVALID")
        end)
        test.it("accepts the broker-minted Settings origin and preserves backend refusals", function()
            local identity = assert(principal.value(WORKSPACE, "settings-instance", "bee.settings.app:app", "1", 1))
            local actor = assert(security.new_actor(identity.id, identity.metadata))
            local executor = assert(funcs.new():with_actor(actor))
            local raw, err = executor:call("bee.gov.binding:super_edit_call", {
                operation = "enable", workspace_id = WORKSPACE, input = "invalid"})
            test.is_nil(err)
            local result = assert(bounds.object(raw))
            test.eq(result.code, "INVALID")
            test.eq(result.message, "enter NAMESPACE... --for DURATION")
        end)
        test.it("admits the host-selected Settings edit grant", function()
            local original = assert(registry.get("bee.env:gov_activation_profiles"))
            local identity = assert(principal.value(WORKSPACE, "settings-instance", "bee.settings.app:app", "1", 1))
            local executor = assert(funcs.new():with_actor(assert(security.new_actor(identity.id, identity.metadata)))
                :with_scope(settings_scope()))
            local raw, err = executor:call("bee.gov.binding:super_edit_call", {
                operation = "enable", workspace_id = WORKSPACE, input = "bee.settings.app --for 5m"})
            local policy = assert(security.policy("bee.security.gateway:gateway_tool_delivery_policy"))
            local author = assert(funcs.new():with_actor(assert(security.new_actor("fixture.author")))
                :with_scope(assert(security.new_scope({policy}))))
            local delivered, delivery_error = author:call("bee.gov.binding:delivery_call", {
                operation = "request", workspace_id = WORKSPACE, source_overlay_id = "bee.settings.app",
                version = "1.0.0", snapshot_digest = string.rep("a", 64)})
            local restore = assert(registry.snapshot()):changes()
            assert(restore:update(original)); assert(restore:apply())
            test.is_nil(err)
            local result = assert(bounds.object(raw))
            test.is_true(result.ok == true, tostring(result.message))
            test.is_nil(delivery_error)
            local refusal = assert(bounds.object(delivered))
            test.eq(refusal.code, "MISSING_ARTIFACT", tostring(refusal.message))
        end)
        test.it("reads current edit admission after the initiating Settings execution is replaced", function()
            local original = assert(registry.get("bee.env:gov_activation_profiles"))
            local identity = assert(principal.value(WORKSPACE, "settings-instance", "bee.settings.app:app", "1", 2))
            local executor = assert(funcs.new():with_actor(assert(security.new_actor(identity.id, identity.metadata)))
                :with_scope(settings_scope()))
            local enabled, enable_error = executor:call("bee.gov.binding:super_edit_call", {
                operation = "enable", workspace_id = WORKSPACE, input = "bee.settings.app --for 5m"})
            local status_revision = assert(registry.snapshot()):version():string()
            local active, active_error = executor:call("bee.gov.binding:super_edit_call", {operation = "status", workspace_id = WORKSPACE})
            test.eq(assert(registry.snapshot()):version():string(), status_revision, "status wrote registry state")
            local disabled, disable_error = executor:call("bee.gov.binding:super_edit_call", {operation = "disable", workspace_id = WORKSPACE})
            local inactive, inactive_error = executor:call("bee.gov.binding:super_edit_call", {operation = "status", workspace_id = WORKSPACE})
            local restore = assert(registry.snapshot()):changes()
            assert(restore:update(original)); assert(restore:apply())
            test.is_nil(enable_error); test.is_nil(active_error); test.is_nil(disable_error); test.is_nil(inactive_error)
            test.is_true(assert(bounds.object(enabled)).ok == true)
            test.is_true(assert(bounds.object(disabled)).ok == true)
            local active_reply, inactive_reply = assert(bounds.object(active)), assert(bounds.object(inactive))
            test.is_true(active_reply.ok == true, tostring(active_reply.message))
            test.is_true(assert(bounds.object(active_reply.value)).enabled == true)
            test.is_true(inactive_reply.ok == true, tostring(inactive_reply.message))
            test.is_true(assert(bounds.object(inactive_reply.value)).enabled == false)
            test.eq(assert(bounds.object(inactive_reply.value)).message, "Edit mode is disabled for this workspace")
        end)
        test.it("reports malformed host profiles instead of calling edit mode disabled", function()
            local original = assert(registry.get("bee.env:gov_activation_profiles"))
            local change = assert(registry.snapshot()):changes()
            assert(change:update({id = original.id, kind = original.kind, meta = original.meta, data = {profiles = {{}}}}))
            assert(change:apply())
            local identity = assert(principal.value(WORKSPACE, "settings-instance", "bee.settings.app:app", "1", 1))
            local executor = assert(funcs.new():with_actor(assert(security.new_actor(identity.id, identity.metadata)))
                :with_scope(settings_scope()))
            local raw, err = executor:call("bee.gov.binding:super_edit_call", {operation = "status", workspace_id = WORKSPACE})
            local restore = assert(registry.snapshot()):changes()
            assert(restore:update(original)); assert(restore:apply())
            test.is_nil(err)
            local result = assert(bounds.object(raw))
            test.is_true(result.ok == false)
            test.eq(result.code, "INVALID")
            test.is_true(type(result.message) == "string" and result.message ~= "")
            test.is_nil(result.value)
        end)
        test.it("refuses other applications and a Settings request for another workspace", function()
            for _, definition in ipairs({"bee.console.app:app", "bee.settings.app:app"}) do
                local identity = assert(principal.value(WORKSPACE, "origin-instance", definition, "1", 1))
                local executor = assert(funcs.new():with_actor(assert(security.new_actor(identity.id, identity.metadata))))
                local raw, err = executor:call("bee.gov.binding:super_edit_call", {
                    operation = "enable", workspace_id = definition == "bee.settings.app:app" and string.rep("b", 32) or WORKSPACE,
                    input = "bee.settings.app --for 5m"})
                test.is_nil(err)
                test.eq(assert(bounds.object(raw)).code, "DENIED")
            end
        end)
        test.it("parses an exact namespace list and bounded duration", function()
            local namespaces, duration, invalid = super_edit.parse_enable("vendor.alpha app.clock --for 45m")
            test.is_nil(invalid)
            test.eq(duration, "45m")
            test.eq(#(principals.strings(namespaces)), 2)
            test.eq((principals.strings(namespaces))[1], "app.clock")
            test.eq((principals.strings(namespaces))[2], "vendor.alpha")
            test.eq(super_edit.duration("1d"), "24h")
            test.is_nil(super_edit.duration("25h"))
            test.is_nil(super_edit.parse_enable("vendor.alpha vendor.alpha --for 5m"))
            test.is_nil(super_edit.parse_enable(string.rep("a", 257)))
        end)

        test.it("writes one bounded profile per exact non-kernel namespace", function()
            local namespaces = {"vendor.alpha", "app.clock"}
            local changed, err = super_edit.enable({profiles = {}, workspace_applications = true}, WORKSPACE,
                "node-local", namespaces, "2030-01-01T00:00:00.000Z", KERNEL)
            if not changed then error(tostring(err)) end
            local rows = principals.objects(changed.profiles)
            test.eq(#rows, 2)
            test.eq(rows[1].source_workspace, "app.clock")
            test.eq(rows[1].component, "app.clock")
            local owner_prefix = "bee.super_edit:" .. WORKSPACE .. "."
            test.eq(string.sub(rows[1].overlay_owner, 1, #owner_prefix), owner_prefix)
            test.eq(rows[1].approval_policy, "super-edit-person")
            test.eq(rows[1].expires_at, "2030-01-01T00:00:00.000Z")
            local allow = assert(bounds.object(rows[1].allow))
            test.eq(allow.auto_start, false)
            test.eq(#(principals.items(allow.grants)), 0)
            test.eq(#(principals.items(allow.namespaces)), 1)
            test.eq((principals.strings(allow.namespaces))[1], "app.clock")
            test.eq(changed.workspace_applications, true)
        end)

        test.it("refuses kernel namespaces and ancestors that would contain them", function()
            for _, namespace in ipairs({"bee.gov", "bee.gov.binding", "bee"}) do
                local changed, err = super_edit.enable({profiles = {}}, WORKSPACE, "node-local", {namespace},
                    "2030-01-01T00:00:00.000Z", KERNEL)
                test.is_nil(changed)
                test.not_nil((string.find(tostring(err), "kernel namespace", 1, true)))
            end
        end)

        test.it("honors exact host carve-outs while refusing their protected parents", function()
            local opened = {revision = 1, namespaces = {"bee.settings", "bee.desktop", "bee.gov"},
                super_edit = {"bee.settings.app", "bee.desktop"}, entries = {"bee.security.gov:protected_kernel"}}
            for _, namespace in ipairs({"bee.settings.app", "bee.desktop"}) do
                local changed, err = super_edit.enable({profiles = {}}, WORKSPACE, "node-local", {namespace},
                    "2030-01-01T00:00:00.000Z", opened)
                test.not_nil(changed, tostring(err))
            end
            for _, namespace in ipairs({"bee", "bee.settings", "bee.gov"}) do
                local changed = super_edit.enable({profiles = {}}, WORKSPACE, "node-local", {namespace},
                    "2030-01-01T00:00:00.000Z", opened)
                test.is_nil(changed)
            end
        end)
        test.it("requires an existing super-edit profile to be disabled before replacement", function()
            local changed, err = super_edit.enable({profiles = {
                {workspace_id = WORKSPACE, source_node = "node-local", source_workspace = "vendor.alpha",
                    expires_at = "2030-01-01T00:00:00.000Z", overlay_owner = "bee.super_edit:old"}}},
                WORKSPACE, "node-local", {"vendor.alpha"}, "2030-02-01T00:00:00.000Z", KERNEL)
            test.is_nil(changed)
            test.not_nil((string.find(tostring(err), "disable edit mode", 1, true)))
        end)

        test.it("disables only the selected workspace's super-edit rows", function()
            local config = {profiles = {
                {workspace_id = WORKSPACE, source_workspace = "vendor.alpha", expires_at = "2030-01-01T00:00:00.000Z"},
                {workspace_id = WORKSPACE, source_workspace = "vendor.normal"},
                {workspace_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", source_workspace = "vendor.other",
                    expires_at = "2030-01-01T00:00:00.000Z"}}}
            local changed, err = super_edit.disable(config, WORKSPACE)
            if not changed then error(tostring(err)) end
            local rows = principals.objects(changed.profiles)
            test.eq(#rows, 2)
            test.eq(rows[1].source_workspace, "vendor.normal")
            test.eq(rows[2].source_workspace, "vendor.other")
        end)

        test.it("boot fallback removes all expiring profiles and returns exact owners", function()
            local changed, owners, err = super_edit.disable_all({profiles = {
                {workspace_id = WORKSPACE, overlay_owner = "bee.super_edit:" .. WORKSPACE .. ".vendor.beta.x", expires_at = "2030"},
                {workspace_id = WORKSPACE, overlay_owner = "bee.super_edit:" .. WORKSPACE .. ".vendor.alpha.y", expires_at = "2030"},
                {workspace_id = WORKSPACE, overlay_owner = "bee.super_edit:" .. WORKSPACE .. ".vendor.alpha.y", expires_at = "2030"},
                {workspace_id = WORKSPACE, overlay_owner = "bee.packages:" .. WORKSPACE .. ".normal"},
            }})
            if not changed or not owners then error(tostring(err)) end
            test.eq(#owners, 2)
            test.eq(owners[1], "bee.super_edit:" .. WORKSPACE .. ".vendor.alpha.y")
            test.eq(owners[2], "bee.super_edit:" .. WORKSPACE .. ".vendor.beta.x")
            local rows = principals.items(changed.profiles)
            test.eq(#rows, 1)
            test.eq((assert(bounds.object(rows[1]))).overlay_owner, "bee.packages:" .. WORKSPACE .. ".normal")
        end)
    end)
end

return test.run_cases(define_tests)
