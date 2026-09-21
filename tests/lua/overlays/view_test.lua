-- MIT. Overlays frames remain bounded and distinguish available from selected.
local test = require("test")
local tty = require("tty")
local model = require("model")
local view = require("view")
local appearance = require("appearance")
local preflight = require("preflight")

local function define_tests()
    test.describe("Overlays frame", function()
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
            local kind, label, enabled = view.primary(state)
            test.eq(kind, "read")
            test.eq(label, " Read review ")
            test.is_true(enabled)
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
            test.is_true(rendered:find("Stage", 1, true) ~= nil)
            test.is_true(rendered:find("does not install", 1, true) ~= nil)
            local found = false
            for _, hit in ipairs(frame.hits) do if hit.kind == "stage" then found = true end end
            test.is_true(found)
        end)

        test.it("shows the verdict, its diagnostics and the entry set the plan changes", function()
            local state = model.new("workspace-destination")
            local digest = string.rep("a", 64)
            local bytes, measured = preflight.encode_report({schema_revision = "bee.governance-preflight@1",
                plan_digest = digest, destination_node = "node-destination", base_revision = 7,
                policy_digest = digest, ready = false,
                diagnostics = {{code = "DANGLING_REFERENCE", target = "demo:run",
                    message = "missing final-state target demo:absent", remedy = "repair the reference"}},
                pending_migrations = {}})
            if not bytes or not measured then error("valid preflight report fixture was rejected") end
            local row: {[string]: unknown} = {owner_node = "node-destination",
                workspace_id = "workspace-destination", source_node = "node-source",
                source_workspace = "example-app", version = "2.0.0", plan_digest = digest,
                candidate_digest = digest, artifact_digest = digest, preflight_digest = measured,
                revision = 1, status = "staged", selected = false}
            model.toggle_pane(state)
            model.apply_list(state, {ok = true, error = nil, replayed = false, value = {owner_node = "node-destination",
                workspace_id = "workspace-destination", plans = {row}}})
            local detail: {[string]: unknown} = {}
            for key, value in pairs(row) do detail[key] = value end
            detail.preflight_bytes = bytes
            model.apply_plan(state, {ok = true, error = nil, replayed = false, value = detail})
            model.toggle_pane(state)
            test.eq(state.pane, "review")
            local frame = view.draw(100, 26, appearance.defaults(), state, 0)
            local rendered = table.concat(frame.rows, "\n")
            test.is_true(rendered:find("Verdict blocked", 1, true) ~= nil)
            test.is_true(rendered:find("DANGLING_REFERENCE  demo:run", 1, true) ~= nil)
            test.is_true(rendered:find("missing final-state target demo:absent", 1, true) ~= nil)
            test.is_true(rendered:find("Entry changes unread", 1, true) ~= nil)
            test.is_true(rendered:find("unbound", 1, true) ~= nil)
        end)

        test.it("fills every compact canvas without leaking control text", function()
            local state = model.new("workspace-destination")
            state.notice = "unsafe \27[31m notice \7"
            for _ = 1, 3 do
            model.toggle_pane(state)
            for _, width in ipairs({1, 12, 40, 100}) do
                for _, height in ipairs({1, 3, 8, 24}) do
                    local frame = view.draw(width, height, appearance.defaults(), state, 0)
                    test.eq(#frame.rows, height)
                    for _, row in ipairs(frame.rows) do
                        test.eq(tty.text.width(row), width)
                        test.is_nil(row:find("\27[31m", 1, true))
                        test.is_nil(row:find("\7", 1, true))
                    end
                    for _, hit in ipairs(frame.hits) do
                        test.is_true(hit.x >= 1 and hit.y >= 1)
                        test.is_true(hit.x + hit.width - 1 <= width)
                        test.is_true(hit.y + hit.height - 1 <= height)
                    end
                end
            end
            end
        end)

        test.it("offers one contextual next transition while keeping advanced recovery in details", function()
            local state = model.new("workspace-destination")
            local digest = string.rep("a", 64)
            local report, report_digest = preflight.encode_report({schema_revision = "bee.governance-preflight@1",
                plan_digest = digest, destination_node = "node-destination", base_revision = 7,
                policy_digest = digest, ready = true, diagnostics = {}, pending_migrations = {}})
            if not report or not report_digest then error("valid ready preflight report was rejected") end
            model.toggle_pane(state)
            model.apply_list(state, {ok = true, error = nil, replayed = false, value = {
                owner_node = "node-destination", workspace_id = "workspace-destination", plans = {{
                    owner_node = "node-destination", workspace_id = "workspace-destination", source_node = "node-source",
                    source_workspace = "example-app", version = "2.0.0", plan_digest = digest,
                    candidate_digest = digest, artifact_digest = digest, preflight_digest = report_digest,
                    revision = 2, status = "reviewed", review_status = "accepted", selected = false}}}})
            local detail = state.plans[1]
            detail.preflight_bytes = report
            model.apply_plan(state, {ok = true, error = nil, replayed = false, value = detail})
            model.show_pane(state, "review")
            local kind, _, enabled = view.primary(state)
            test.eq(kind, "select"); test.is_true(enabled)
            state.plans[1].selected = true
            kind, _, enabled = view.primary(state)
            test.eq(kind, "prepare"); test.is_true(enabled)
            test.is_true(model.apply_activation(state, {ok = true, error = nil, replayed = false, value = {
                owner_node = "node-destination", workspace_id = "workspace-destination", intent_id = "intent-1",
                overlay_owner = "overlay-owner", source_node = "node-source", source_workspace = "example-app",
                version = "2.0.0", phase = "authorized", revision = 1}}))
            kind, _, enabled = view.primary(state)
            test.eq(kind, "step"); test.is_true(enabled)
            local ordinary = view.draw(80, 18, appearance.defaults(), state, 0)
            local ordinary_kinds: {[string]: boolean} = {}
            for _, hit in ipairs(ordinary.hits) do ordinary_kinds[hit.kind] = true end
            test.is_true(ordinary_kinds.step)
            test.is_false(ordinary_kinds.recover == true)
            model.toggle_technical(state)
            local detailed = view.draw(80, 18, appearance.defaults(), state, 0)
            local detailed_kinds: {[string]: boolean} = {}
            for _, hit in ipairs(detailed.hits) do detailed_kinds[hit.kind] = true end
            test.is_true(detailed_kinds.recover and detailed_kinds.status)
        end)
    end)
end

return test.run_cases(define_tests)
