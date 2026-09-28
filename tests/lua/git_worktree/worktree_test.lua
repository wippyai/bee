-- MIT. Tests for Git worktree dedicated creation, status detection, and cleanup.
local test = require("test")
local time = require("time")
local worktree = require("worktree")
local setup_method = require("setup_method")
local cleanup_method = require("cleanup_method")
local funcs = require("funcs")
local security = require("security")

local function unauthorized_call(target: string, request: {[string]: unknown}): {[string]: unknown}
    local policy, policy_error = security.policy("bee.git_worktree.test:caller_policy")
    if not policy then error("caller policy: " .. tostring(policy_error)) end
    local reply, err = funcs.new():with_actor(security.new_actor("intruder", {})):with_scope(security.new_scope({policy})):call(target, request)
    if err then error("call " .. target .. ": " .. tostring(err)) end
    return reply :: {[string]: unknown}
end

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

        test.it("rejects unsafe attempt paths before creating anything", function()
            local repo = temp_dir()
            init_repo(repo)
            for _, id in ipairs({"../escape", "x/../../escape", "--bad", "a b"}) do
                local path, _, _, err = worktree.create_dedicated(repo, id, {repo})
                test.is_nil(path)
                test.not_nil(err)
            end
            cleanup_dir(repo)
        end)

        test.it("rejects a symlinked worktree parent outside the grant", function()
            local repo, outside = temp_dir(), temp_dir()
            init_repo(repo)
            worktree.run_git({"ln", "-s", outside, repo .. "/.worktrees"})
            local path, _, _, err = worktree.create_dedicated(repo, "escape", {repo})
            test.is_nil(path)
            test.not_nil(err)
            cleanup_dir(repo)
            cleanup_dir(outside)
        end)

        test.it("cleanup is idempotent and requires complete ownership evidence", function()
            local repo = temp_dir()
            init_repo(repo)
            local path, _, state, err = worktree.create_dedicated(repo, "repeat", {repo})
            test.is_nil(err)
            test.not_nil(path)
            local retained, _, first_error = worktree.cleanup_dedicated(state)
            test.is_false(retained)
            test.is_nil(first_error)
            local again, _, second_error = worktree.cleanup_dedicated(state)
            test.is_false(again)
            test.is_nil(second_error)
            local _, _, invalid = worktree.cleanup_dedicated({repository = repo, worktree_path = repo, branch = "main"})
            test.not_nil(invalid)
            cleanup_dir(repo)
        end)

        test.it("retains detached commits even when the original branch is merged", function()
            local repo = temp_dir()
            init_repo(repo)
            local path, _, state = worktree.create_dedicated(repo, "detached", {repo})
            if not path then error("setup failed") end
            worktree.run_git({"git", "-C", path, "switch", "--detach"})
            worktree.run_git({"git", "-C", path, "-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "--allow-empty", "-m", "detached work"})
            local retained, _, err = worktree.cleanup_dedicated(state)
            test.is_true(retained)
            test.is_nil(err)
            cleanup_dir(repo)
        end)

        test.it("replays a durable plan and retains ignored files and locked worktrees", function()
            local repo = temp_dir()
            init_repo(repo)
            local plan = assert(worktree.plan_dedicated(repo, "replay", {repo}))
            local path = assert(worktree.apply_dedicated(plan, {repo}))
            test.eq(worktree.apply_dedicated(plan, {repo}), path)
            worktree.run_git({"git", "-C", repo, "worktree", "lock", path})
            local _, _, err = worktree.cleanup_dedicated(plan)
            test.not_nil(err)
            worktree.run_git({"git", "-C", repo, "worktree", "unlock", path})
            worktree.run_git({"sh", "-c", 'printf "ignored\\n" >> "$1/.git/info/exclude"; touch "$2/ignored"', "fixture", repo, path})
            local retained, _, ignored_error = worktree.cleanup_dedicated(plan)
            test.is_true(retained)
            test.is_nil(ignored_error)
            cleanup_dir(repo)
        end)

        test.it("refuses preexisting names and write grants that omit Git metadata", function()
            local repo = temp_dir()
            init_repo(repo)
            worktree.run_git({"mkdir", repo .. "/subdir"})
            local plan, err = worktree.plan_dedicated(repo .. "/subdir", "restricted", {repo .. "/subdir"})
            test.is_nil(plan); test.not_nil(err)
            worktree.run_git({"git", "-C", repo, "branch", "bee-worker-existing"})
            plan, err = worktree.plan_dedicated(repo, "existing", {repo})
            test.is_nil(plan); test.not_nil(err)
            cleanup_dir(repo)
        end)

        test.it("passes shell metacharacters in workdirs as literal arguments", function()
            local root = temp_dir()
            local repo = root .. "/repo"
            worktree.run_git({"mkdir", repo})
            init_repo(repo)
            local literal = root .. "/repo '$(touch escaped)'"
            worktree.run_git({"mv", repo, literal})
            local path, _, state, err = worktree.create_dedicated(literal, "quoted", {root})
            test.is_nil(err); test.not_nil(path)
            local retained, _, cleanup_error = worktree.cleanup_dedicated(state)
            test.is_false(retained); test.is_nil(cleanup_error)
            cleanup_dir(root)
        end)

        test.it("cleans an unapplied plan and refuses a replaced worktree path", function()
            local repo, outside = temp_dir(), temp_dir()
            init_repo(repo)
            local plan = assert(worktree.plan_dedicated(repo, "planned", {repo}))
            local retained, _, err = worktree.cleanup_dedicated(plan)
            test.is_false(retained); test.is_nil(err)
            local path = assert(worktree.apply_dedicated(plan, {repo}))
            worktree.run_git({"mv", path, path .. "-saved"})
            worktree.run_git({"ln", "-s", outside, path})
            retained, _, err = worktree.cleanup_dedicated(plan)
            test.is_nil(retained); test.not_nil(err)
            local _, present = worktree.run_git({"test", "-d", outside})
            test.eq(present, 0)
            cleanup_dir(repo); cleanup_dir(outside)
        end)

        test.it("refuses administrative pointers borrowed from another worktree", function()
            local repo = temp_dir()
            init_repo(repo)
            local first, _, state = worktree.create_dedicated(repo, "first", {repo})
            local second = worktree.create_dedicated(repo, "second", {repo})
            if not first or not second then error("fixture worktrees missing") end
            worktree.run_git({"cp", second .. "/.git", first .. "/.git"})
            worktree.run_git({"git", "-C", second, "symbolic-ref", "HEAD", "refs/heads/bee-worker-first"})
            local retained, _, err = worktree.cleanup_dedicated(state)
            test.is_nil(retained)
            test.contains(tostring(err), "backreference")
            local _, present = worktree.run_git({"test", "-d", second})
            test.eq(present, 0)
            cleanup_dir(repo)
        end)

        test.it("retains dirty files hidden by assume-unchanged or skip-worktree", function()
            local repo = temp_dir()
            init_repo(repo)
            for index, flag in ipairs({"--assume-unchanged", "--skip-worktree"}) do
                local path, _, state = worktree.create_dedicated(repo, "hidden-" .. tostring(index), {repo})
                if not path then error("fixture worktree missing") end
                worktree.run_git({"git", "-C", path, "update-index", flag, "base.txt"})
                worktree.run_git({"sh", "-c", 'printf "dirty" > "$1/base.txt"', "fixture", path})
                local retained, reason, err = worktree.cleanup_dedicated(state)
                test.is_true(retained); test.is_nil(err)
                test.contains(tostring(reason), "index suppresses")
                local _, present = worktree.run_git({"test", "-f", path .. "/base.txt"})
                test.eq(present, 0)
            end
            cleanup_dir(repo)
        end)

        test.it("encodes harness attempt identifiers as bounded distinct names", function()
            local repo = temp_dir()
            init_repo(repo)
            local id = "attempt:request:worker"
            local plan = assert(worktree.plan_dedicated(repo, id, {repo}))
            local replay = assert(worktree.plan_dedicated(repo, id, {repo}))
            test.eq(plan.worktree_path, replay.worktree_path)
            test.eq(plan.attempt_id, id)
            local component = assert(plan.worktree_path:match("([^/]+)$"))
            test.eq(#component, 65)
            test.not_nil(component:match("^_%x+$"))
            test.eq(plan.branch, "bee-worker-" .. component)
            local path = assert(worktree.apply_dedicated(plan, {repo}))
            test.eq(path, plan.worktree_path)
            local retained, _, err = worktree.cleanup_dedicated(plan)
            test.is_false(retained); test.is_nil(err)
            cleanup_dir(repo)
        end)

        test.it("refuses preparer calls from callers without placement authority", function()
            local repo = temp_dir()
            init_repo(repo)
            local request = {attempt_id = "test-att-denied", owner_id = "intruder", working_directory = repo,
                write_roots = {repo}, options = {worktree = "dedicated"}, argv = {"test"}}
            local planned = unauthorized_call("bee.git_worktree:plan", request)
            test.is_false(planned.ok)
            test.eq((planned.error :: {[string]: unknown}).code, "DENIED")
            local setup_res = unauthorized_call("bee.git_worktree:setup", request)
            test.is_false(setup_res.ok)
            test.eq((setup_res.error :: {[string]: unknown}).code, "DENIED")
            local state = assert(worktree.plan_dedicated(repo, "test-att-denied", {repo}))
            local cleanup_res = unauthorized_call("bee.git_worktree:cleanup", {attempt_id = "test-att-denied", owner_id = "intruder", state = state})
            test.is_false(cleanup_res.ok)
            test.eq((cleanup_res.error :: {[string]: unknown}).code, "DENIED")
            local _, present = worktree.run_git({"test", "-e", state.worktree_path})
            test.eq(present, 1)
            cleanup_dir(repo)
        end)

        test.it("handles setup and cleanup via contract method handlers", function()
            local repo = temp_dir()
            init_repo(repo)
            local attempt_id = "test-att-handler"

            local planned = setup_method.plan({attempt_id = attempt_id, working_directory = repo,
                write_roots = {repo}, options = {worktree = "dedicated"}})
            test.is_true(planned.ok)
            local setup_res = setup_method.handle({
                state = planned.value.state,
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
