-- MIT. Command selection resolves only one definition reference; the Agent
-- window discovers ready and unavailable candidates through session_catalog.
local test = require("test")
local registry = require("registry")
local selection = require("selection")

type Entry = {[string]: unknown}
local PREFIX = "bee.harness.catalog:selection_"
local POLICY = "bee.harness.catalog:selection_policy"


type RegistryInput = {id: string, kind: string, meta: {[string]: unknown}, data: unknown, dependency_root: boolean}
local function registry_input(value: {[string]: unknown}): RegistryInput
    local id, kind, meta, dependency_root = value.id, value.kind, value.meta, value.dependency_root
    assert(type(id) == "string" and type(kind) == "string", "fixture registry entry identity")
    local metadata: {[string]: unknown} = {}
    if meta ~= nil then
        assert(type(meta) == "table", "fixture registry metadata")
        for key, item in pairs(meta) do metadata[key] = item end
    end
    assert(dependency_root == nil or type(dependency_root) == "boolean", "fixture registry dependency root")
    return {id = id, kind = kind, meta = metadata, data = value.data, dependency_root = dependency_root == true}
end

local function definition(id: string, command: string, mode: string, fullscreen: boolean?): Entry
    return {id = PREFIX .. id, kind = "registry.entry", meta = {type = "bee.launch_definition", test_support = true}, data = {
        schema_revision = "bee.launch-definition@1", launch_id = id, title = "Selection fixture", command_names = {command},
        binding_ref = "bee.driver.claude:binding", profile_id = "window", policy_ref = POLICY, default_mode = mode,
        allowed_overrides = {}, workdir_policy = {kind = "caller_workspace"}, thread_policy = {kind = "new"},
        credentials = {}, presentation = {start_menu = false, fullscreen = fullscreen == true, reuse = "never"},
    }}
end

local function with_entries(entries: {Entry}, body: () -> ())
    local changes = registry.snapshot():changes()
    for _, entry in ipairs(entries) do
        if registry.get(tostring(entry.id)) then error("selection fixture already exists") end
        changes:create(registry_input(entry))
    end
    local applied, apply_error = changes:apply()
    if not applied then error("create selection fixtures: " .. tostring(apply_error)) end
    local ok, failure = pcall(body)
    local remove = registry.snapshot():changes()
    for _, entry in ipairs(entries) do remove:delete(tostring(entry.id)) end
    local removed, remove_error = remove:apply()
    if not removed then error("remove selection fixtures: " .. tostring(remove_error)) end
    if not ok then error(tostring(failure)) end
end

local function define_tests()
    test.describe("Component command selection", function()
        test.it("resolves a command without Start-menu visibility", function()
            with_entries({definition("command", "selection-command", "window", true)}, function()
                local selected, err = selection.command("selection-command")
                if not selected then error(tostring(err)) end
                test.eq(selected.definition_ref, PREFIX .. "command")
                test.is_true(selected.fullscreen)
                local missing, missing_error = selection.command("selection-missing")
                test.is_nil(missing)
                test.is_nil(missing_error)
            end)
        end)

        test.it("refuses ambiguous, non-window and malformed command claims", function()
            with_entries({definition("first", "selection-duplicate", "window"),
                definition("second", "selection-duplicate", "window")}, function()
                local selected, err = selection.command("selection-duplicate")
                test.is_nil(selected)
                test.eq(err, "Ambiguous Bee command: selection-duplicate")
            end)
            with_entries({definition("batch", "selection-batch", "batch")}, function()
                local selected, err = selection.command("selection-batch")
                test.is_nil(selected)
                test.eq(err, "Bee command selection-batch does not select a window profile")
            end)
            local invalid, invalid_error = selection.command("../invalid")
            test.is_nil(invalid)
            test.eq(invalid_error, "Invalid Bee command")
        end)
    end)
end

return test.run_cases(define_tests)
