-- MIT. Tests for workdir preparers extension point, discovery, setup, and cleanup.
local test = require("test")
local registry = require("registry")
local sql = require("sql")
local service = require("service")
local time = require("time")
local exec = require("exec")
local json = require("json")
local workdir_preparers = require("workdir_preparers")
local store = require("store")
local migrations = require("migrations")
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

local function make_request(attempt_id: string, options: types.WorkdirOptions?): types.LaunchRequest
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

local function with_preparer(config: {[string]: unknown}, body: () -> ())
    local host = registry.get("bee:workdir_preparers")
    local fixture = registry.get("bee.placement.native:preparer_fixture_config")
    if not host or not fixture then error("fixture configuration missing") end
    local original_host, original_config = host.data, fixture.data
    host.data = {preparers = {"bee.placement.native:preparer_fixture_binding"}}
    fixture.data = config
    local changes = registry.snapshot():changes()
    changes:update(host); changes:update(fixture)
    assert(changes:apply())
    local ok, err = pcall(body)
    host.data, fixture.data = original_host, original_config
    local restoration = registry.snapshot():changes()
    restoration:update(host); restoration:update(fixture)
    assert(restoration:apply())
    if not ok then error(tostring(err)) end
end

local function apply_legacy_preparer_backfill(db: sql.DB)
    for _, migration in ipairs(migrations.all()) do
        if migration.id == 7 then
            local _, err = db:execute(migration.sql)
            if err then error("apply legacy preparer backfill: " .. tostring(err)) end
        end
    end
end

local function define_tests()
    test.describe("Workdir preparers extension point", function()
        test.it("registry metadata alone never selects a preparer", function()
            local preparers = workdir_preparers.authorized_preparers()
            if not preparers then error("resolve preparers") end
            for _, item in ipairs(preparers) do test.is_true(item.binding_id ~= "bee.placement.native:preparer_fixture_binding") end
        end)

        test.it("rejects escaped roots and workdirs and preserves cleanup intent", function()
            local root, outside = temp_dir(), temp_dir()
            run_cmd({"ln", "-s", outside, root .. "/escape"})
            for _, output in ipairs({{extra_writable_roots = {root .. "/../" .. outside:match("[^/]+$")}},
                {extra_writable_roots = {root .. "/escape"}}, {working_directory = outside},
                {extra_writable_roots = {17}}, {extra_writable_roots = "invalid"}}) do
                with_preparer(output, function()
                    local db = assert(store.open())
                    local req = make_request(fresh("escape"))
                    claim_attempt(db, req)
                    local dir, _, err = workdir_preparers.setup(db, req, req.attempt_id, root, {root})
                    test.is_nil(dir)
                    test.not_nil(err)
                    local intents = assert(db:query("SELECT detail FROM bee_placement_evidence WHERE attempt_id = ? AND kind = 'workdir_preparer.state'", {req.attempt_id}))
                    test.eq(#intents, 1)
                    store.transition(db, req.attempt_id, {execution = "exited", fields = {exit_source = "runner"}, evidence = {kind = "test.exited", detail = "fixture exit"}})
                    local attempt = assert(store.attempt(db, req.attempt_id))
                    db:release()
                    test.is_true(workdir_preparers.cleanup(attempt))
                end)
            end
            cleanup_dir(root); cleanup_dir(outside)
        end)

        test.it("cleanup failures surface and a later call completes from evidence", function()
            local root = temp_dir()
            with_preparer({cleanup_failure = true}, function()
                local db = assert(store.open())
                local req = make_request(fresh("cleanup-fail"))
                claim_attempt(db, req)
                test.not_nil(workdir_preparers.setup(db, req, req.attempt_id, root, {root}))
                store.transition(db, req.attempt_id, {execution = "exited", fields = {exit_source = "runner"}, evidence = {kind = "test.exited", detail = "fixture exit"}})
                local attempt = assert(store.attempt(db, req.attempt_id))
                db:release()
                local result = service.cleanup_attempt(attempt)
                test.is_false(result.ok)
                test.contains(result.error.message, "fixture cleanup failure")
                local entry = assert(registry.get("bee.placement.native:preparer_fixture_config"))
                entry.data = {}
                local changes = registry.snapshot():changes(); changes:update(entry); assert(changes:apply())
                test.is_true(service.cleanup_attempt(attempt).ok)
            end)
            cleanup_dir(root)
        end)

        test.it("recovers a vanished runner before child creation and cleans via sweep", function()
            local repo = temp_dir()
            init_repo(repo)
            local db = assert(store.open())
            local req = make_request(fresh("crash"), {worktree = "dedicated"})
            claim_attempt(db, req)
            local path = assert(workdir_preparers.setup(db, req, req.attempt_id, repo, {repo}))
            local replay = assert(workdir_preparers.setup(db, req, req.attempt_id, repo, {repo}))
            test.eq(path, replay)
            store.transition(db, req.attempt_id, {fields = {runner_pid = "00000000-0000-0000-0000-000000000001"}, evidence = {kind = "test.crashed", detail = "absent fixture runner"}})
            local attempt = assert(store.attempt(db, req.attempt_id))
            local recovered = service.reconcile_attempt(attempt)
            test.is_true(recovered.ok)
            local ended = assert(store.attempt(db, req.attempt_id))
            test.eq(ended.execution_state, "exited")
            db:release()
            test.is_true(service.sweep().ok)
            local _, present = run_cmd({"test", "-e", path})
            test.is_true(present ~= 0)
            cleanup_dir(repo)
        end)

        test.it("requires an authorized preparer to consume requested options", function()
            local root = temp_dir()
            with_preparer({}, function()
                local db = assert(store.open())
                local req = make_request(fresh("unhandled"), {worktree = "dedicated"})
                claim_attempt(db, req)
                local path, _, err = workdir_preparers.setup(db, req, req.attempt_id, root, {root})
                test.is_nil(path)
                test.contains(tostring(err), "no authorized preparer handled option worktree")
                db:release()
            end)
            cleanup_dir(root)
        end)

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

            local attempt_id = fresh("attempt:prep")
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

        test.it("migrates legacy ownership JSON before settling workdir cleanup", function()
            local repo = temp_dir()
            init_repo(repo)
            local db = assert(store.open())
            local req = make_request(fresh("legacy-state"), {worktree = "dedicated"})
            claim_attempt(db, req)
            local work_dir, _, setup_error = workdir_preparers.setup(db, req, req.attempt_id, repo, {repo})
            if not work_dir then error(tostring(setup_error)) end
            local plans = assert(store.preparer_plans(db, req.attempt_id))
            test.eq(#plans, 1)
            local _, delete_error = db:execute("DELETE FROM bee_placement_preparer_states WHERE attempt_id = ?", {req.attempt_id})
            local _, update_error = db:execute([[UPDATE bee_placement_evidence SET detail = ?
                WHERE attempt_id = ? AND kind = 'workdir_preparer.state']], {plans[1].record_json, req.attempt_id})
            if delete_error or update_error then error("write legacy ownership fixture") end
            store.transition(db, req.attempt_id, {execution = "exited", fields = {exit_source = "runner"},
                evidence = {kind = "child.not_started", detail = "legacy preparer cleanup fixture"}})
            apply_legacy_preparer_backfill(db)
            local attempt = assert(store.attempt(db, req.attempt_id))
            db:release()

            local cleaned = service.cleanup_attempt(attempt, true)
            local _, stat = run_cmd({"test", "-d", work_dir})
            cleanup_dir(repo)
            test.is_true(cleaned.ok, "legacy workdir ownership did not clean")
            test.is_true(stat ~= 0, "legacy worktree remained after cleanup was settled")
        end)

        test.it("keeps truncated legacy ownership unresolved", function()
            local db = assert(store.open())
            local req = make_request(fresh("legacy-truncated"))
            claim_attempt(db, req)
            store.transition(db, req.attempt_id, {evidence = {kind = "workdir_preparer.state",
                detail = '{"binding_id":"bee.git_worktree:binding"'}})
            store.transition(db, req.attempt_id, {execution = "exited", fields = {exit_source = "runner"},
                evidence = {kind = "child.not_started", detail = "truncated legacy state fixture"}})
            apply_legacy_preparer_backfill(db)
            local attempt = assert(store.attempt(db, req.attempt_id))
            db:release()

            local cleaned = service.cleanup_attempt(attempt, true)
            local check = assert(store.open())
            local settled = assert(check:query("SELECT sequence FROM bee_placement_evidence WHERE attempt_id = ? AND kind = 'workdir_preparers.settled'", {req.attempt_id}))
            check:release()
            test.is_false(cleaned.ok, "truncated legacy state was treated as having no owner")
            test.eq(#settled, 0, "truncated legacy state was marked settled")
        end)

        test.it("keeps long ownership state whole through cleanup", function()
            local base = temp_dir()
            local repo = base .. "/" .. string.rep("a", 200) .. "/" .. string.rep("b", 200) .. "/" .. string.rep("c", 200)
            run_cmd({"mkdir", "-p", repo})
            init_repo(repo)
            local db = assert(store.open())
            local attempt_id = fresh("att-long")
            local req = make_request(attempt_id, {worktree = "dedicated"})
            claim_attempt(db, req)
            local work_dir, _, prep_err = workdir_preparers.setup(db, req, attempt_id, repo, {base})
            if not work_dir then error(tostring(prep_err)) end
            test.is_true(#work_dir * 3 > store.MAX_DETAIL_BYTES)
            store.transition(db, attempt_id, {execution = "exited", fields = {exit_code = 0, exit_source = "runner"},
                evidence = {kind = "child.exited", detail = "exit code 0"}})
            local att = assert(store.attempt(db, attempt_id))
            db:release()
            local cleaned, clean_err = workdir_preparers.cleanup(att)
            if not cleaned then error(tostring(clean_err)) end
            local _, present = run_cmd({"test", "-d", work_dir})
            test.is_true(present ~= 0)
            cleanup_dir(base)
        end)

        test.it("refuses to set up when the preparer's ownership state is too large to keep", function()
            local root = temp_dir()
            with_preparer({oversized_state = true}, function()
                local db = assert(store.open())
                local req = make_request(fresh("oversized"))
                claim_attempt(db, req)
                local dir, _, err = workdir_preparers.setup(db, req, req.attempt_id, root, {root})
                test.is_nil(dir)
                test.contains(tostring(err), "preparer state exceeds")
                local plans = assert(store.preparer_plans(db, req.attempt_id))
                test.eq(#plans, 0)
                db:release()
            end)
            cleanup_dir(root)
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
