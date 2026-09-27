-- MIT. Tests for workdir preparers extension point, discovery, setup, and cleanup.
local test = require("test")
local time = require("time")
local exec = require("exec")
local json = require("json")
local funcs = require("funcs")
local workdir_preparers = require("workdir_preparers")
local store = require("store")
local request_codec = require("request_codec")
local quote = require("quote")
local types = require("types")

local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end

local function run_cmd(args: {string}): (string?, integer?, string?)
    local executor, exec_err = exec.get("bee.git_worktree:git_executor")
    if not executor then return nil, 1, "no executor: " .. tostring(exec_err) end
    local proc, err = executor:exec(quote.line(args), {})
    if not proc then return nil, 1, tostring(err) end
    local out = proc:stdout_stream()
    local started, start_err = proc:start()
    if not started then return nil, 1, tostring(start_err) end
    local data = out:read(65536)
    local code = proc:wait()
    local exit_code: integer = type(code) == "number" and math.floor(code :: number) or 0
    return data and tostring(data) or "", exit_code, nil
end

local function temp_dir(): string
    local dir = "/tmp/bee-test-preparer-" .. fresh("dir")
    run_cmd({"mkdir", "-p", dir})
    return dir
end

local function cleanup_dir(dir: string)
    run_cmd({"rm", "-rf", dir})
end

local function init_repo(dir: string)
    run_cmd({"git", "init", "-b", "main", dir})
    run_cmd({"git", "-C", dir, "config", "user.name", "Preparer Tester"})
    run_cmd({"git", "-C", dir, "config", "user.email", "preparer@example.test"})
    run_cmd({"git", "-C", dir, "config", "commit.gpgsign", "false"})
    run_cmd({"sh", "-c", "echo base > " .. dir .. "/base.txt"})
    run_cmd({"git", "-C", dir, "add", "base.txt"})
    run_cmd({"git", "-C", dir, "commit", "-m", "initial commit"})
end

local function make_request(attempt_id: string, options: {[string]: any}?): types.LaunchRequest
    local env_names: {string} = {}
    local argv_list: {string} = {"worker"}
    local req: types.LaunchRequest = {
        idempotency_key = fresh("key"),
        owner_id = "bee.test.owner",
        owner_incarnation = 1,
        action_id = fresh("action"),
        attempt_id = attempt_id,
        binding_ref = "bee.driver.codex:binding",
        policy_ref = "bee.placement.native:test_launch_policy",
        profile_id = "session",
        binding_digest = string.rep("c", 64),
        profile_digest = string.rep("c", 64),
        options = options,
        launch = {
            executable = "codex",
            argv = argv_list,
            environment = env_names,
            readiness = "protocol:system.init",
        },
        resources = {},
        environment = {},
        environment_refs = {},
        projections = {},
        required_cleanup = "direct_process",
        required_exit_observation = "eof_gated",
        timeouts = {start_ms = 10000, stop_grace_ms = 500, drain_ms = 1000, retain_ms = 1000},
    }
    return req
end

local function claim_attempt(db, request: types.LaunchRequest)
    local digest, digest_error = request_codec.digest(request)
    if not digest then error(tostring(digest_error)) end
    local encoded, encode_error = json.encode(request)
    if not encoded then error(tostring(encode_error)) end
    local intended = store.intend(db, request, digest, encoded,
        {capability = "direct_process", exit_observation = "eof_gated"})
    if not intended.ok then error(tostring(intended.message)) end
    local starting = store.transition(db, request.attempt_id, {
        expected_execution = "intended",
        execution = "starting",
        evidence = {kind = "test.started", detail = "test setup"},
    })
    if not starting.ok then error(tostring(starting.message)) end
end

local function define_tests()
    test.describe("Workdir preparers extension point", function()
        test.it("discovers and authorizes registered preparers", function()
            local preparers, err = workdir_preparers.authorized_preparers()
            if not preparers then error(tostring(err)) end
            test.is_true(#preparers >= 1)
            local found_git_wt = false
            for _, p in ipairs(preparers) do
                if p.binding_id == "bee.git_worktree:binding" then
                    found_git_wt = true
                    test.eq(p.setup, "bee.git_worktree:setup")
                    test.eq(p.cleanup, "bee.git_worktree:cleanup")
                end
            end
            test.is_true(found_git_wt)
        end)

        test.it("prepares dedicated worktree and cleans it up after child exit", function()
            local repo = temp_dir()
            init_repo(repo)
            local db, open_err = store.open()
            if not db then error(tostring(open_err)) end

            local attempt_id = fresh("att-prep")
            local req = make_request(attempt_id, {worktree = "dedicated"})
            claim_attempt(db, req)

            local work_dir, extra_roots, prep_err = workdir_preparers.setup(db, req, attempt_id, repo, {repo})
            if not work_dir then error(tostring(prep_err)) end
            test.is_true(work_dir ~= repo)
            test.is_true(work_dir:sub(1, #repo) == repo)
            test.is_true(extra_roots ~= nil and #extra_roots >= 1)

            -- Check that state evidence was written
            local rows, q_err = db:query("SELECT kind, detail FROM bee_placement_evidence WHERE attempt_id = ? AND kind = 'workdir_preparer.state'", {attempt_id})
            if q_err or not rows then error(tostring(q_err)) end
            test.eq(#rows, 1)

            -- Transition attempt to exited so cleanup can proceed
            store.transition(db, attempt_id, {
                execution = "exited",
                fields = {exit_code = 0, exit_source = "runner"},
                evidence = {kind = "child.exited", detail = "exit code 0"},
            })

            local att, att_err = store.attempt(db, attempt_id)
            if not att then error(tostring(att_err)) end
            db:release()

            local cleaned, clean_err = workdir_preparers.cleanup(att)
            if not cleaned then error(tostring(clean_err)) end

            -- Verify worktree directory was removed
            local _, wt_stat_code = run_cmd({"test", "-d", work_dir})
            test.is_true(wt_stat_code ~= 0)

            local check_db, check_db_err = store.open()
            if not check_db then error(tostring(check_db_err)) end
            local cleaned_rows, c_err = check_db:query("SELECT kind FROM bee_placement_evidence WHERE attempt_id = ? AND kind = 'workdir_preparer.cleaned'", {attempt_id})
            check_db:release()
            if c_err or not cleaned_rows then error(tostring(c_err)) end
            test.eq(#cleaned_rows, 1)

            cleanup_dir(repo)
        end)

        test.it("retains dedicated worktree when dirty changes exist on cleanup", function()
            local repo = temp_dir()
            init_repo(repo)
            local db, open_err = store.open()
            if not db then error(tostring(open_err)) end

            local attempt_id = fresh("att-dirty")
            local req = make_request(attempt_id, {worktree = "dedicated"})
            claim_attempt(db, req)

            local work_dir, extra_roots, prep_err = workdir_preparers.setup(db, req, attempt_id, repo, {repo})
            if not work_dir then error(tostring(prep_err)) end

            -- Introduce uncommitted change in workdir
            run_cmd({"sh", "-c", "echo dirty > " .. work_dir .. "/dirty.txt"})

            store.transition(db, attempt_id, {
                execution = "exited",
                fields = {exit_code = 0, exit_source = "runner"},
                evidence = {kind = "child.exited", detail = "exit code 0"},
            })

            local att, att_err = store.attempt(db, attempt_id)
            if not att then error(tostring(att_err)) end
            db:release()

            local cleaned, clean_err = workdir_preparers.cleanup(att)
            if not cleaned then error(tostring(clean_err)) end

            -- Verify worktree directory is kept
            local _, wt_stat_code = run_cmd({"test", "-d", work_dir})
            test.eq(wt_stat_code, 0)

            local check_db, check_db_err = store.open()
            if not check_db then error(tostring(check_db_err)) end
            local retained_rows, r_err = check_db:query("SELECT kind, detail FROM bee_placement_evidence WHERE attempt_id = ? AND kind = 'workdir_preparer.retained'", {attempt_id})
            check_db:release()
            if r_err or not retained_rows then error(tostring(r_err)) end
            test.eq(#retained_rows, 1)

            cleanup_dir(repo)
        end)
    end)
end

return test.run_cases(define_tests)
