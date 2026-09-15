-- MIT. App Delivery frames remain bounded and distinguish available from selected.
local test = require("test")
local tty = require("tty")
local model = require("model")
local view = require("view")
local appearance = require("appearance")

local function define_tests()
    test.describe("App Delivery frame", function()
        test.it("shows staged updates without presenting them as active", function()
            local state = model.new("workspace-destination")
            model.toggle_pane(state)
            local digest = string.rep("a", 64)
            model.apply_list(state, {ok = true, error = nil, replayed = false, value = {owner_node = "node-destination",
                workspace_id = "workspace-destination", plans = {{owner_node = "node-destination",
                    workspace_id = "workspace-destination", source_node = "node-source",
                    source_workspace = "example-app", version = "2.0.0", plan_digest = digest,
                    candidate_digest = digest, artifact_digest = digest, preflight_digest = digest,
                    revision = 1, status = "staged", selected = false}}}})
            local frame = view.draw(90, 18, appearance.defaults(), state, 0)
            local rendered = table.concat(frame.rows, "\n")
            test.is_true(rendered:find("2.0.0", 1, true) ~= nil)
            test.is_true(rendered:find("staged", 1, true) ~= nil)
            test.is_true(rendered:find("pending", 1, true) ~= nil)
            test.is_true(rendered:find("no", 1, true) ~= nil)
        end)

        test.it("shows available versions with an explicit local Stage action", function()
            local state = model.new("workspace-destination")
            local digest = string.rep("a", 64)
            model.apply_available(state, {ok = true, error = nil, replayed = false, value = {
                workspace_id = "workspace-destination", versions = {{schema = "bee.sync-version@1",
                    owner_id = "node-source", feed = "governance.application_versions", key = "version-key",
                    object_id = "sample/app", version_id = "2.0.0", content_digest = digest,
                    manifest_digest = digest, content_kind = "bee.governance-application-version@2",
                    total_bytes = 2048, manifest = {schema_revision = "bee.governance-application-version@2",
                        source_workspace = "example-app", component = "sample/app", artifact_digest = digest},
                    digest = digest}}}})
            local frame = view.draw(90, 18, appearance.defaults(), state, 0)
            local rendered = table.concat(frame.rows, "\n")
            test.is_true(rendered:find("sample/app", 1, true) ~= nil)
            test.is_true(rendered:find("2.0.0", 1, true) ~= nil)
            test.is_true(rendered:find("available", 1, true) ~= nil)
            test.is_true(rendered:find("S Stage", 1, true) ~= nil)
            test.is_true(rendered:find("does not install", 1, true) ~= nil)
        end)

        test.it("fills every compact canvas without leaking control text", function()
            local state = model.new("workspace-destination")
            state.notice = "unsafe \27[31m notice \7"
            for _, width in ipairs({1, 12, 40, 100}) do
                for _, height in ipairs({1, 3, 8, 24}) do
                    local frame = view.draw(width, height, appearance.defaults(), state, 0)
                    test.eq(#frame.rows, height)
                    for _, row in ipairs(frame.rows) do
                        test.eq(tty.text.width(row), width)
                        test.is_nil(row:find("\27[31m", 1, true))
                        test.is_nil(row:find("\7", 1, true))
                    end
                end
            end
        end)
    end)
end

return test.run_cases(define_tests)
