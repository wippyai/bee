-- MIT. The Library folds governed versions and Hub packages into one list per tab
-- and names every row's status in the person-facing vocabulary only.
local test = require("test")
local model = require("model")
local governed = require("governed")
local hub = require("hub")

local WORKSPACE = "workspace-destination"
local NODE = "node-destination"

local function reply(value: unknown): governed.Reply
    local result = governed.reply({ok = true, value = value, replayed = false})
    if not result then error("valid fixture reply was rejected") end
    return result
end

local function hub_reply(value: unknown): hub.Reply
    return {ok = true, code = nil, message = nil, value = value, replayed = false}
end

local function version(source_workspace: string, release: string, owner: string): {[string]: unknown}
    return {schema = "bee.sync-version@1", owner_id = owner, feed = "governance.application_versions",
        key = "key-" .. source_workspace .. "-" .. release, object_id = "app." .. source_workspace, version_id = release,
        content_digest = string.rep("a", 64), manifest_digest = string.rep("b", 64),
        content_kind = "bee.governance-application-version@2", total_bytes = 2048,
        manifest = {schema_revision = "bee.governance-application-version@2", source_workspace = source_workspace,
            component = "app." .. source_workspace, artifact_digest = string.rep("c", 64)}, digest = string.rep("d", 64)}
end

local function activation(id: string, source_workspace: string, release: string, phase: string, outcome: string?,
    observed: string?, source_node: string?): {[string]: unknown}
    return {owner_node = NODE, workspace_id = WORKSPACE, intent_id = id, overlay_owner = "owner-" .. source_workspace,
        source_node = source_node or NODE, source_workspace = source_workspace, version = release, revision = 3,
        phase = phase, outcome = outcome, observed_intent_id = observed,
        observed_outcome = observed and "applied" or nil}
end

local function fresh(): model.State
    local state = model.new(WORKSPACE)
    test.is_true(governed.apply_list(state.governed, reply({owner_node = NODE, workspace_id = WORKSPACE, plans = {}})))
    return state
end

local function load(state: model.State, available: {unknown}, activations: {unknown})
    test.is_true(governed.apply_available(state.governed, reply({workspace_id = WORKSPACE, versions = available})))
    test.is_true(governed.apply_activations(state.governed, reply({workspace_id = WORKSPACE, activations = activations})))
end

local function define_tests()
    test.describe("Library model", function()
        test.it("speaks only the person-facing status words", function()
            test.eq(model.STATUS_SHARED, "Shared")
            test.eq(model.STATUS_WAITING, "Waiting for your approval")
            test.eq(model.STATUS_INSTALLING, "Installing")
            test.eq(model.STATUS_INSTALLED, "Installed")
            test.eq(model.STATUS_UPDATE, "Update available")
            test.eq(model.STATUS_REMOVED, "Removed")
        end)

        test.it("lists an installed application made on this bee", function()
            local state = fresh()
            load(state, {}, {activation("i1", "notes", "1.0.1", "settled", "applied", "i1")})
            local rows = model.rows(state, "installed")
            test.eq(#rows, 1)
            test.eq(rows[1].name, "Notes")
            test.eq(rows[1].version, "1.0.1")
            test.eq(rows[1].status, "Installed")
            test.eq(rows[1].source, "made on this bee")
            test.eq(model.summary(state), "1 installed · 0 shared")
        end)

        test.it("offers the newer shared version of an installed application as an update", function()
            local state = fresh()
            load(state, {version("todo", "1.0.1", "node-laptop"), version("todo", "0.9.0", "node-laptop")},
                {activation("i1", "todo", "1.0.0", "settled", "applied", "i1", "node-laptop")})
            local rows = model.rows(state, "installed")
            test.eq(#rows, 1)
            test.eq(rows[1].status, "Update available")
            test.eq(rows[1].update, "1.0.1")
            test.eq(rows[1].source, "from bee node-laptop")
            test.eq(#model.rows(state, "shared"), 0)
        end)

        test.it("says an install is waiting for approval, then installing", function()
            local state = fresh()
            load(state, {version("tally", "1.0.0", "node-laptop")}, {activation("i2", "tally", "1.0.0", "approval_bound", nil, nil, "node-laptop")})
            local rows = model.rows(state, "installed")
            test.eq(#rows, 1)
            test.eq(rows[1].status, "Waiting for your approval")
            test.eq(#model.rows(state, "shared"), 0)
            for _, phase in ipairs({"consuming", "authorized", "applying"}) do
                load(state, {}, {activation("i2", "tally", "1.0.0", phase, nil, nil, "node-laptop")})
                test.eq(model.rows(state, "installed")[1].status, "Installing")
            end
        end)

        test.it("keeps the installed version while its update waits for approval", function()
            local state = fresh()
            load(state, {}, {activation("i3", "notes", "1.0.2", "prepared", nil, "i1"),
                activation("i1", "notes", "1.0.1", "settled", "applied", "i1")})
            local rows = model.rows(state, "installed")
            test.eq(#rows, 1)
            test.eq(rows[1].status, "Waiting for your approval")
            test.eq(rows[1].version, "1.0.2")
        end)

        test.it("shares a version another bee made as a row from that bee", function()
            local state = fresh()
            load(state, {version("tally", "1.0.0", "node-laptop"), version("tally", "1.1.0", "node-laptop")}, {})
            local rows = model.rows(state, "shared")
            test.eq(#rows, 1)
            test.eq(rows[1].name, "Tally")
            test.eq(rows[1].version, "1.1.0")
            test.eq(rows[1].status, "Shared")
            test.eq(rows[1].source, "from bee node-laptop")
            test.eq(model.summary(state), "0 installed · 1 shared")
        end)

        test.it("returns a version that could not be installed to Shared", function()
            local state = fresh()
            load(state, {version("tally", "1.0.0", "node-laptop")}, {activation("i4", "tally", "1.0.0", "settled", "failed", nil, "node-laptop")})
            test.eq(#model.rows(state, "installed"), 0)
            test.eq(#model.rows(state, "shared"), 1)
            local history = model.rows(state, "history")
            test.eq(#history, 1)
            test.eq(history[1].status, "Shared")
            test.eq(history[1].note, "could not be installed")
        end)

        test.it("returns a version whose approval expired or was denied to Shared, to install again", function()
            local state = fresh()
            load(state, {version("tally", "1.0.0", "node-laptop"), version("notes", "1.0.0", "node-laptop")},
                {activation("i6", "tally", "1.0.0", "settled", "expired", nil, "node-laptop"),
                    activation("i7", "notes", "1.0.0", "settled", "denied", nil, "node-laptop")})
            test.eq(#model.rows(state, "installed"), 0)
            test.eq(model.summary(state), "0 installed · 2 shared")
            local shared: {[string]: string} = {}
            for _, row in ipairs(model.rows(state, "shared")) do
                test.eq(row.status, "Shared")
                shared[row.name] = row.note
            end
            test.eq(shared["Tally"], "Approval expired — install again")
            test.eq(shared["Notes"], "Denied")
            local history: {[string]: string} = {}
            for _, row in ipairs(model.rows(state, "history")) do history[row.name] = row.note end
            test.eq(history["Tally"], "Approval expired — install again")
            test.eq(history["Notes"], "Denied")
        end)

        test.it("counts only installed versions in the header", function()
            local state = fresh()
            load(state, {}, {activation("i2", "tally", "1.0.0", "approval_bound", nil, nil, "node-laptop"),
                activation("i1", "notes", "1.0.1", "settled", "applied", "i1")})
            test.eq(#model.rows(state, "installed"), 2)
            test.eq(model.summary(state), "1 installed · 0 shared")
        end)

        test.it("lists what the person uses and folds Bee's platform into one row", function()
            local state = fresh()
            hub.apply_installed(state.hub, hub_reply({modules = {
                {component = "bee/bee", version = "0.1.0-dev", source = "hub", direct = true, used_by = {}},
                {component = "wippy/bootloader", version = "1.0.0", source = "hub", direct = false, used_by = {"bee/bee"}},
                {component = "wippy/terminal", version = "1.0.0", source = "hub", direct = false, used_by = {"wippy/bootloader", "bee/bee"}},
                {component = "bee/terminal", version = "0.4.6", source = "builtin", direct = true, used_by = {}},
                {component = "userspace/calc", version = "1.0.0", source = "hub", direct = true, used_by = {}},
                {component = "userspace/lib", version = "1.0.0", source = "hub", direct = false, used_by = {"userspace/calc"}},
                {component = "userspace/shared", version = "1.0.0", source = "hub", direct = false, used_by = {"userspace/calc", "bee/bee"}},
            }, roots = {}}))
            hub.apply_updates(state.hub, hub_reply({modules = {
                {component = "userspace/calc", installed_version = "1.0.0", available_version = "1.2.0", update_available = true}},
                bee_update = {installed_version = "1.0.0", available_version = "1.0.0", update_available = false,
                    needs_new_binary = false, reason = ""}, catalog_error = ""}))
            local rows = model.rows(state, "installed")
            test.eq(#rows, 2)
            test.eq(rows[1].name, "userspace/calc")
            test.eq(rows[1].kind, "package")
            test.eq(rows[1].status, "Update available")
            test.eq(rows[1].update, "1.2.0")
            test.eq(rows[1].source, "from Hub")
            test.is_true(model.can_remove_package(rows[1]))
            test.eq(rows[2].kind, "platform")
            test.eq(rows[2].name, "Bee")
            test.eq(rows[2].version, "0.1.0-dev")
            test.eq(rows[2].source, "built in · 4 packages")
            test.is_false(model.can_remove_package(rows[2]))
            local names: {string} = {}
            for _, row in ipairs(model.platform(state)) do names[#names + 1] = row.name end
            test.eq(table.concat(names, ","), "bee/bee,bee/terminal,wippy/bootloader,wippy/terminal")
        end)

        test.it("names an application by its title and a package by its Hub title once the catalog is known", function()
            local state = fresh()
            local current = activation("i1", "notes_app", "1.0.0", "settled", "applied", "i1")
            current.title = "Notes"
            load(state, {}, {current})
            hub.apply_installed(state.hub, hub_reply({modules = {
                {component = "userspace/calc", version = "1.0.0", source = "hub", direct = true, used_by = {}}}, roots = {}}))
            test.eq(model.rows(state, "installed")[1].name, "Notes")
            test.eq(model.rows(state, "installed")[2].name, "userspace/calc")
            hub.apply_catalog(state.hub, hub_reply({total = 1, items = {
                {component = "userspace/calc", title = "Calculator", description = "App", latest_version = "1.0.0"}}}))
            test.eq(model.rows(state, "installed")[2].name, "Calculator")
        end)

        test.it("marks a driver and keeps a package other things need out of removal", function()
            local state = fresh()
            local driver = activation("i1", "driver_stub", "1.0.0", "settled", "applied", "i1")
            driver.overlay_owner = "bee.gov.drivers:workspace-destination.stub"
            load(state, {}, {driver})
            hub.apply_installed(state.hub, hub_reply({modules = {
                {component = "userspace/editor", version = "1.0.0", source = "hub", direct = true, used_by = {"userspace/suite"}}}, roots = {}}))
            local rows = model.rows(state, "installed")
            test.eq(rows[1].kind, "driver")
            test.eq(rows[2].component, "userspace/editor")
            test.is_false(model.can_remove_package(rows[2]))
        end)

        test.it("does not offer an update of Bee that needs a newer binary", function()
            local state = fresh()
            hub.apply_installed(state.hub, hub_reply({modules = {
                {component = "bee/bee", version = "1.0.0", source = "hub", direct = true, used_by = {}}}, roots = {}}))
            hub.apply_updates(state.hub, hub_reply({modules = {
                {component = "bee/bee", installed_version = "1.0.0", available_version = "2.0.0", update_available = true}},
                bee_update = {installed_version = "1.0.0", available_version = "2.0.0", update_available = true,
                    needs_new_binary = true, reason = "needs a newer Bee binary"}, catalog_error = ""}))
            test.eq(model.rows(state, "installed")[1].status, "Installed")
        end)

        test.it("shares the hive's versions first and keeps the Hub catalog collapsed until it is opened", function()
            local state = fresh()
            hub.apply_installed(state.hub, hub_reply({modules = {
                {component = "userspace/calc", version = "1.0.0", source = "hub", direct = true, used_by = {}}}, roots = {}}))
            hub.apply_catalog(state.hub, hub_reply({total = 4, items = {
                {component = "wippy/test", title = "Test Framework", description = "BDD", latest_version = "0.4.19", application = false},
                {component = "userspace/editor", title = "Editor", description = "Text editor app", latest_version = "2.0.0"},
                {component = "userspace/calc", title = "Calculator", description = "Calculator app", latest_version = "1.0.0"},
            }}))
            load(state, {version("tally", "1.0.0", "node-laptop")}, {})
            local rows = model.rows(state, "shared")
            test.eq(#rows, 2)
            test.eq(rows[1].name, "Tally")
            test.eq(rows[2].kind, "section")
            test.eq(rows[2].name, "Hub catalog")
            test.is_true(rows[2].source:find("packages", 1, true) ~= nil)
            test.is_false(model.summary(state):find("2 shared", 1, true) ~= nil)
            state.hub_open = true
            rows = model.rows(state, "shared")
            test.eq(#rows, 2)
            test.eq(rows[2].name, "Editor")
            test.eq(rows[2].component, "userspace/editor")
            test.eq(rows[2].source, "from Hub")
            test.eq(rows[2].status, "Shared")
            hub.set_developer_packages(state.hub, true)
            test.eq(#model.rows(state, "shared"), 3)
        end)

        test.it("picks a status glyph and a kind glyph from the one glyph set", function()
            test.eq(model.status_glyph("Installed"), "✓")
            test.eq(model.status_glyph("Update available"), "↑")
            test.eq(model.status_glyph("Waiting for your approval"), "◷")
            test.eq(model.status_glyph("Installing"), "⇣")
            test.eq(model.status_glyph("Removed"), "✗")
            test.eq(model.status_glyph("Shared"), "⬡")
            test.eq(model.kind_glyph("app"), "▣")
            test.eq(model.kind_glyph("driver"), "⌁")
            test.eq(model.kind_glyph("package"), "◫")
        end)

        test.it("records installs, removals and unfinished work in History", function()
            local state = fresh()
            load(state, {}, {activation("i5", "notes", "1.0.2", "settled", "applied", "i5"),
                activation("i1", "notes", "1.0.1", "settled", "applied", "i5")})
            hub.apply_history(state.hub, hub_reply({page = 1, total = 3, page_size = 25, operations = {
                {digest = string.rep("a", 64), component = "acme/app", action = "uninstall", state = "complete", message = "done", baseline_revision = 3},
                {digest = string.rep("b", 64), component = "acme/new", action = "install", state = "complete", message = "done", baseline_revision = 2,
                    request = {action = "install", component = "acme/new", version = "1.4.0", parameters = {}, migration_policy = "none"}},
                {digest = string.rep("c", 64), component = "acme/stuck", action = "update", state = "recovery_required", message = "paused", baseline_revision = 1},
            }}))
            local rows = model.rows(state, "history")
            test.eq(#rows, 5)
            test.eq(rows[1].status, "Installed")
            test.eq(rows[2].status, "Removed")
            test.eq(rows[3].status, "Removed")
            test.eq(rows[4].status, "Installed")
            test.eq(rows[4].version, "1.4.0")
            test.eq(rows[5].status, "Shared")
            test.eq(rows[5].note, "needs to be finished")
        end)

        test.it("keeps a selection through a refresh and moves within the list", function()
            local state = fresh()
            load(state, {version("a", "1.0.0", "node-x"), version("b", "1.0.0", "node-x"), version("c", "1.0.0", "node-x")}, {})
            model.show_tab(state, "shared")
            test.eq(assert(model.selected_row(state)).name, "A")
            model.move(state, 1)
            test.eq(assert(model.selected_row(state)).name, "B")
            model.move(state, 9)
            test.eq(assert(model.selected_row(state)).name, "C")
            load(state, {version("a", "1.0.0", "node-x"), version("b", "1.0.0", "node-x"), version("c", "1.0.0", "node-x")}, {})
            test.eq(assert(model.selected_row(state)).name, "C")
        end)

        test.it("orders dotted versions by their numbers", function()
            test.eq(model.compare("1.10.0", "1.9.0"), 1)
            test.eq(model.compare("1.0", "1.0.0"), 0)
            test.eq(model.compare("2.0.0", "10.0.0"), -1)
            test.eq(model.compare("1.0.0-beta", "1.0.0-alpha"), 1)
        end)

        test.it("names the agent that made a version on this bee and the bee a shared version came from", function()
            local state = fresh()
            local made = version("notes", "1.0.1", NODE)
            local made_manifest = made.manifest :: {[string]: unknown}
            made_manifest.author = "Claude Code"
            load(state, {made, version("tally", "1.0.0", "node-laptop")}, {
                activation("i1", "notes", "1.0.1", "settled", "applied", "i1"),
                activation("i2", "other", "1.0.0", "settled", "applied", "i2")})
            local rows = model.rows(state, "installed")
            test.eq(rows[1].source, "made by Claude Code")
            test.eq(rows[2].source, "made on this bee")
            test.eq(model.rows(state, "shared")[1].source, "from bee node-laptop")
            test.is_true(governed.apply_names(state.governed, reply({names = {["node-laptop"] = "laptop"}})))
            test.eq(model.rows(state, "shared")[1].source, "from bee laptop")
            test.eq(model.sources(state)[1], "node-laptop")
            test.eq(#model.sources(state), 1)
        end)

        test.it("says who made a shared version when it names its agent", function()
            local state = fresh()
            local shared = version("tally", "1.0.0", "node-laptop")
            local shared_manifest = shared.manifest :: {[string]: unknown}
            shared_manifest.author = "Codex"
            load(state, {shared}, {})
            model.show_tab(state, "shared")
            local lines = model.version_lines(state, assert(model.selected_row(state)))
            local made_by = ""
            for _, line in ipairs(lines) do if line.label == "Made by" then made_by = line.value end end
            test.eq(made_by, "Codex")
        end)

        test.it("opens an installed application by its definition and removes it back to the version before", function()
            local state = fresh()
            local installed = activation("i2", "notes", "1.0.1", "settled", "applied", "i2")
            installed.application = "app.notes:main"
            installed.baseline_intent_id = "i1"
            load(state, {}, {installed, activation("i1", "notes", "1.0.0", "settled", "applied", "i2")})
            local row = model.rows(state, "installed")[1]
            test.eq(row.application, "app.notes:main")
            test.eq(row.baseline, "1.0.0")
            test.is_true(model.can_remove(row) and model.can_go_back(row))
            test.is_true(model.ask_remove(state, row, "back"))
            local removal = assert(state.removal)
            test.eq(removal.app, "notes")
            test.eq(removal.baseline, "1.0.0")
            local said = table.concat(model.removal_lines(removal), "\n")
            test.is_true(said:find("Go back to Notes 1.0.0?", 1, true) ~= nil)
            test.is_true(said:find("goes back to 1.0.0", 1, true) ~= nil)
            test.is_true(said:find("saved stays", 1, true) ~= nil)
            model.cancel_remove(state)
            test.is_nil(state.removal)
            test.is_true(model.ask_remove(state, row))
            local plain_removal = assert(state.removal)
            test.eq(plain_removal.kind, "remove")
            local removing = table.concat(model.removal_lines(plain_removal), "\n")
            test.is_true(removing:find("Remove Notes 1.0.1?", 1, true) ~= nil)
            test.is_true(removing:find("saved in its databases is kept; nothing is deleted", 1, true) ~= nil)
            test.is_true(removing:find("again finds it as it was", 1, true) ~= nil)
        end)

        test.it("removes a first version outright but goes back only to an earlier one, and neither for an install on its way", function()
            local state = fresh()
            load(state, {}, {activation("i1", "notes", "1.0.0", "settled", "applied", "i1"),
                activation("i3", "tally", "1.0.0", "prepared", nil, nil)})
            local rows = model.rows(state, "installed")
            local by_name: {[string]: model.Row} = {}
            for _, row in ipairs(rows) do by_name[row.name] = row end
            test.is_true(model.can_remove(by_name.Notes))
            test.is_false(model.can_go_back(by_name.Notes))
            test.is_false(model.ask_remove(state, by_name.Notes, "back"))
            test.is_false(model.can_remove(by_name.Tally))
            test.is_false(model.ask_remove(state, by_name.Tally))
            test.is_nil(state.removal)
            test.is_false(model.can_remove(nil))
        end)

        test.it("describes a version in person words and keeps technical words for details", function()
            local state = fresh()
            load(state, {version("tally", "1.0.0", "node-laptop")}, {})
            model.show_tab(state, "shared")
            local row = assert(model.selected_row(state))
            local lines = model.version_lines(state, row)
            test.eq(lines[1].label, "Status")
            test.eq(lines[1].value, "⬡ Shared")
            test.eq(lines[2].value, "from bee node-laptop")
            for _, line in ipairs(lines) do
                for _, word in ipairs({"overlay", "staged", "plan", "preflight", "activation", "destination", "artifact", "digest", "descriptor", "receipt"}) do
                    test.is_nil(((line.label .. " " .. line.value):lower():find(word, 1, true)))
                end
            end
        end)
    end)
end

return test.run_cases(define_tests)
