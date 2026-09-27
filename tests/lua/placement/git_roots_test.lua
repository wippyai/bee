-- MIT. Git metadata discovery and provider argument formatting without a
-- Git process, plus the boundary that keeps added roots under writable grants.
local test = require("test")
local git_roots = require("git_roots")

local function filesystem(files: {[string]: string}, directories: {[string]: boolean})
    local function exists(path: string): (boolean?, string?)
        return files[path] ~= nil or directories[path] == true, nil
    end
    local function is_directory(path: string): (boolean?, string?)
        return directories[path] == true, nil
    end
    local function read_file(path: string): (string?, string?)
        local content = files[path]
        if content == nil then return nil, "not found" end
        return content, nil
    end
    return exists, is_directory, read_file
end

local function define_tests()
    test.describe("Git writable roots", function()
        test.it("resolves a worktree gitdir and commondir without starting Git", function()
            local git_dir = "/workspace/.git/worktrees/topic"
            local exists, is_directory, read_file = filesystem({
                ["/workspace/.worktrees/topic/.git"] = "gitdir: " .. git_dir .. "\n",
                [git_dir .. "/commondir"] = "../..\n",
            }, {[git_dir] = true, ["/workspace/.git"] = true})
            local found, err = git_roots.detect("/workspace/.worktrees/topic", exists, is_directory, read_file)
            if not found then error(tostring(err)) end
            test.eq(#found, 2)
            test.eq(found[1], "/workspace/.git")
            test.eq(found[2], git_dir)
            local writable, writable_error = git_roots.writable_roots(found, {"/workspace"})
            if not writable then error(tostring(writable_error)) end
            test.eq(#writable, 2)
            test.eq(writable[1], "/workspace/.git")
            test.eq(writable[2], git_dir)
        end)
        test.it("uses one root for a regular repository and no roots for an ordinary directory", function()
            local exists, is_directory, read_file = filesystem({}, { ["/workspace/repo/.git"] = true })
            local repo = assert(git_roots.detect("/workspace/repo", exists, is_directory, read_file))
            test.eq(#repo, 1)
            test.eq(repo[1], "/workspace/repo/.git")
            local nested = assert(git_roots.detect("/workspace/repo/source", exists, is_directory, read_file))
            test.eq(#nested, 1)
            test.eq(nested[1], "/workspace/repo/.git")
            local empty = assert(git_roots.detect("/workspace/plain", exists, is_directory, read_file))
            test.eq(#empty, 0)
        end)
        test.it("omits Git metadata outside a write-granted root and deduplicates exact roots", function()
            local omitted, omit_error = git_roots.writable_roots({"/outside/repo/.git"}, {"/workspace"})
            if not omitted then error(tostring(omit_error)) end
            test.eq(#omitted, 0)
            local accepted = assert(git_roots.writable_roots({"/workspace/repo/.git", "/workspace/repo/.git"}, {"/workspace"}))
            test.eq(#accepted, 1)
            test.eq(accepted[1], "/workspace/repo/.git")
        end)
        test.it("builds only the provider's writable-root options for an active permission mode", function()
            local roots = {"/workspace/.git", "/workspace/.git/worktrees/topic"}
            local codex = assert(git_roots.arguments("codex_workspace_write", roots))
            test.eq(#codex, 2)
            test.eq(codex[1], "--config")
            test.eq(codex[2], 'sandbox_workspace_write.writable_roots=["/workspace/.git","/workspace/.git/worktrees/topic"]')
            test.is_true(git_roots.enabled("codex_workspace_write", {"exec", "--sandbox", "workspace-write"}))
            test.is_false(git_roots.enabled("codex_workspace_write", {"exec", "--sandbox", "read-only"}))
            local claude = assert(git_roots.arguments("claude_add_dir", roots))
            test.eq(#claude, 4)
            test.eq(claude[1], "--add-dir")
            test.eq(claude[2], roots[1])
            test.eq(claude[3], "--add-dir")
            test.eq(claude[4], roots[2])
            test.is_true(git_roots.enabled("claude_add_dir", {"--permission-mode", "default"}))
            test.is_false(git_roots.enabled("claude_add_dir", {"--permission-mode", "plan"}))
            local agy = assert(git_roots.arguments("agy_add_dir", roots))
            test.eq(#agy, #claude)
            for index, argument in ipairs(claude) do test.eq(agy[index], argument) end
            test.is_true(git_roots.enabled("agy_add_dir", {"--sandbox"}))
            test.is_false(git_roots.enabled("agy_add_dir", {"--model", "flash"}))
        end)
        test.it("rejects malformed Git pointers instead of guessing a writable location", function()
            local exists, is_directory, read_file = filesystem({["/workspace/wt/.git"] = "other: /tmp/git\n"}, {})
            local found, err = git_roots.detect("/workspace/wt", exists, is_directory, read_file)
            test.is_nil(found)
            test.eq(err, ".git file must contain one gitdir path")
        end)
    end)
end

return test.run_cases(define_tests)
