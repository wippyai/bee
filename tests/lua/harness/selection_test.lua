-- MIT. Window launch selection reads definitions and admission measurements
-- from one pinned registry snapshot, exposes only presentation-safe fields,
-- and treats malformed or unusable visible definitions as unavailable.
local test = require("test")
local registry = require("registry")
local selection = require("selection")
local view = require("view")
local appearance = require("appearance")

local CLAUDE = "bee.driver.claude:binding"
local POLICY = "bee.harness.catalog:fixture_policy"
local ACTIVATION = "bee:harness_activation"
local PREFIX = "bee.harness.catalog:selection_"

type Entry = {[string]: unknown}
type Choice = {definition_ref: string, title: string, launch_id: string, plan_digest: string}
type Choices = {items: {Choice}, unavailable: integer}

local function definition(id: string, title: string, launch_id: string, mode: string, start_menu: boolean, binding_ref: string?): Entry
    return {id = PREFIX .. id, kind = "registry.entry", meta = {type = "bee.launch_definition", test_support = true}, data = {
        schema_revision = "bee.launch-definition@1",
        launch_id = launch_id,
        title = title,
        command_names = {launch_id},
        binding_ref = binding_ref or CLAUDE,
        profile_id = "window",
        policy_ref = POLICY,
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
    local fields = {definition_ref = true, title = true, launch_id = true, plan_digest = true}
    for key, _ in pairs(item :: {[string]: unknown}) do
        if not fields[tostring(key)] then error("selection leaked field " .. tostring(key)) end
    end
end

local function copy_table(value: Entry): Entry
    local result: Entry = {}
    for key, item in pairs(value) do result[key] = item end
    return result
end

local function define_tests()
    test.describe("Window launch selection", function()
        test.it("renders bounded profiles without terminal controls and disables invisible launch", function()
            local listed: selection.Choices = {items = {{definition_ref = "fixture:profile", title = "Profile\27]52;injected", launch_id = "profile", plan_digest = string.rep("a", 64)}}, unavailable = 0}
            local frame = view.draw(40, 10, appearance.defaults(), listed, 1, "")
            test.eq(#frame.rows, 10)
            test.is_nil(table.concat(frame.rows):find("\27]52", 1, true))
            local small = view.draw(20, 3, appearance.defaults(), listed, 1, "")
            test.eq(#small.rows, 3)
            test.eq(small.capacity, 0)
            for _, hit in ipairs(small.hits) do test.is_true(hit.action ~= "open") end
            local thin = view.draw(2, 10, appearance.defaults(), listed, 1, "")
            test.eq(thin.capacity, 0)
            for _, hit in ipairs(thin.hits) do test.is_true(hit.action ~= "open") end
        end)
        test.it("returns an empty eligible list when only hidden or batch definitions exist", function()
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

        test.it("sorts valid window definitions and measures independent plans", function()
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
                has_only_choice_fields(result.items[1])
                has_only_choice_fields(result.items[2])
            end)
        end)

        test.it("counts a visible definition with an inactive binding as unavailable", function()
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
                test.eq(#result.items, 0)
                test.eq(result.unavailable, 1)
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

        test.it("keeps a pinned selection stable across a later policy mutation", function()
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

        test.it("refuses an incomplete definition list above the bound", function()
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
