-- MIT. Freezing authoring files is deterministic, bounded, and memory-only.
local test = require("test")
local workspace = require("workspace")

local function input(files: {workspace.File}?): workspace.Input
    local selected: {workspace.File}
    if files then
        selected = files
    else
        selected = {{path = "service/main.lua", content = "return 'ok'"},
            {path = "assets/module.wasm", content = "\0\255wasm"}}
    end
    return {workspace_id = "wolfy-j/demo", revision = 4, files = selected}
end

local function freeze(value: workspace.Input): workspace.Snapshot
    local snapshot, freeze_error = workspace.freeze(value)
    if not snapshot then error(tostring(freeze_error)) end
    return snapshot
end

local function define_tests()
    test.describe("Governance workspace snapshot", function()
        test.it("sorts canonical relative paths and deterministically measures binary content", function()
            local unordered = input({{path = "z.txt", content = "z"}, {path = "a/module.wasm", content = "\0\255"}})
            local ordered = input({{path = "a/module.wasm", content = "\0\255"}, {path = "z.txt", content = "z"}})
            local left, right = freeze(unordered), freeze(ordered)
            test.eq(left.files[1].path, "a/module.wasm")
            test.eq(left.files[2].path, "z.txt")
            test.eq(left.file_count, 2)
            test.eq(left.total_bytes, 3)
            test.eq(left.digest, right.digest)
        end)
        test.it("binds files, workspace identity, and revision while copying records", function()
            local value = input()
            local snapshot = freeze(value)
            local initial = snapshot.digest
            value.files[1].path = "changed.lua"
            value.files[1].content = "changed"
            test.eq(snapshot.files[1].path, "assets/module.wasm")
            test.eq(snapshot.files[2].content, "return 'ok'")
            test.eq(snapshot.digest, initial)
            local changed = input()
            changed.files[1].content = "different"
            test.is_false(freeze(changed).digest == initial)
            changed = input()
            changed.workspace_id = "wolfy-j/other"
            test.is_false(freeze(changed).digest == initial)
            changed = input()
            changed.revision = 5
            test.is_false(freeze(changed).digest == initial)
        end)
        test.it("rejects hostile or ambiguous paths", function()
            local bad = {"/absolute", "dir\\file", "C:drive", "dir:ads", "../escape", "dir/../escape", "dir//file", "dir/", "", "dir/\nfile"}
            for _, path in ipairs(bad) do
                local snapshot = workspace.freeze(input({{path = path, content = "x"}}))
                test.is_nil(snapshot)
            end
            local duplicate = workspace.freeze(input({{path = "same", content = "a"}, {path = "same", content = "b"}}))
            test.is_nil(duplicate)
            local collision = workspace.freeze(input({{path = "service", content = "a"}, {path = "service-other", content = "b"},
                {path = "service/main.lua", content = "c"}}))
            test.is_nil(collision)
        end)
        test.it("enforces file and byte quotas before producing a snapshot", function()
            local too_many: {workspace.File} = {}
            for index = 1, workspace.MAX_FILES + 1 do too_many[index] = {path = "file" .. tostring(index), content = "x"} end
            test.is_nil(workspace.freeze(input(too_many)))
            test.is_nil(workspace.freeze(input({{path = "large", content = string.rep("x", workspace.MAX_FILE_BYTES + 1)}})))
            local total = {{path = "one", content = string.rep("x", workspace.MAX_FILE_BYTES)},
                {path = "two", content = string.rep("x", workspace.MAX_FILE_BYTES)},
                {path = "three", content = string.rep("x", workspace.MAX_FILE_BYTES)},
                {path = "four", content = string.rep("x", workspace.MAX_FILE_BYTES)},
                {path = "five", content = "x"}}
            test.is_nil(workspace.freeze(input(total)))
        end)
        test.it("hashes an admitted binary file beyond canonical JSON's content limit", function()
            local binary = string.rep("\255", 16385)
            local snapshot = freeze(input({{path = "assets/large.wasm", content = binary}}))
            test.eq(snapshot.total_bytes, #binary)
            test.eq(snapshot.files[1].bytes, #binary)
            test.eq(snapshot.files[1].content, binary)
        end)
        test.it("admits every bounded record without relying on an aggregate JSON manifest", function()
            local maximum_files: {workspace.File} = {}
            for index = 1, workspace.MAX_FILES do
                local suffix = string.format("-%08d", index)
                maximum_files[index] = {path = string.rep("p", workspace.MAX_PATH_BYTES - #suffix) .. suffix, content = ""}
            end
            local maximum_records = freeze(input(maximum_files))
            test.eq(maximum_records.file_count, workspace.MAX_FILES)
            test.eq(#maximum_records.files[1].path, workspace.MAX_PATH_BYTES)
            local maximum_file = freeze(input({{path = "assets/max.wasm", content = string.rep("\255", workspace.MAX_FILE_BYTES)}}))
            test.eq(maximum_file.total_bytes, workspace.MAX_FILE_BYTES)
        end)
    end)
end

return test.run_cases(define_tests)
