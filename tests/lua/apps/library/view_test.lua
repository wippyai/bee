-- MIT. Library frames stay bounded, name statuses in person words only, and keep
-- technical words in the details view.
local test = require("test")
local tty = require("tty")
local model = require("model")
local governed = require("governed")
local hub = require("hub")
local view = require("view")
local contents = require("contents")
local appearance = require("appearance")
local preflight = require("preflight")

local WORKSPACE = "workspace-destination"
local NODE = "node-destination"
local DIGEST = string.rep("a", 64)

local function reply(value: unknown): governed.Reply
    local result = governed.reply({ok = true, value = value, replayed = false})
    if not result then error("valid fixture reply was rejected") end
    return result
end

local function hub_reply(value: unknown): hub.Reply
    return {ok = true, code = nil, message = nil, value = value, replayed = false}
end

local function ui(offset: integer?): view.Ui
    return {offset = offset or 0, status = "", reading = false, editor = nil, content = contents.new()}
end

local function plain(rows: {string}): {string}
    local result: {string} = {}
    for index, row in ipairs(rows) do result[index] = row:gsub("\27%[[0-9;]*m", "") end
    return result
end

local function fresh(): model.State
    local state = model.new(WORKSPACE)
    test.is_true(governed.apply_list(state.governed, reply({owner_node = NODE, workspace_id = WORKSPACE, plans = {}})))
    return state
end

local function version(source_workspace: string, release: string, owner: string): {[string]: unknown}
    return {schema = "bee.sync-version@1", owner_id = owner, feed = "governance.application_versions",
        key = "key-" .. source_workspace .. "-" .. release, object_id = "app." .. source_workspace, version_id = release,
        content_digest = DIGEST, manifest_digest = DIGEST, content_kind = "bee.governance-application-version@2",
        total_bytes = 2048, manifest = {schema_revision = "bee.governance-application-version@2",
            source_workspace = source_workspace, component = "app." .. source_workspace, artifact_digest = DIGEST},
        digest = DIGEST}
end

local function plan_row(source_workspace: string, release: string, status: string, owner: string, preflight_digest: string): {[string]: unknown}
    local value: {[string]: unknown} = {owner_node = NODE, workspace_id = WORKSPACE, source_node = owner,
        source_workspace = source_workspace, version = release, plan_digest = DIGEST, candidate_digest = DIGEST,
        artifact_digest = DIGEST, preflight_digest = preflight_digest, revision = 2, status = status, selected = false}
    if status == "reviewed" then value.review_status = "accepted"; value.reviewer_id = "reviewer" end
    return value
end

local function report(ready: boolean, migrations: {string}?): (string, string)
    local diagnostics: {unknown} = {}
    if not ready then
        diagnostics[1] = {code = "DANGLING_REFERENCE", target = "demo:run",
            message = "missing final-state target demo:absent", remedy = "repair the reference"}
    end
    local bytes, measured = preflight.encode_report({schema_revision = "bee.governance-preflight@1",
        plan_digest = DIGEST, destination_node = NODE, base_revision = 7, policy_digest = DIGEST, ready = ready,
        diagnostics = diagnostics, pending_migrations = migrations or {}})
    if not bytes or not measured then error("valid preflight report fixture was rejected") end
    return bytes, measured
end

-- A shared version staged with its checks read, ready to open on its screen.
local function staged(source_workspace: string, release: string, ready: boolean, status: string?, migrations: {string}?): model.State
    local state = fresh()
    local bytes, measured = report(ready, migrations)
    test.is_true(governed.apply_available(state.governed, reply({workspace_id = WORKSPACE,
        versions = {version(source_workspace, release, "node-laptop")}})))
    local row = plan_row(source_workspace, release, status or "staged", "node-laptop", measured)
    test.is_true(governed.apply_list(state.governed, reply({owner_node = NODE, workspace_id = WORKSPACE, plans = {row}})))
    local detail: {[string]: unknown} = {}
    for key, value in pairs(row) do detail[key] = value end
    detail.preflight_bytes = bytes
    governed.select(state.governed, governed.key(state.governed.plans[1]))
    test.is_true(governed.apply_plan(state.governed, reply(detail)))
    model.show_tab(state, "shared")
    model.show_version(state, true)
    return state
end

type frame_button = {kind: string, enabled: boolean, primary: boolean?}

local function kinds(hits: {{kind: string}}): {[string]: boolean}
    local found: {[string]: boolean} = {}
    for _, hit in ipairs(hits) do found[hit.kind] = true end
    return found
end

local function define_tests()
    test.describe("Library frame", function()
        test.it("scrolls the entire catalog failure in Technical", function()
            local state = fresh()
            state.governed.technical = true
            state.governed.fault = string.rep("unavailable ", 100) .. "\nreason-end"
            local shown = view.draw(40, 18, appearance.defaults(), state, ui(999))
            test.is_true(table.concat(shown.rows, "\n"):find("reason-end", 1, true) ~= nil)
            test.is_true(shown.offset > 0)
        end)
        test.it("shows an empty list's failure in Technical with available actions", function()
            local state = fresh()
            state.governed.technical, state.governed.fault = true, "UNAVAILABLE: owner call failed"
            state.notice = state.governed.fault
            local shown = view.draw(160, 45, appearance.defaults(), state, ui())
            test.is_true(table.concat(shown.rows, "\n"):find("Last result: UNAVAILABLE: owner call failed", 1, true) ~= nil)
            test.is_true(#shown.hits > 3)
        end)

        test.it("reads a version an update replaced as replaced and keeps Removed for removals", function()
            local state = fresh()
            test.is_true(governed.apply_activations(state.governed, reply({workspace_id = WORKSPACE, activations = {
                {owner_node = NODE, workspace_id = WORKSPACE, intent_id = "i2", overlay_owner = "owner-tasks", source_node = NODE,
                    source_workspace = "tasks", version = "1.0.1", revision = 3, phase = "settled", outcome = "applied",
                    observed_intent_id = "i2", observed_outcome = "applied"},
                {owner_node = NODE, workspace_id = WORKSPACE, intent_id = "i1", overlay_owner = "owner-tasks", source_node = NODE,
                    source_workspace = "tasks", version = "1.0.0", revision = 3, phase = "settled", outcome = "applied",
                    observed_intent_id = "i2", observed_outcome = "applied"}}})))
            model.show_tab(state, "history")
            local rendered = table.concat(plain(view.draw(100, 18, appearance.defaults(), state, ui()).rows), "\n")
            test.is_true(rendered:find("Tasks  ", 1, true) ~= nil)
            test.is_true(rendered:find("Replaced by 1.0.1", 1, true) ~= nil)
            test.is_false(rendered:find("Removed", 1, true) ~= nil)
        end)

        test.it("keeps internal workflow words off a shared version's Details until Technical", function()
            local state = fresh()
            test.is_true(governed.apply_available(state.governed, reply({workspace_id = WORKSPACE,
                versions = {version("tally", "2.0.0", "node-laptop")}})))
            model.show_tab(state, "shared")
            model.show_version(state, true)
            local rendered = table.concat(plain(view.draw(100, 24, appearance.defaults(), state, ui()).rows), "\n")
            for _, internal in ipairs({"Accept", "Reject", "Select", "Prepare", "staged", "Apply", "Recover"}) do
                test.is_false(rendered:find(internal, 1, true) ~= nil, internal)
            end
            test.is_true(rendered:find("Install", 1, true) ~= nil)
            test.is_true(rendered:find("Technical", 1, true) ~= nil)
        end)

        test.it("shows Bee's full version in the Installed table", function()
            local state = fresh()
            hub.apply_installed(state.hub, hub_reply({modules = {
                {component = "bee/bee", version = "0.2.0-alpha.8", source = "hub", direct = true, used_by = {}}}, roots = {}}))
            local rendered = table.concat(plain(view.draw(100, 18, appearance.defaults(), state, ui()).rows), "\n")
            test.is_true(rendered:find("0.2.0-alpha.8", 1, true) ~= nil)
            test.is_false(rendered:find("…", 1, true) ~= nil)
        end)

        test.it("shows a shared version as shared and never as installed", function()
            local state = fresh()
            test.is_true(governed.apply_available(state.governed, reply({workspace_id = WORKSPACE,
                versions = {version("tally", "2.0.0", "node-laptop")}})))
            test.is_true(governed.apply_list(state.governed, reply({owner_node = NODE, workspace_id = WORKSPACE,
                plans = {plan_row("tally", "2.0.0", "staged", "node-laptop", DIGEST)}})))
            model.show_tab(state, "shared")
            local rendered = table.concat(view.draw(90, 18, appearance.defaults(), state, ui()).rows, "\n")
            test.is_true(rendered:find("Tally", 1, true) ~= nil)
            test.is_true(rendered:find("2.0.0", 1, true) ~= nil)
            test.is_true(rendered:find("Shared", 1, true) ~= nil)
            test.is_true(rendered:find("from bee node-laptop", 1, true) ~= nil)
            test.is_true(rendered:find("Installed  ", 1, true) == nil)
            test.is_true(rendered:find("staged", 1, true) == nil)
        end)

        test.it("keeps Help visible at 80 columns and names an empty tab's next action once", function()
            local state = fresh()
            local drawn = view.draw(80, 24, appearance.defaults(), state, ui())
            local rows = plain(drawn.rows)
            test.is_true(rows[1]:find("LIBRARY", 1, true) ~= nil)
            test.is_true(rows[1]:find("0 installed · 0 shared", 1, true) ~= nil)
            test.is_true(rows[2]:find("Installed", 1, true) ~= nil and rows[2]:find("Shared", 1, true) ~= nil and rows[2]:find("History", 1, true) ~= nil)
            test.is_true(rows[4]:find("Nothing installed yet", 1, true) ~= nil)
            test.is_true(rows[5]:find("Install something from Shared", 1, true) ~= nil)
            test.contains(view.draw(160, 24, appearance.defaults(), state, ui()).rows[24], "Tab view · ↑↓ select · Esc close")
            local hinted: {[string]: boolean} = {}
            for _, hint in ipairs(assert(drawn.controls).hints) do hinted[hint.key] = true end
            test.is_true(hinted.Tab and hinted["↑↓"] and hinted.Esc)
            test.is_true(rows[24]:find("? help", 1, true) ~= nil)
            local tabs = 0
            for _, hit in ipairs(drawn.hits) do if view.tab_of(hit.kind) then tabs = tabs + 1 end end
            test.eq(tabs, 3)
        end)

        test.it("offers Install on a shared version and Update on an installed one", function()
            local state = fresh()
            test.is_true(governed.apply_available(state.governed, reply({workspace_id = WORKSPACE,
                versions = {version("tally", "2.0.0", "node-laptop"), version("todo", "1.0.1", "node-laptop")}})))
            test.is_true(governed.apply_activations(state.governed, reply({workspace_id = WORKSPACE, activations = {
                {owner_node = NODE, workspace_id = WORKSPACE, intent_id = "i1", overlay_owner = "owner-todo",
                    source_node = "node-laptop", source_workspace = "todo", version = "1.0.0", revision = 3,
                    phase = "settled", outcome = "applied", observed_intent_id = "i1", observed_outcome = "applied"}}})))
            model.show_tab(state, "shared")
            local shared = view.draw(90, 18, appearance.defaults(), state, ui())
            test.is_true(kinds(shared.hits).install)
            model.show_tab(state, "installed")
            local installed = view.draw(90, 18, appearance.defaults(), state, ui())
            local rendered = table.concat(plain(installed.rows), "\n")
            test.is_true(rendered:find("Update available 1.0.1", 1, true) ~= nil)
            test.is_true(rendered:find("from bee node-laptop", 1, true) ~= nil)
            test.is_true(kinds(installed.hits).update)
            test.is_false(kinds(installed.hits).install == true)
        end)

        test.it("reads a shared version in person words", function()
            local state = staged("tally", "2.0.0", true)
            local rendered = table.concat(plain(view.draw(100, 24, appearance.defaults(), state, ui()).rows), "\n")
            test.is_true(rendered:find("LIBRARY  TALLY", 1, true) ~= nil)
            test.is_true(rendered:find("Status   ⬡ Shared", 1, true) ~= nil)
            test.is_true(rendered:find("Source   from bee node-laptop", 1, true) ~= nil)
            test.is_true(rendered:find("Checks   Passed", 1, true) ~= nil)
            for _, word in ipairs({"overlay", "staged", "preflight", "activation", "destination", "artifact", "digest", "descriptor", "receipt"}) do
                test.is_true(rendered:lower():find(word, 1, true) == nil, word)
            end
        end)

        test.it("shows the verdict, its diagnostics and the entry set only in the details view", function()
            local state = staged("example_app", "2.0.0", false)
            local person = table.concat(plain(view.draw(100, 26, appearance.defaults(), state, ui()).rows), "\n")
            test.is_true(person:find("Checks   Fails 1 check", 1, true) ~= nil)
            test.is_true(person:find("DANGLING_REFERENCE", 1, true) == nil)
            model.toggle_technical(state)
            local rendered = table.concat(view.draw(100, 26, appearance.defaults(), state, ui()).rows, "\n")
            test.is_true(rendered:find("Verdict blocked", 1, true) ~= nil)
            test.is_true(rendered:find("DANGLING_REFERENCE  demo:run", 1, true) ~= nil)
            test.is_true(rendered:find("missing final-state target demo:absent", 1, true) ~= nil)
            test.is_true(rendered:find("Entry changes unread", 1, true) ~= nil)
            test.is_true(rendered:find("unbound", 1, true) ~= nil)
        end)

        test.it("lists each pending migration by its id and the database it changes", function()
            local state = staged("notes", "1.0.0", true, nil, {preflight.migration_key({target_db = "notes", id = "app.notes:create_notes"})})
            model.toggle_technical(state)
            local rendered = table.concat(view.draw(100, 26, appearance.defaults(), state, ui()).rows, "\n")
            test.is_true(rendered:find("PENDING_MIGRATION  app.notes:create_notes on notes", 1, true) ~= nil, rendered)
        end)

        test.it("fills every compact canvas without leaking control text", function()
            local state = fresh()
            state.notice = "unsafe \27[31m notice \7"
            test.is_true(governed.apply_available(state.governed, reply({workspace_id = WORKSPACE,
                versions = {version("tally", "2.0.0", "node-laptop")}})))
            hub.apply_installed(state.hub, hub_reply({modules = {
                {component = "acme/app", version = "1.0.0", source = "hub", direct = true, used_by = {}}}, roots = {}}))
            hub.apply_catalog(state.hub, hub_reply({total = 1, items = {
                {component = "userspace/docker", title = "Docker \27[31m", description = "container \7b", latest_version = "0.5.12"}}}))
            for _, tab in ipairs({"installed", "shared", "history"}) do
                model.show_tab(state, tab :: model.Tab)
                for _, width in ipairs({1, 12, 40, 80, 100, 120}) do
                    for _, height in ipairs({1, 3, 8, 24, 36}) do
                        local frame = view.draw(width, height, appearance.defaults(), state, ui())
                        test.eq(#frame.rows, height)
                        for _, row in ipairs(frame.rows) do
                            test.eq(tty.text.width(row), width)
                            test.is_nil((row:find("\27[31m", 1, true)))
                            test.is_nil((row:find("\7", 1, true)))
                        end
                        for _, hit in ipairs(frame.hits) do
                            test.is_true(hit.x >= 1 and hit.y >= 1)
                            test.is_true(hit.x + hit.width - 1 <= width)
                            test.is_true(hit.y + hit.height - 1 <= height)
                        end
                    end
                end
            end
            local shared = staged("tally", "2.0.0", true)
            shared.notice = "unsafe \27[31m notice \7"
            for _, technical in ipairs({false, true}) do
                if technical then model.toggle_technical(shared) end
                for _, width in ipairs({1, 12, 40, 80, 120}) do
                    for _, height in ipairs({1, 3, 8, 24}) do
                        local frame = view.draw(width, height, appearance.defaults(), shared, ui())
                        test.eq(#frame.rows, height)
                        for _, row in ipairs(frame.rows) do test.eq(tty.text.width(row), width) end
                    end
                end
            end
        end)

        test.it("offers one contextual next move and keeps recovery steps in details", function()
            local state = staged("tally", "2.0.0", true, "reviewed")
            local primary = view.actions(state, model.selected_row(state))[1]
            test.eq(primary.kind, "install")
            test.is_true(primary.primary == true and primary.enabled)
            local ordinary = kinds(view.draw(100, 24, appearance.defaults(), state, ui()).hits)
            test.is_true(ordinary.install and ordinary.technical and ordinary.back)
            for _, hidden in ipairs({"accept", "reject", "select", "prepare", "step", "status", "recover"}) do
                test.is_false(ordinary[hidden] == true, hidden)
            end
            model.toggle_technical(state)
            local detailed = kinds(view.draw(160, 24, appearance.defaults(), state, ui()).hits)
            test.is_true(detailed.select and detailed.recover)
            test.is_false(detailed.accept == true)
            test.is_false(detailed.step == true)
            test.is_false(detailed.prepare == true)
            test.is_true(governed.apply_activation(state.governed, reply({owner_node = NODE, workspace_id = WORKSPACE,
                intent_id = "intent-1", overlay_owner = "owner", source_node = "node-laptop", source_workspace = "tally",
                version = "2.0.0", phase = "authorized", revision = 1})))
            local advancing = {}
            for _, button in ipairs(view.actions(state, model.selected_row(state))) do advancing[button.kind] = button end
            test.is_true(advancing.step.enabled)
            test.is_true(advancing.status.enabled)
        end)

        test.it("does not offer to ask for approval of a locally rejected version", function()
            local state = staged("tally", "2.0.0", true, "reviewed")
            local plan = assert(governed.selected(state.governed))
            plan.review_status = "rejected"
            model.toggle_technical(state)
            for _, button in ipairs(view.actions(state, model.selected_row(state))) do
                if button.kind == "prepare" or button.kind == "select" then test.is_false(button.enabled) end
            end
        end)

        test.it("opens an installed application where it can and removes it only with an earlier version", function()
            local state = fresh()
            local current = {owner_node = NODE, workspace_id = WORKSPACE, intent_id = "i2", overlay_owner = "owner-notes",
                source_node = NODE, source_workspace = "notes", version = "1.0.1", revision = 3, phase = "settled",
                outcome = "applied", observed_intent_id = "i2", observed_outcome = "applied", application = "app.notes:main",
                baseline_intent_id = "i1"}
            local earlier = {owner_node = NODE, workspace_id = WORKSPACE, intent_id = "i1", overlay_owner = "owner-notes",
                source_node = NODE, source_workspace = "notes", version = "1.0.0", revision = 3, phase = "settled",
                outcome = "applied", observed_intent_id = "i2", observed_outcome = "applied"}
            test.is_true(governed.apply_activations(state.governed, reply({workspace_id = WORKSPACE, activations = {current, earlier}})))
            local function buttons(): {[string]: frame_button}
                local found: {[string]: frame_button} = {}
                for _, button in ipairs(view.actions(state, model.selected_row(state))) do found[button.kind] = button end
                return found
            end
            test.is_false(buttons().launch.enabled)
            state.can_open = true
            local ready = buttons()
            test.is_true(ready.launch.enabled and ready.launch.primary == true)
            test.is_true(ready.remove.enabled and ready.go_back.enabled and ready.open.enabled)
            test.is_true(kinds(view.draw(100, 24, appearance.defaults(), state, ui()).hits).launch)
            local first = {}
            for key, value in pairs(current) do first[key] = value end
            first.baseline_intent_id = nil
            test.is_true(governed.apply_activations(state.governed, reply({workspace_id = WORKSPACE, activations = {first, earlier}})))
            local first_version = buttons()
            test.is_true(first_version.remove.enabled)
            test.is_false(first_version.go_back.enabled)
        end)

        test.it("asks before removing, names what goes and what stays, and takes every click", function()
            local state = fresh()
            local current = {owner_node = NODE, workspace_id = WORKSPACE, intent_id = "i2", overlay_owner = "owner-notes",
                source_node = NODE, source_workspace = "notes", version = "1.0.1", revision = 3, phase = "settled",
                outcome = "applied", observed_intent_id = "i2", observed_outcome = "applied", baseline_intent_id = "i1"}
            local earlier = {owner_node = NODE, workspace_id = WORKSPACE, intent_id = "i1", overlay_owner = "owner-notes",
                source_node = NODE, source_workspace = "notes", version = "1.0.0", revision = 3, phase = "settled",
                outcome = "applied", observed_intent_id = "i2", observed_outcome = "applied"}
            test.is_true(governed.apply_activations(state.governed, reply({workspace_id = WORKSPACE, activations = {current, earlier}})))
            test.is_true(model.ask_remove(state, model.selected_row(state), "back"))
            for _, size in ipairs({{100, 24}, {60, 16}, {30, 12}}) do
                local drawn = view.draw(size[1], size[2], appearance.defaults(), state, ui())
                test.not_nil(drawn.controls)
                if drawn.controls then
                    test.eq(#drawn.controls.buttons, 2)
                    test.eq(drawn.controls.buttons[1].kind, "confirm_remove")
                    test.eq(drawn.controls.buttons[2].kind, "cancel_remove")
                end
                test.eq(#drawn.rows, size[2])
                for _, row in ipairs(drawn.rows) do test.eq(tty.text.width(row), size[1]) end
                for _, hit in ipairs(drawn.hits) do
                    test.is_true(hit.kind == "confirm_remove" or hit.kind == "cancel_remove" or hit.kind == "frame_help" or hit.kind == "frame_more")
                    test.eq(hit.y, size[2])
                    test.is_true(hit.x + hit.width - 1 <= size[1] and hit.y + hit.height - 1 <= size[2])
                end
            end
            local drawn = view.draw(100, 24, appearance.defaults(), state, ui())
            local text = table.concat(plain(drawn.rows), "\n")
            test.is_true(text:find("Go back to Notes 1.0.0?", 1, true) ~= nil)
            test.is_true(text:find("goes back to 1.0.0", 1, true) ~= nil)
            test.is_true(text:find("saved stays", 1, true) ~= nil)
            local found = kinds(drawn.hits)
            test.is_true(found.confirm_remove and found.cancel_remove)
            model.cancel_remove(state)
            test.is_true(model.ask_remove(state, model.selected_row(state), "remove"))
            local removing = table.concat(plain(view.draw(100, 24, appearance.defaults(), state, ui()).rows), "\n")
            test.is_true(removing:find("Remove Notes 1.0.1?", 1, true) ~= nil)
            test.is_true(removing:find("nothing is deleted", 1, true) ~= nil)
            model.cancel_remove(state)
            test.is_false(kinds(view.draw(100, 24, appearance.defaults(), state, ui()).hits).confirm_remove == true)
        end)

        test.it("draws each row's kind and status as glyphs and the platform as one row", function()
            local state = fresh()
            local notes = {owner_node = NODE, workspace_id = WORKSPACE, intent_id = "i2", overlay_owner = "owner-notes",
                source_node = NODE, source_workspace = "notes", version = "1.0.1", revision = 3, phase = "settled",
                outcome = "applied", observed_intent_id = "i2", observed_outcome = "applied", title = "Notes"}
            local stub = {owner_node = NODE, workspace_id = WORKSPACE, intent_id = "i3", overlay_owner = "bee.gov.drivers:w.stub",
                source_node = NODE, source_workspace = "driver_stub", version = "0.2.0", revision = 1, phase = "approval_bound"}
            test.is_true(governed.apply_activations(state.governed, reply({workspace_id = WORKSPACE, activations = {notes, stub}})))
            local modules: {{[string]: unknown}} = {{component = "bee/bee", version = "0.2.0-dev", source = "hub", direct = true, used_by = {}}}
            for _, name in ipairs({"bootloader", "migration", "security", "terminal", "test"}) do
                modules[#modules + 1] = {component = "wippy/" .. name, version = "1.0.0", source = "hub", direct = false, used_by = {"bee/bee"}}
            end
            hub.apply_installed(state.hub, hub_reply({modules = modules, roots = {}}))
            local text = table.concat(plain(view.draw(120, 36, appearance.defaults(), state, ui()).rows), "\n")
            test.is_true(text:find("▣ Notes", 1, true) ~= nil, text)
            test.is_true(text:find("✓ Installed", 1, true) ~= nil)
            test.is_true(text:find("⌁ Driver stub", 1, true) ~= nil)
            test.is_true(text:find("◷ Waiting for your approval", 1, true) ~= nil)
            test.is_true(text:find("◫ Bee", 1, true) ~= nil)
            test.is_true(text:find("0.2.0-dev", 1, true) ~= nil)
            test.is_true(text:find("built in · 6 packages", 1, true) ~= nil)
            for _, word in ipairs({"wippy/bootloader", "wippy/migration", "wippy/security", "wippy/terminal", "wippy/test", "needed by"}) do
                test.is_true(text:find(word, 1, true) == nil, word)
            end
            test.is_true(model.rows(state, "installed")[3].kind == "platform")
            for _, line in ipairs(plain(view.draw(120, 36, appearance.defaults(), state, ui()).rows)) do
                test.is_true(tty.text.width(line) == 120)
            end
        end)

        test.it("opens the platform on its own screen and never offers to remove it", function()
            local state = fresh()
            hub.apply_installed(state.hub, hub_reply({modules = {
                {component = "bee/bee", version = "0.2.0-dev", source = "hub", direct = true, used_by = {}},
                {component = "wippy/bootloader", version = "1.0.0", source = "hub", direct = false, used_by = {"bee/bee"}},
                {component = "userspace/editor", version = "1.0.0", source = "hub", direct = true, used_by = {"userspace/suite"}},
                {component = "userspace/calc", version = "1.0.0", source = "hub", direct = true, used_by = {}}}, roots = {}}))
            local function remove_enabled(): boolean
                for _, button in ipairs(view.actions(state, model.selected_row(state))) do
                    if button.kind == "remove" and button.enabled then return true end
                end
                return false
            end
            local rows = model.rows(state, "installed")
            model.select(state, rows[1].key)
            test.is_true(remove_enabled())
            model.select(state, rows[2].key)
            test.is_false(remove_enabled())
            model.select(state, rows[3].key)
            test.eq(rows[3].kind, "platform")
            test.is_false(remove_enabled())
            local primary = view.actions(state, model.selected_row(state))[1]
            test.eq(primary.kind, "platform")
            model.show_platform(state, true)
            test.eq(view.screen(state), "platform")
            local screen = table.concat(plain(view.draw(120, 36, appearance.defaults(), state, ui()).rows), "\n")
            test.is_true(screen:find("LIBRARY  BEE", 1, true) ~= nil)
            test.is_true(screen:find("◫ wippy/bootloader", 1, true) ~= nil)
            test.is_true(screen:find("◫ bee/bee", 1, true) ~= nil)
            test.is_true(screen:find("userspace/calc", 1, true) == nil)
            model.show_platform(state, false)
            test.eq(view.screen(state), "list")
        end)

        test.it("shows a Hub application directly with its description and Install action", function()
            local state = fresh()
            hub.apply_catalog(state.hub, hub_reply({total = 45, items = {
                {component = "kickside/core", title = "Kickside Core", description = "Inbox application", latest_version = "0.1.126", application = true}}}))
            model.show_tab(state, "shared")
            local rows = model.rows(state, "shared")
            test.eq(#rows, 1)
            test.eq(rows[1].kind, "app")
            local primary = view.actions(state, rows[1])[1]
            test.eq(primary.kind, "install")
            local text = table.concat(plain(view.draw(100, 24, appearance.defaults(), state, ui()).rows), "\n")
            test.is_true(text:find("Inbox application", 1, true) ~= nil)
            test.is_true(text:find("0.1.126", 1, true) ~= nil)
            test.is_true(text:find("Kickside Core", 1, true) ~= nil)
        end)

        test.it("keeps the list title whole when an installed name is long and marks the selected one", function()
            local state = fresh()
            local long = "acme/" .. string.rep("very-long-package-name-", 4)
            hub.apply_installed(state.hub, hub_reply({modules = {
                {component = "acme/app", version = "1.0.0", source = "hub", direct = true, used_by = {}},
                {component = long, version = "2.0.0", source = "hub", direct = true, used_by = {}},
            }, roots = {}}))
            model.select(state, "h:" .. long)
            local rows = plain(view.draw(60, 18, appearance.defaults(), state, ui()).rows)
            test.eq(rows[1]:sub(1, 8), " LIBRARY")
            test.is_true(rows[1]:find("2 installed", 1, true) ~= nil)
            local marked = 0
            for _, row in ipairs(rows) do
                if row:sub(1, #"›") == "›" then marked = marked + 1; test.is_true(row:find("very-long", 1, true) ~= nil) end
            end
            test.eq(marked, 1)
            local wide = view.draw(160, 18, appearance.defaults(), state, ui())
            test.contains(wide.rows[18], "↑↓ select")
            test.contains(rows[18], "Enter Details")
        end)

        test.it("offers no publication from installed Hub packages", function()
            local state = fresh()
            hub.apply_installed(state.hub, hub_reply({modules = {
                {component = "acme/app", version = "1.0.0", source = "hub", direct = true, used_by = {}},
                {component = "acme/lib", version = "1.0.0", source = "hub", direct = false, used_by = {"acme/app"}},
            }, roots = {}}))
            local installed = view.draw(80, 18, appearance.defaults(), state, ui())
            for _, hit in ipairs(installed.hits) do test.is_true(hit.kind ~= "publish") end
        end)

        test.it("keeps installed dependencies readable and reachable after scrolling", function()
            local state = fresh()
            local modules: {{[string]: unknown}} = {}
            for index = 1, 20 do
                modules[index] = {component = "bee/package" .. tostring(index), version = "1.0.0", source = "hub", direct = true,
                    used_by = {}}
            end
            hub.apply_installed(state.hub, hub_reply({modules = modules, roots = {}}))
            model.select(state, "h:bee/package20")
            for _, width in ipairs({24, 48, 80}) do
                local frame = view.draw(width, 18, appearance.defaults(), state, ui(999))
                local found = false
                for _, hit in ipairs(frame.hits) do
                    if hit.kind == "row" and hit.key == "h:bee/package20" then found = true end
                    test.is_true(hit.x + hit.width - 1 <= width and hit.y + hit.height - 1 <= 18)
                end
                test.is_true(found)
            end
        end)

        test.it("lists Hub applications before developer packages with the filter and its empty state", function()
            local state = fresh()
            hub.apply_installed(state.hub, hub_reply({modules = {
                {component = "bee/terminal", version = "0.4.6", source = "builtin", direct = true, used_by = {}},
                {component = "userspace/calc", version = "1.0.0", source = "hub", direct = true, used_by = {}},
            }, roots = {}}))
            hub.apply_catalog(state.hub, hub_reply({total = 5, items = {
                {component = "wippy/test", title = "Test Framework", description = "BDD framework", latest_version = "0.4.19", application = false},
                {component = "wippy/terminal", title = "Terminal", description = "Terminal library components", latest_version = "0.4.6", application = false},
                {component = "userspace/editor", title = "Editor", description = "Text editor app", latest_version = "2.0.0", application = true},
                {component = "bee/terminal", title = "Terminal", description = "Workspace terminal console", latest_version = "0.4.6", application = true},
                {component = "userspace/calc", title = "Calculator", description = "Calculator app", latest_version = "1.0.0", application = true},
            }}))
            for _, dims in ipairs({{120, 36}, {80, 24}}) do
                local w, h = dims[1], dims[2]
                model.show_tab(state, "installed")
                local installed = view.draw(w, h, appearance.defaults(), state, ui())
                test.eq(#installed.rows, h)
                local installed_text = table.concat(plain(installed.rows), "\n")
                test.is_true(installed_text:find("◫ Bee", 1, true) ~= nil, installed_text)
                test.is_true(installed_text:find("built in · 1 package", 1, true) ~= nil, installed_text)
                test.is_true(installed_text:find("Calculator", 1, true) ~= nil, installed_text)
                test.is_true(installed_text:find("from Hub", 1, true) ~= nil, installed_text)
                test.is_true(installed_text:find("bee/terminal", 1, true) == nil, installed_text)
                model.show_tab(state, "shared")
                state.hub_open = false
                local collapsed = table.concat(plain(view.draw(w, h, appearance.defaults(), state, ui()).rows), "\n")
                test.is_true(collapsed:find("Hub catalog", 1, true) ~= nil)
                test.is_true(collapsed:find("Editor", 1, true) ~= nil)
                state.hub_open = true
                local shared = view.draw(w, h, appearance.defaults(), state, ui())
                test.eq(#shared.rows, h)
                for _, row in ipairs(shared.rows) do test.eq(tty.text.width(row), w) end
                local text = table.concat(plain(shared.rows), "\n")
                test.is_true(text:find("Editor", 1, true) ~= nil, "missing Editor in " .. tostring(w))
                test.is_true(text:find("2.0.0", 1, true) ~= nil)
                test.is_true(text:find("Test Framework", 1, true) == nil)
                test.is_true(text:find("Developer packages", 1, true) ~= nil, "missing Developer packages in " .. tostring(w))
                local found = kinds(shared.hits)
                test.is_true(found.developer_packages and found.install and found.hub_catalog)
                for _, hit in ipairs(shared.hits) do
                    test.is_true(hit.x >= 1 and hit.y >= 1 and hit.x + hit.width - 1 <= w and hit.y + hit.height - 1 <= h)
                end
            end
            hub.set_developer_packages(state.hub, true)
            local everything = table.concat(plain(view.draw(120, 36, appearance.defaults(), state, ui()).rows), "\n")
            test.is_true(everything:find("Test Framework", 1, true) ~= nil)
            local only_libraries = fresh()
            hub.apply_catalog(only_libraries.hub, hub_reply({total = 1, items = {
                {component = "wippy/test", title = "Test Framework", description = "BDD framework", latest_version = "0.4.19", application = false}}}))
            model.show_tab(only_libraries, "shared")
            only_libraries.hub_open = true
            for _, dims in ipairs({{120, 36}, {80, 24}}) do
                local text = table.concat(plain(view.draw(dims[1], dims[2], appearance.defaults(), only_libraries, ui()).rows), "\n")
                test.is_true(text:find("Only developer packages are shared", 1, true) ~= nil)
                test.is_true(text:find("Developer packages are hidden", 1, true) ~= nil)
            end
        end)

        test.it("filters Hub packages by declared application metadata across arbitrary names", function()
            local state = fresh()
            hub.apply_catalog(state.hub, hub_reply({total = 4, items = {
                {component = "wippy/arbitrary", title = "Library", description = "Framework utilities", latest_version = "1.0.0", application = true},
                {component = "bee/console", title = "App", description = "Application", latest_version = "1.0.0", application = false},
                {component = "acme/editor", title = "Editor", description = "Editor", latest_version = "1.0.0", application = false},
                {component = "wippy/test", title = "Test Framework", description = "Testing library", latest_version = "1.0.0"},
            }}))
            model.show_tab(state, "shared")
            state.hub_open = true
            for _, dimensions in ipairs({{120, 36}, {80, 24}}) do
                local rendered = table.concat(view.draw(dimensions[1], dimensions[2], appearance.defaults(), state, ui()).rows, "\n")
                test.is_true(rendered:find("wippy/arbitrary", 1, true) ~= nil or rendered:find("Library", 1, true) ~= nil)
                test.is_true(rendered:find("Test Framework", 1, true) == nil)
                test.is_true(rendered:find("Editor", 1, true) == nil)
                test.is_true(rendered:find("bee/console", 1, true) == nil)
            end
            hub.set_developer_packages(state.hub, true)
            for _, dimensions in ipairs({{120, 36}, {80, 24}}) do
                local rendered = table.concat(view.draw(dimensions[1], dimensions[2], appearance.defaults(), state, ui()).rows, "\n")
                for _, name in ipairs({"Library", "App", "Editor", "Test Framework"}) do
                    test.is_true(rendered:find(name, 1, true) ~= nil, name)
                end
            end
        end)

        test.it("renders history with the recorded change, its migration rows and the recovery action", function()
            local state = fresh()
            hub.apply_history(state.hub, hub_reply({page = 1, total = 26, page_size = 25, operations = {
                {digest = string.rep("f", 64), component = "bee/recover", action = "update",
                    state = "recovery_required", message = "migration paused", baseline_revision = 8,
                    request = {action = "update", component = "bee/recover", version = "2.0.0", parameters = {}, migration_policy = "up"},
                    migration_work = {rows = {{id = "bee.recover:01", target_db = "app:db", module = "bee/recover", status = "applied"}}}}}}))
            model.show_tab(state, "history")
            local selected, problem = hub.select_operation(state.hub, string.rep("f", 64))
            test.not_nil(selected)
            test.is_nil(problem)
            local person = view.draw(100, 24, appearance.defaults(), state, ui())
            local person_text = table.concat(person.rows, "\n")
            test.is_true(person_text:find("bee/recover", 1, true) ~= nil)
            test.is_true(person_text:find("needs to be finished", 1, true) ~= nil)
            test.is_true(person_text:find("bee.recover:01", 1, true) == nil)
            test.is_true(kinds(person.hits).recover)
            model.toggle_technical(state)
            local detailed = table.concat(view.draw(100, 24, appearance.defaults(), state, ui()).rows, "\n")
            test.is_true(detailed:find("bee.recover:01", 1, true) ~= nil)
            test.is_nil(hub.recover(state.hub))
            local review = view.draw(100, 24, appearance.defaults(), state, ui())
            test.eq(view.screen(state), "package")
            test.is_true(table.concat(review.rows, "\n"):find("Finish an interrupted change", 1, true) ~= nil)
        end)

        test.it("scrolls through every row of a full history page", function()
            local state = fresh()
            local operations: {{[string]: unknown}} = {}
            for index = 1, 25 do
                operations[index] = {digest = string.format("%064x", index), component = "bee/package" .. tostring(index),
                    action = "install", state = "complete", message = "done", baseline_revision = index}
            end
            hub.apply_history(state.hub, hub_reply({page = 1, total = 25, page_size = 25, operations = operations}))
            model.show_tab(state, "history")
            local first = view.draw(100, 12, appearance.defaults(), state, ui())
            test.is_true(table.concat(first.rows, "\n"):find("bee/package25", 1, true) ~= nil)
            test.is_true(table.concat(first.rows, "\n"):find("bee/package1 ", 1, true) == nil)
            model.select(state, "h:op:" .. string.format("%064x", 1))
            local last = view.draw(100, 12, appearance.defaults(), state, ui(24))
            test.is_true(table.concat(last.rows, "\n"):find("bee/package1 ", 1, true) ~= nil)
            test.is_true(table.concat(last.rows, "\n"):find("bee/package25", 1, true) == nil)
        end)

        test.it("opens the package screens inside the Library tabs", function()
            local state = fresh()
            hub.select(state.hub, "bee/example")
            hub.apply_details(state.hub, hub_reply({component = "bee/example", title = "Example", description = "Package",
                readme = "Guide", versions = {{version = "1.0.0", yanked = false}}, page = 1, total_versions = 1}))
            test.eq(view.screen(state), "package")
            local rows = plain(view.draw(100, 24, appearance.defaults(), state, ui()).rows)
            test.is_true(rows[1]:find("LIBRARY  PACKAGE", 1, true) ~= nil)
            test.is_true(rows[2]:find("Installed", 1, true) ~= nil and rows[2]:find("History", 1, true) ~= nil)
        end)
    end)
end

return test.run_cases(define_tests)
