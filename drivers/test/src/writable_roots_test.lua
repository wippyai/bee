-- MIT. A CLI descriptor declares how its launch argv admits extra writable
-- roots and how they render.
local test = require("test")
local descriptor = require("descriptor")
local writable_roots = require("writable_roots")

local function declared(provider: string): writable_roots.Declaration
    local selected, load_error = descriptor.load("bee.drivers." .. provider .. ".descriptor:cli")
    if not selected then error(tostring(load_error)) end
    return assert(selected.writable_roots, provider .. " declares writable roots")
end

local function define_tests()
    test.describe("Declared writable roots", function()
        test.it("admits roots only for the argv each shipped descriptor declares", function()
            local codex, claude, agy = declared("codex"), declared("claude"), declared("agy")
            test.is_true(writable_roots.enabled(codex, {"exec", "--sandbox=workspace-write"}))
            test.is_true(writable_roots.enabled(codex, {"--sandbox", "workspace-write", "x"}))
            test.is_false(writable_roots.enabled(codex, {"--sandbox", "read-only"}))
            test.is_false(writable_roots.enabled(codex, {"--help"}))
            for _, argv in ipairs({{"--permission-mode=default"}, {"--permission-mode=acceptEdits"}, {"--permission-mode=dontAsk"},
                {"--permission-mode", "default"}, {"--permission-mode", "acceptEdits"}, {"-p", "--permission-mode", "dontAsk"}}) do
                test.is_true(writable_roots.enabled(claude, argv))
            end
            test.is_false(writable_roots.enabled(claude, {"--permission-mode", "plan"}))
            test.is_false(writable_roots.enabled(claude, {"--permission-mode=bypassPermissions"}))
            test.is_false(writable_roots.enabled(claude, {"--permission-mode"}))
            test.is_true(writable_roots.enabled(agy, {"--sandbox"}))
            test.is_true(writable_roots.enabled(agy, {"--sandbox=true"}))
            test.is_false(writable_roots.enabled(agy, {"--other"}))
        end)

        test.it("renders each shipped descriptor's root arguments", function()
            local roots = {"/workspace/a", "/workspace/b"}
            test.eq(table.concat(assert(writable_roots.arguments(declared("codex"), roots)), " "),
                "--config " .. 'sandbox_workspace_write.writable_roots=["/workspace/a","/workspace/b"]')
            for _, provider in ipairs({"claude", "agy"}) do
                test.eq(table.concat(assert(writable_roots.arguments(declared(provider), roots)), " "),
                    "--add-dir /workspace/a --add-dir /workspace/b")
                test.eq(#assert(writable_roots.arguments(declared(provider), {})), 0)
            end
        end)

        test.it("refuses a declaration that renders no roots or names other placeholders", function()
            for _, raw in ipairs({
                {when_argv = {{"--x"}}},
                {when_argv = {{"--x"}}, argv = {"{roots}"}, argv_each = {"{root}"}},
                {when_argv = {}, argv_each = {"--add-dir", "{root}"}},
                {when_argv = {{}}, argv_each = {"--add-dir", "{root}"}},
                {when_argv = {{"--x"}}, argv_each = {"--add-dir", "{roots}"}},
                {when_argv = {{"--x"}}, argv = {"--config", "{root}"}},
                {when_argv = {{"--x"}}, argv = {"--config"}},
                {when_argv = {{"--x"}}, argv_each = {"--add-dir", "{root}"}, extra = true},
            }) do
                local decoded, decode_error = writable_roots.decode(raw)
                test.is_nil(decoded)
                test.not_nil(decode_error)
            end
        end)
    end)
end
return test.run_cases(define_tests)
