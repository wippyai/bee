-- MIT. Tests for writable roots CLI adapter rendering.
local test = require("test")
local writable_roots_adapter = require("writable_roots_adapter")

local function define_tests()
    test.describe("Writable roots adapter", function()
        test.it("checks if adapter is enabled based on argv", function()
            test.is_true(writable_roots_adapter.enabled("codex_workspace_write", {"--sandbox=workspace-write"}))
            test.is_true(writable_roots_adapter.enabled("codex_workspace_write", {"--sandbox", "workspace-write"}))
            test.is_false(writable_roots_adapter.enabled("codex_workspace_write", {"--help"}))

            test.is_true(writable_roots_adapter.enabled("claude_add_dir", {"--permission-mode=acceptEdits"}))
            test.is_true(writable_roots_adapter.enabled("claude_add_dir", {"--permission-mode", "dontAsk"}))
            test.is_false(writable_roots_adapter.enabled("claude_add_dir", {"--help"}))

            test.is_true(writable_roots_adapter.enabled("agy_add_dir", {"--sandbox"}))
            test.is_true(writable_roots_adapter.enabled("agy_add_dir", {"--sandbox=true"}))
            test.is_false(writable_roots_adapter.enabled("agy_add_dir", {"--other"}))
        end)

        test.it("renders codex writable-roots arguments", function()
            local args, err = writable_roots_adapter.arguments("codex_workspace_write", {"/workspace/a", "/workspace/b"})
            if not args then error(tostring(err)) end
            test.eq(#args, 2)
            test.eq(args[1], "--config")
            test.contains(args[2], "sandbox_workspace_write.writable_roots=")
            test.contains(args[2], "/workspace/a")
            test.contains(args[2], "/workspace/b")
        end)

        test.it("renders add-dir arguments", function()
            local args, err = writable_roots_adapter.arguments("claude_add_dir", {"/workspace/a", "/workspace/b"})
            if not args then error(tostring(err)) end
            test.eq(#args, 4)
            test.eq(args[1], "--add-dir")
            test.eq(args[2], "/workspace/a")
            test.eq(args[3], "--add-dir")
            test.eq(args[4], "/workspace/b")
        end)

        test.it("rejects unsupported adapter kind", function()
            local args, err = writable_roots_adapter.arguments("unsupported", {"/workspace/a"})
            test.is_nil(args)
            test.not_nil(err)
        end)
    end)
end

return test.run_cases(define_tests)
