-- MIT. Window launch selection reads definitions and admission measurements
-- from one pinned registry snapshot, exposes only presentation-safe fields,
-- and treats malformed or unusable visible definitions as unavailable.
local test = require("test")
local registry = require("registry")
local selection = require("selection")
local view = require("view")
local appearance = require("appearance")

local CLAUDE = "bee.driver.claude:binding"
local POLICY = "bee.harness.catalog:selection_policy"
local ACTIVATION = "bee:harness_activation"
local PREFIX = "bee.harness.catalog:selection_"

type Entry = {[string]: unknown}
type Choice = selection.Choice
type Choices = {items: {Choice}, unavailable: integer}

local function definition(id: string, title: string, launch_id: string, mode: string, start_menu: boolean, binding_ref: string?, policy_ref: string?): Entry
    return {id = PREFIX .. id, kind = "registry.entry", meta = {type = "bee.launch_definition", test_support = true}, data = {
        schema_revision = "bee.launch-definition@1",
        launch_id = launch_id,
        title = title,
        command_names = {launch_id},
        binding_ref = binding_ref or CLAUDE,
        profile_id = "window",
        policy_ref = policy_ref or POLICY,
        default_mode = mode,
        allowed_overrides = {},
        workdir_policy = {kind = "caller_workspace"},
        thread_policy = {kind = "new"},
        credentials = {},
        presentation = {start_menu = start_menu, fullscreen = false, reuse = "never"},
    }}
end

local function invalid_definition(id: string): Entry
    return {id = PREFIX .. id, kind = "registry.entry", meta = {type = "bee.launch_definition", test_support = true}, data = {
        schema_revision = "bee.launch-definition@invalid",
        title = "Broken selection fixture",
    }}
end

local function apply_create(entries: {Entry})
    local changes = registry.snapshot():changes()
    for _, entry in ipairs(entries) do
        if registry.get(tostring(entry.id)) then error("selection fixture already exists: " .. tostring(entry.id)) end
        changes:create(entry)
    end
    local applied, err = changes:apply()
    if not applied then error("create selection fixtures: " .. tostring(err)) end
end

local function remove(entries: {Entry})
    local changes = registry.snapshot():changes()
    for _, entry in ipairs(entries) do changes:delete(tostring(entry.id)) end
    local removed, err = changes:apply()
    if not removed then error("remove selection fixtures: " .. tostring(err)) end
end

local function with_entries(entries: {Entry}, body: () -> ())
    for _, entry in ipairs(entries) do
        if registry.get(tostring(entry.id)) then error("selection fixture already exists: " .. tostring(entry.id)) end
    end
    local created, create_failure = pcall(function() apply_create(entries) end)
    if not created then
        local removed, remove_error = pcall(function() remove(entries) end)
        if not removed then error(tostring(remove_error)) end
        error(tostring(create_failure))
    end
    local ok, failure = pcall(body)
    local cleanup_ok, cleanup_error = pcall(function() remove(entries) end)
    if not cleanup_ok then error("restore selection fixtures: " .. tostring(cleanup_error)) end
    if not ok then error(tostring(failure)) end
end

local function choices(value: Choices?, err: string?): Choices
    if not value then error(tostring(err)) end
    return value
end

local function has_only_choice_fields(item: Choice)
    local fields = {definition_ref = true, title = true, launch_id = true, plan_digest = true, unavailable = true, summary = true}
    for key, _ in pairs(item :: {[string]: unknown}) do
        if not fields[tostring(key)] then error("selection leaked field " .. tostring(key)) end
    end
end

local function copy_table(value: Entry): Entry
    local result: Entry = {}
    for key, item in pairs(value) do result[key] = item end
    return result
end

-- Production defaults are covered by executable acceptance. These cases own
-- their inventory and restore the shipped definitions even after a failure.
local function isolated_it(name: string, body: () -> ())
    test.it(name, function()
        local saved: {Entry} = {}
        local changes = registry.snapshot():changes()
        local found = assert(registry.find({["meta.type"] = "bee.launch_definition"}))
        for _, entry in ipairs(found) do
            local meta = entry.meta :: Entry
            if meta.test_support ~= true then
                saved[#saved + 1] = entry
                local hidden = copy_table(entry)
                local data = copy_table(entry.data :: Entry)
                local presentation = copy_table(data.presentation :: Entry)
                presentation.start_menu = false
                data.presentation = presentation; hidden.data = data
                changes:update(hidden)
            end
        end
        local applied, apply_error = changes:apply()
        if not applied then error(tostring(apply_error)) end
        local ok, failure = pcall(body)
        local restore = registry.snapshot():changes()
        for _, entry in ipairs(saved) do restore:update(entry) end
        local restored, restore_error = restore:apply()
        if not restored then error(tostring(restore_error)) end
        if not ok then error(tostring(failure)) end
    end)
end
local function define_tests()
    test.describe("Window launch selection", function()
        isolated_it("renders bounded profiles without terminal controls and disables invisible launch", function()
            local listed: selection.Choices = {items = {{definition_ref = "fixture:profile", title = "Profile\27]52;injected", launch_id = "profile", plan_digest = string.rep("a", 64)}}, unavailable = 0}
            local frame = view.draw(40, 10, appearance.defaults(), listed, 1, "")
            test.eq(#frame.rows, 10)
            test.is_nil(table.concat(frame.rows):find("\27]52", 1, true))
            local small = view.draw(20, 3, appearance.defaults(), listed, 1, "")
            test.eq(#small.rows, 3)
            test.eq(small.capacity, 0)
            for _, hit in ipairs(small.hits) do
                test.is_true(hit.action ~= "open" and hit.action ~= "new" and hit.action ~= "edit")
            end
            local thin = view.draw(2, 10, appearance.defaults(), listed, 1, "")
            test.eq(thin.capacity, 0)
            for _, hit in ipairs(thin.hits) do
                test.is_true(hit.action ~= "open" and hit.action ~= "new" and hit.action ~= "edit")
            end
            local empty = view.draw(80, 12, appearance.defaults(), {items = {}, unavailable = 0}, 0, "")
            for _, hit in ipairs(empty.hits) do
                test.is_true(hit.action ~= "open" and hit.action ~= "new" and hit.action ~= "edit")
            end
            local loading = table.concat(view.draw(80, 12, appearance.defaults(),
                {items = {}, unavailable = 0}, 0, "Loading profiles…").rows)
            test.is_true(loading:find("Loading profiles", 1, true) ~= nil)
            test.is_true(loading:find("No agent profiles", 1, true) == nil)
            local starting = view.draw(80, 12, appearance.defaults(), listed, 1, "Starting Agent…", true)
            test.is_true(table.concat(starting.rows):find("Starting Agent", 1, true) ~= nil)
            for _, hit in ipairs(starting.hits) do
                test.is_true(hit.action ~= "open" and hit.action ~= "new" and hit.action ~= "edit" and hit.action ~= "refresh")
            end
        end)
        isolated_it("returns an empty eligible list when only hidden or batch definitions exist", function()
            local entries = {
                definition("empty-hidden", "Hidden empty fixture", "selection-empty-hidden", "window", false),
                definition("empty-batch", "Batch empty fixture", "selection-empty-batch", "batch", true),
            }
            with_entries(entries, function()
                local listed, err = selection.snapshot()
                local result = choices(listed, err)
                test.eq(#result.items, 0)
                test.eq(result.unavailable, 0)
            end)
        end)

        isolated_it("resolves component command names without requiring Start-menu visibility", function()
            local entries = {
                definition("command", "Command window", "selection-command", "window", false),
            }
            with_entries(entries, function()
                local command, err = selection.command("selection-command")
                if not command then error(tostring(err)) end
                test.eq(command.definition_ref, PREFIX .. "command")
                test.is_false(command.fullscreen)
                local missing, missing_error = selection.command("selection-missing")
                test.is_nil(missing)
                test.is_nil(missing_error)
            end)
        end)

        isolated_it("refuses ambiguous and non-window command claims", function()
            local duplicates = {
                definition("command-first", "First", "selection-duplicate", "window", false),
                definition("command-second", "Second", "selection-duplicate", "window", false),
            }
            with_entries(duplicates, function()
                local command, err = selection.command("selection-duplicate")
                test.is_nil(command)
                test.eq(err, "Ambiguous Bee command: selection-duplicate")
            end)
            local batch = {definition("command-batch", "Batch", "selection-batch-command", "batch", false)}
            with_entries(batch, function()
                local command, err = selection.command("selection-batch-command")
                test.is_nil(command)
                test.eq(err, "Bee command selection-batch-command does not select a window profile")
            end)
        end)

        isolated_it("sorts valid window definitions and measures independent plans", function()
            local entries = {
                definition("zulu", "Zulu window", "selection-zulu", "window", true),
                definition("alpha", "Alpha window", "selection-alpha", "window", true),
                definition("hidden", "Hidden window", "selection-hidden", "window", false),
                definition("batch", "Batch menu entry", "selection-batch", "batch", true),
                invalid_definition("invalid"),
            }
            with_entries(entries, function()
                local result = choices(selection.snapshot())
                test.eq(#result.items, 2)
                test.eq(result.unavailable, 1)
                test.eq(result.items[1].title, "Alpha window")
                test.eq(result.items[1].definition_ref, PREFIX .. "alpha")
                test.eq(result.items[1].launch_id, "selection-alpha")
                test.eq(result.items[2].title, "Zulu window")
                test.eq(result.items[2].definition_ref, PREFIX .. "zulu")
                test.eq(result.items[2].launch_id, "selection-zulu")
                test.neq(result.items[1].plan_digest, result.items[2].plan_digest)
                test.eq(#result.items[1].plan_digest, 64)
                test.eq(#result.items[2].plan_digest, 64)
                test.eq(result.items[1].summary, "Project folder · No instructions · 0 tools configured")
                local frame = view.draw(100, 12, appearance.defaults(), result, 1, "")
                test.is_true(table.concat(frame.rows):find("Project folder", 1, true) ~= nil)
                test.is_true(table.concat(frame.rows):find("No instructions", 1, true) ~= nil)
                has_only_choice_fields(result.items[1])
                has_only_choice_fields(result.items[2])
            end)
        end)

        isolated_it("summarizes configured guidance without exposing its text", function()
          for _, guidance in ipairs({
            {instructions = "PRIVATE_GUIDANCE_SENTINEL"},
            {instruction_builder = {func_id = "fixture:not_called_during_discovery", args = {memory = "PRIVATE_GUIDANCE_SENTINEL"}}},
            {instructions = "PRIVATE_GUIDANCE_SENTINEL", instruction_builder = {func_id = "fixture:not_called_during_discovery", args = {}}},
          }) do
            local original = registry.get(POLICY)
            if not original then error("missing selection policy") end
            local configured = copy_table(original)
            configured.id = PREFIX .. "guidance_policy"
            local data = copy_table(original.data :: Entry)
            data.instructions = guidance.instructions
            data.instruction_builder = guidance.instruction_builder
            configured.data = data
            with_entries({configured, definition("guided", "Guided profile", "selection-guided", "window", true, nil,
                PREFIX .. "guidance_policy")}, function()
                local result = choices(selection.snapshot())
                test.eq(#result.items, 1)
                test.eq(result.items[1].summary, "Project folder · Profile instructions · 0 tools configured")
                local frame = view.draw(100, 12, appearance.defaults(), result, 1, "")
                local rows = table.concat(frame.rows)
                test.is_true(rows:find("Profile instructions", 1, true) ~= nil)
                test.is_true(rows:find("PRIVATE_GUIDANCE_SENTINEL", 1, true) == nil)
                test.is_true(rows:find("not_called_during_discovery", 1, true) == nil)
                has_only_choice_fields(result.items[1])
            end)
          end
        end)

        isolated_it("keeps an inactive profile visible with its refusal and disables launch", function()
            local original = assert(registry.get(ACTIVATION))
            local changed = copy_table(original)
            local original_data = original.data :: Entry
            local changed_data = copy_table(original_data)
            local bindings: {string} = {}
            for _, binding in ipairs(original_data.bindings :: {string}) do
                if binding ~= CLAUDE then bindings[#bindings + 1] = binding end
            end
            changed_data.bindings = bindings
            changed.data = changed_data
            local entry = definition("inactive", "Inactive Claude window", "selection-inactive", "window", true)
            local ok, failure = pcall(function()
                apply_create({entry})
                local activation_changes = registry.snapshot():changes()
                activation_changes:update(changed)
                local applied, apply_error = activation_changes:apply()
                if not applied then error("deactivate Claude fixture: " .. tostring(apply_error)) end
                local result = choices(selection.snapshot())
                test.eq(#result.items, 1)
                test.eq(result.unavailable, 1)
                local item = result.items[1]
                test.eq(item.title, "Inactive Claude window")
                test.eq(item.plan_digest, "")
                test.is_true(item.unavailable ~= nil)
                has_only_choice_fields(item)
                local frame = view.draw(100, 10, appearance.defaults(), result, 1, "")
                test.is_true(table.concat(frame.rows):find("Inactive Claude window", 1, true) ~= nil)
                test.is_true(table.concat(frame.rows):find("not usable on this host", 1, true) ~= nil)
                for _, hit in ipairs(frame.hits) do test.is_true(hit.action ~= "open") end
            end)
            local activation_restored, activation_error = pcall(function()
                local restore_changes = registry.snapshot():changes()
                restore_changes:update(original)
                local applied, apply_error = restore_changes:apply()
                if not applied then error("restore activation: " .. tostring(apply_error)) end
            end)
            local removed, remove_error = pcall(function() remove({entry}) end)
            if not activation_restored then error(tostring(activation_error)) end
            if not removed then error(tostring(remove_error)) end
            if not ok then error(tostring(failure)) end
        end)

        isolated_it("requires an absolute policy binding without inferring the prepared executable key", function()
            local policy = assert(registry.get(POLICY))
            local original_policy = policy.data
            local distinct = copy_table(policy)
            local distinct_data = copy_table(policy.data :: Entry)
            distinct_data.executables = {codex = "/bin/true"}
            distinct.data = distinct_data
            local relative = copy_table(policy)
            local relative_data = copy_table(policy.data :: Entry)
            relative_data.executables = {codex = "bin/codex"}
            relative.data = relative_data
            local claude = definition("distinct-executable", "Claude with a distinct executable key", "selection-distinct-executable", "window", true)
            local ok, failure = pcall(function()
                apply_create({claude})
                local changes = registry.snapshot():changes()
                changes:update(distinct)
                local applied, apply_error = changes:apply()
                if not applied then error("set distinct executable binding: " .. tostring(apply_error)) end
                local result = choices(selection.snapshot())
                -- Listing preserves only the measured choice. It does not
                -- pre-bind the Claude driver's eventual executable to codex;
                -- machine.plan remains the exact prepared-name mapper.
                test.eq(#result.items, 1)
                test.eq(result.items[1].definition_ref, PREFIX .. "distinct-executable")
                has_only_choice_fields(result.items[1])
                test.eq(result.unavailable, 0)
                local relative_changes = registry.snapshot():changes()
                relative_changes:update(relative)
                local relative_applied, relative_error = relative_changes:apply()
                if not relative_applied then error("set relative executable binding: " .. tostring(relative_error)) end
                local unavailable = choices(selection.snapshot())
                test.eq(#unavailable.items, 1)
                test.eq(unavailable.unavailable, 1)
                test.eq(unavailable.items[1].plan_digest, "")
                test.is_true(unavailable.items[1].unavailable ~= nil)
            end)
            local restored, restore_error = pcall(function()
                policy.data = original_policy
                local changes = registry.snapshot():changes()
                changes:update(policy)
                local applied, apply_error = changes:apply()
                if not applied then error("restore selection policies: " .. tostring(apply_error)) end
            end)
            local removed, remove_error = pcall(function() remove({claude}) end)
            if not restored then error(tostring(restore_error)) end
            if not removed then error(tostring(remove_error)) end
            if not ok then error(tostring(failure)) end
        end)

        isolated_it("keeps a pinned selection stable across a later policy mutation", function()
            local entry = definition("pinned", "Pinned window", "selection-pinned", "window", true)
            local policy = assert(registry.get(POLICY))
            local original_policy_data = policy.data
            local ok, failure = pcall(function()
                apply_create({entry})
                local pinned = assert(registry.snapshot())
                local before = choices(selection.read(pinned))
                test.eq(#before.items, 1)
                local changed = copy_table(policy)
                local changed_data = copy_table(policy.data :: Entry)
                changed_data.start_ms = 23456
                changed.data = changed_data
                local policy_changes = registry.snapshot():changes()
                policy_changes:update(changed)
                local applied, apply_error = policy_changes:apply()
                if not applied then error("mutate selection policy: " .. tostring(apply_error)) end
                local retained = choices(selection.read(pinned))
                local current = choices(selection.snapshot())
                test.eq(retained.items[1].plan_digest, before.items[1].plan_digest)
                test.neq(current.items[1].plan_digest, before.items[1].plan_digest)
            end)
            local policy_restored, policy_error = pcall(function()
                policy.data = original_policy_data
                local policy_changes = registry.snapshot():changes()
                policy_changes:update(policy)
                local applied, apply_error = policy_changes:apply()
                if not applied then error("restore selection policy: " .. tostring(apply_error)) end
            end)
            local removed, remove_error = pcall(function() remove({entry}) end)
            if not policy_restored then error(tostring(policy_error)) end
            if not removed then error(tostring(remove_error)) end
            if not ok then error(tostring(failure)) end
        end)

        isolated_it("refuses an incomplete definition list above the bound", function()
            local entries: {Entry} = {}
            for index = 1, selection.MAX_DEFINITIONS + 1 do
                entries[#entries + 1] = definition("bounded-" .. tostring(index), "Bounded " .. tostring(index),
                    "selection-bounded-" .. tostring(index), "window", true)
            end
            with_entries(entries, function()
                local listed, err = selection.snapshot()
                test.is_nil(listed)
                test.eq(err, "Too many agent profiles to list")
            end)
        end)
    end)
end

return test.run_cases(define_tests)
