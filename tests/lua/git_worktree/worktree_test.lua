-- MIT. Tests for Git worktree dedicated creation, status detection, and cleanup.
local test = require("test")
local time = require("time")
local worktree = require("worktree")
local setup_method = require("setup_method")
local cleanup_method = require("cleanup_method")

local counter = 0
local function temp_dir(): string
    counter = counter + 1
    local dir = "/tmp/bee-test-gitwt-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
    worktree.run_git({"mkdir", "-p", dir})
    return dir
end

local function cleanup_dir(dir: string)
    worktree.run_git({"rm", "-rf", dir})
end

local function init_repo(dir: string)
    local _, c1, e1 = worktree.run_git({"git", "init", "-b", "main", dir})
    if c1 ~= 0 then error("git init failed: " .. tostring(e1)) end
    worktree.run_git({"git", "-C", dir, "config", "user.name", "Test Worker"})
    worktree.run_git({"git", "-C", dir, "config", "user.email", "worker@example.test"})
    worktree.run_git({"git", "-C", dir, "config", "commit.gpgsign", "false"})
    worktree.run_git({"sh", "-c", "echo base > " .. dir .. "/base.txt"})
    worktree.run_git({"git", "-C", dir, "add", "base.txt"})
    local _, c2, e2 = worktree.run_git({"git", "-C", dir, "commit", "-m", "initial commit"})
    if c2 ~= 0 then error("git commit failed: " .. tostring(e2)) end
end

local function define_tests()
    test.describe("Git worktree dedicated lifecycle", function()
        test.it("creates a dedicated worktree and removes it when clean and merged", function()
            local repo = temp_dir()
            init_repo(repo)
            local attempt_id = "test-att-clean"
            local write_roots: {string} = {repo}

            local wt_path, extra_roots, state, err = worktree.create_dedicated(repo, attempt_id, write_roots)
            if err or not wt_path then
                cleanup_dir(repo)
                error("create_dedicated failed: " .. tostring(err))
            end

            test.eq(wt_path, repo .. "/.worktrees/" .. attempt_id)
            test.not_nil(extra_roots)
            test.eq(state.branch, "bee-worker-" .. attempt_id)
            test.eq(state.repository, repo)

            -- Cleanup when clean and no new commits -> should remove worktree
            local retained, reason, clean_err = worktree.cleanup_dedicated(state)
            if clean_err then
                cleanup_dir(repo)
                error("cleanup_dedicated failed: " .. tostring(clean_err))
            end
            test.is_false(retained)
            test.is_nil(reason)

            -- Verify worktree directory is gone
            local out, code, _ = worktree.run_git({"git", "-C", repo, "worktree", "list"})
            test.eq(code, 0)
            test.is_nil(out:find(wt_path, 1, true))

            cleanup_dir(repo)
        end)

        test.it("retains the worktree when there are uncommitted changes", function()
            local repo = temp_dir()
            init_repo(repo)
            local attempt_id = "test-att-dirty"
            local write_roots: {string} = {repo}

            local wt_path, _, state, err = worktree.create_dedicated(repo, attempt_id, write_roots)
            if err or not wt_path then
                cleanup_dir(repo)
                error("create_dedicated failed: " .. tostring(err))
            end

            -- Create uncommitted change in worktree
            worktree.run_git({"sh", "-c", "echo dirty > " .. wt_path .. "/dirty.txt"})

            local retained, reason, clean_err = worktree.cleanup_dedicated(state)
            if clean_err then
                cleanup_dir(repo)
                error("cleanup_dedicated failed: " .. tostring(clean_err))
            end
            test.is_true(retained)
            test.eq(reason, "uncommitted changes in worktree")

            -- Clean up manually
            worktree.run_git({"git", "-C", repo, "worktree", "remove", "--force", wt_path})
            local br = tostring(state.branch)
            local del_cmd: {string} = {"git", "-C", repo, "branch", "-D", br}
            worktree.run_git(del_cmd)
            cleanup_dir(repo)
        end)

        test.it("retains the worktree when there are unmerged commits on worker branch", function()
            local repo = temp_dir()
            init_repo(repo)
            local attempt_id = "test-att-unmerged"
            local write_roots: {string} = {repo}

            local wt_path, _, state, err = worktree.create_dedicated(repo, attempt_id, write_roots)
            if err or not wt_path then
                cleanup_dir(repo)
                error("create_dedicated failed: " .. tostring(err))
            end

            -- Commit on worker branch
            worktree.run_git({"sh", "-c", "echo change > " .. wt_path .. "/change.txt"})
            worktree.run_git({"git", "-C", wt_path, "add", "change.txt"})
            worktree.run_git({"git", "-C", wt_path, "commit", "-m", "worker commit"})

            local retained, reason, clean_err = worktree.cleanup_dedicated(state)
            if clean_err then
                cleanup_dir(repo)
                error("cleanup_dedicated failed: " .. tostring(clean_err))
            end
            test.is_true(retained)
            test.contains(tostring(reason), "unmerged commits")

            -- Now merge the worker branch into main
            local br = tostring(state.branch)
            local merge_cmd: {string} = {"git", "-C", repo, "merge", br}
            worktree.run_git(merge_cmd)

            -- Cleanup again -> now merged, should be removed
            local retained_after_merge, _, clean_after_err = worktree.cleanup_dedicated(state)
            if clean_after_err then
                cleanup_dir(repo)
                error("cleanup after merge failed: " .. tostring(clean_after_err))
            end
            test.is_false(retained_after_merge)

            cleanup_dir(repo)
        end)

        test.it("handles setup and cleanup via contract method handlers", function()
            local repo = temp_dir()
            init_repo(repo)
            local attempt_id = "test-att-handler"

            -- Setup with dedicated option
            local setup_res = setup_method.handle({
                attempt_id = attempt_id,
                owner_id = "test-owner",
                working_directory = repo,
                write_roots = {repo},
                options = {worktree = "dedicated"},
                argv = {"test"},
            })
            test.is_true(setup_res.ok)
            local val = setup_res.value
            test.eq(val.working_directory, repo .. "/.worktrees/" .. attempt_id)
            test.not_nil(val.state)

            -- Cleanup with clean worktree
            local cleanup_res = cleanup_method.handle({
                attempt_id = attempt_id,
                owner_id = "test-owner",
                state = val.state,
            })
            test.is_true(cleanup_res.ok)
            test.is_false(cleanup_res.value.retained)

            -- Setup without dedicated option (plain git roots detection)
            local plain_setup = setup_method.handle({
                attempt_id = "test-att-plain",
                owner_id = "test-owner",
                working_directory = repo,
                write_roots = {repo},
                argv = {"test"},
            })
            test.is_true(plain_setup.ok)
            test.is_nil(plain_setup.value.working_directory)
            test.not_nil(plain_setup.value.extra_writable_roots)
            test.is_nil(plain_setup.value.state)

            cleanup_dir(repo)
        end)
    end)
end

return test.run_cases(define_tests)
