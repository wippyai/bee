local test = require("test")
local super_edit = require("super_edit")

local WORKSPACE = "0123456789abcdef0123456789abcdef"
local function define_tests()
    test.describe("super-edit host profiles", function()
        test.it("parses an exact namespace list and bounded duration", function()
            local namespaces, duration, invalid = super_edit.parse_enable("vendor.alpha app.clock --for 45m")
            test.is_nil(invalid)
            test.eq(duration, "45m")
            test.eq(#(namespaces :: {string}), 2)
            test.eq((namespaces :: {string})[1], "app.clock")
            test.eq((namespaces :: {string})[2], "vendor.alpha")
            test.eq(super_edit.duration("1d"), "24h")
            test.is_nil(super_edit.duration("25h"))
            test.is_nil(super_edit.parse_enable("vendor.alpha vendor.alpha --for 5m"))
            test.is_nil(super_edit.parse_enable(string.rep("a", 257)))
        end)

        test.it("writes one bounded profile per exact non-kernel namespace", function()
            local namespaces = {"vendor.alpha", "app.clock"}
            local changed, err = super_edit.enable({profiles = {}, workspace_applications = true}, WORKSPACE,
                "node-local", namespaces, "2030-01-01T00:00:00.000Z", {"bee.gov", "bee.security"})
            if not changed then error(tostring(err)) end
            local rows = changed.profiles :: {{[string]: unknown}}
            test.eq(#rows, 2)
            test.eq(rows[1].source_workspace, "app.clock")
            test.eq(rows[1].component, "app.clock")
            local owner_prefix = "bee.super_edit:" .. WORKSPACE .. "."
            test.eq(string.sub(rows[1].overlay_owner :: string, 1, #owner_prefix), owner_prefix)
            test.eq(rows[1].approval_policy, "super-edit-person")
            test.eq(rows[1].expires_at, "2030-01-01T00:00:00.000Z")
            local allow = rows[1].allow :: {[string]: unknown}
            test.eq(allow.auto_start, false)
            test.eq(#(allow.grants :: {unknown}), 0)
            test.eq(#(allow.namespaces :: {unknown}), 1)
            test.eq((allow.namespaces :: {string})[1], "app.clock")
            test.eq(changed.workspace_applications, true)
        end)

        test.it("refuses kernel namespaces and ancestors that would contain them", function()
            for _, namespace in ipairs({"bee.gov", "bee.gov.binding", "bee"}) do
                local changed, err = super_edit.enable({profiles = {}}, WORKSPACE, "node-local", {namespace},
                    "2030-01-01T00:00:00.000Z", {"bee.gov", "bee.security"})
                test.is_nil(changed)
                test.not_nil((string.find(tostring(err), "kernel namespace", 1, true)))
            end
        end)

        test.it("requires an existing super-edit profile to be disabled before replacement", function()
            local changed, err = super_edit.enable({profiles = {
                {workspace_id = WORKSPACE, source_node = "node-local", source_workspace = "vendor.alpha",
                    expires_at = "2030-01-01T00:00:00.000Z", overlay_owner = "bee.super_edit:old"}}},
                WORKSPACE, "node-local", {"vendor.alpha"}, "2030-02-01T00:00:00.000Z", {})
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
            local rows = changed.profiles :: {{[string]: unknown}}
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
            local rows = changed.profiles :: {unknown}
            test.eq(#rows, 1)
            test.eq((rows[1] :: {[string]: unknown}).overlay_owner, "bee.packages:" .. WORKSPACE .. ".normal")
        end)
    end)
end

return test.run_cases(define_tests)
