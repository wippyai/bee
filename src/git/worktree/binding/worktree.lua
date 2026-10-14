-- MIT. Owned Git worktree lifecycle.
local exec = require("exec")
local fs = require("fs")
local registry = require("registry")
local git_roots = require("git_roots")
local paths = require("paths")
local bounds = require("bounds")
local quote = require("quote")
local hash = require("hash")
local channel = require("channel")

local M = {}
M.DEFAULT_EXECUTOR = "bee.git.worktree.env:git_executor"
M.DEFAULT_HOST_FILES = "bee.git.worktree.env:host_files"
M.MAX_STDOUT_BYTES = 16 * 1024 * 1024
M.MAX_STDERR_BYTES = 64 * 1024

local function resolve_resource(ref_name: string, default_val: string): string
    local entry, err = registry.get(ref_name)
    if not err and entry and type(entry.data) == "table" and type(entry.data.resource_ref) == "string" and entry.data.resource_ref ~= "" then
        return entry.data.resource_ref
    end
    return default_val
end

function M.run_git(args: {string}, executor_override: string?): (string?, integer?, string?)
    local executor_ref = executor_override or resolve_resource("bee.git.worktree.env:executor_ref", M.DEFAULT_EXECUTOR)
    local executor, executor_error = exec.get(executor_ref)
    if not executor then return nil, nil, "executor " .. executor_ref .. " unavailable: " .. tostring(executor_error) end
    local proc, exec_error = executor:exec(quote.line(args))
    if not proc then
        executor:release()
        return nil, nil, "exec failed: " .. tostring(exec_error)
    end
    local stdout = proc:stdout_stream()
    local stderr = proc:stderr_stream()
    local started, start_error = proc:start()
    if not started then
        executor:release()
        return nil, nil, "start failed: " .. tostring(start_error)
    end
    -- The child blocks on whichever pipe fills first, so both drain at once.
    local errors = channel.new(1)
    local err_chunks: {string} = {}
    local err_bytes = 0
    coroutine.spawn(function()
        while stderr do
            local chunk = stderr:read(4096)
            if not chunk or chunk == "" then break end
            if err_bytes < M.MAX_STDERR_BYTES then
                err_chunks[#err_chunks + 1] = tostring(chunk)
                err_bytes = err_bytes + #tostring(chunk)
            end
        end
        errors:send(true)
    end)
    local out_chunks: {string} = {}
    local out_bytes = 0
    while true do
        local chunk = stdout:read(4096)
        if not chunk or chunk == "" then break end
        out_bytes = out_bytes + #tostring(chunk)
        if out_bytes <= M.MAX_STDOUT_BYTES then out_chunks[#out_chunks + 1] = tostring(chunk) end
    end
    errors:receive()
    stdout:close()
    if stderr then stderr:close() end
    local code, wait_error = proc:wait()
    executor:release()
    local exit_code = (type(code) == "number") and math.floor(code) or nil
    local stderr_text = table.concat(err_chunks)
    if wait_error then return nil, exit_code, "wait failed: " .. tostring(wait_error) .. "; stderr: " .. stderr_text end
    if out_bytes > M.MAX_STDOUT_BYTES then
        return nil, exit_code, "git output exceeds " .. tostring(M.MAX_STDOUT_BYTES) .. " bytes; stderr: " .. stderr_text
    end
    return table.concat(out_chunks), exit_code, table.concat(err_chunks)
end

function M.get_fs_volume(host_files_override: string?): (fs.FS?, string?)
    local host_files_ref = host_files_override or resolve_resource("bee.git.worktree.env:host_files_ref", M.DEFAULT_HOST_FILES)
    local volume, err = fs.get(host_files_ref)
    if not volume then return nil, "host files " .. host_files_ref .. " unavailable: " .. tostring(err) end
    return volume, nil
end

local function fs_helpers(volume: fs.FS)
    local function exists(path: string): (boolean?, string?)
        local res = volume:exists(path)
        if res == true then return true, nil end
        if res == false then return false, nil end
        return nil, "not found"
    end
    local function is_directory(path: string): (boolean?, string?)
        local res = volume:isdir(path)
        if res == true then return true, nil end
        if res == false then return false, nil end
        return nil, "not a directory"
    end
    local function read_file(path: string): (string?, string?)
        local info, stat_error = volume:stat(path)
        if not info then return nil, tostring(stat_error or "unavailable") end
        if info.type ~= "file" or info.is_dir == true then return nil, "metadata path is not a file" end
        local size = math.floor(tonumber(info.size) or (git_roots.MAX_METADATA_BYTES + 1))
        if size < 0 or size > git_roots.MAX_METADATA_BYTES then return nil, "metadata file is too large" end
        local content = volume:readfile(path)
        if type(content) == "string" then return content, nil end
        return nil, "read file failed"
    end
    return exists, is_directory, read_file
end

function M.detect_git_roots(workdir: string, write_roots: {string}, host_files_override: string?): ({string}?, string?)
    if #write_roots == 0 then return {}, nil end
    local executor_ref = resolve_resource("bee.git.worktree.env:executor_ref", M.DEFAULT_EXECUTOR)
    local admitted_workdir = paths.admit(workdir, write_roots, executor_ref)
    if not admitted_workdir then return {}, nil end
    local volume, volume_err = M.get_fs_volume(host_files_override)
    if not volume then return nil, volume_err end
    local exists, is_directory, read_file = fs_helpers(volume)
    local detected, detect_error = git_roots.detect(admitted_workdir, exists, is_directory, read_file)
    if not detected then return nil, detect_error end
    local roots: {string} = {}
    for _, path in ipairs(detected) do
        local admitted = paths.admit(path, write_roots, executor_ref)
        if not admitted then return {}, nil end
        roots[#roots + 1] = admitted
    end
    return roots, nil
end

type State = {common_directory: string, attempt_id: string, working_directory: string, worktree_path: string, branch: string, repository: string, base_ref: string, base_commit: string}

local function valid_id(id: string): boolean
    return #id <= 128 and id:match("^[%w][%w_-]*$") ~= nil
end

local function path_component(id: string): string?
    if valid_id(id) then return id end
    if not bounds.id(id) or not id:match("^[%w][%w_.:%-]*$") then return nil end
    local digest = hash.sha256(id)
    return digest and ("_" .. digest) or nil
end

local function git(repo: string, args: {string}, executor: string?): (string?, integer?, string?)
    local command = {"git", "-C", repo, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false"}
    for _, arg in ipairs(args) do command[#command + 1] = arg end
    local output, code, err = M.run_git(command, executor)
    if output == nil or code ~= 0 then
        err = quote.line(command) .. " (exit " .. tostring(code) .. "): " .. tostring(err)
    end
    if output == nil then return nil, nil, err end
    return output and output:gsub("\n$", "") or nil, code, err
end

function M.decode_state(value: unknown): (State?, string?)
    local obj = bounds.object(value)
    if not obj then return nil, "missing ownership state" end
    local id = bounds.id(obj.attempt_id)
    local component = id and path_component(id) or nil
    local workdir = bounds.text(obj.working_directory, 8192)
    local path = bounds.text(obj.worktree_path, 8192)
    local branch = bounds.text(obj.branch, 200)
    local repo = bounds.text(obj.repository, 8192)
    local base = bounds.text(obj.base_ref, 1024)
    local commit = bounds.text(obj.base_commit, 64)
    local common = bounds.text(obj.common_directory, 8192)
    if not id or not component or not workdir or not path or not branch or not repo or not base or not commit or not common
        or path ~= workdir .. "/.worktrees/" .. component or branch ~= "bee-worker-" .. component
        or not commit:match("^%x+$") or (#commit ~= 40 and #commit ~= 64)
        or (base ~= commit and not base:match("^refs/heads/[^%c]+$")) then
        return nil, "invalid ownership state"
    end
    return {common_directory = common, attempt_id = id, working_directory = workdir, worktree_path = path, branch = branch,
        repository = repo, base_ref = base, base_commit = commit}, nil
end

local function predicate(args: {string}, executor: string): (boolean?, string?)
    local output, code, err = M.run_git(args, executor)
    if output ~= nil and code == 0 then return true, nil end
    if output ~= nil and code == 1 then return false, nil end
    return nil, quote.line(args) .. " (exit " .. tostring(code) .. "): " .. tostring(err)
end
local function branch_exists(repo: string, branch: string, executor: string): (boolean?, string?)
    local _, code, err = git(repo, {"show-ref", "--verify", "--quiet", "refs/heads/" .. branch}, executor)
    if code == 0 then return true, nil end
    if code == 1 then return false, nil end
    return nil, err
end

local function safe_parent(state: State, executor: string): string?
    for _, path in ipairs({state.repository, state.working_directory, state.common_directory}) do
        local physical, err = paths.resolve(path, executor)
        if physical ~= path then return err or "ownership directory changed" end
    end
    local parent = state.working_directory .. "/.worktrees"
    local exists, exists_error = predicate({"test", "-e", parent}, executor)
    if exists == nil then return exists_error end
    local linked, linked_error = predicate({"test", "-L", parent}, executor)
    if linked == nil then return linked_error end
    if linked then return "worktree parent is a symlink" end
    if exists then
        local physical, err = paths.resolve(parent, executor)
        if physical ~= parent then return err or "worktree parent changed" end
    end
    return nil
end

local function owned_identity_error(state: State, executor: string, host_files_override: string?): string?
    local physical = paths.resolve(state.worktree_path, executor)
    local top, top_code, top_error = git(state.worktree_path, {"rev-parse", "--show-toplevel"}, executor)
    if top_code ~= 0 then return top_error end
    if physical ~= state.worktree_path or top ~= physical then return "worktree identity changed" end
    local common, common_code, common_error = git(state.worktree_path, {"rev-parse", "--path-format=absolute", "--git-common-dir"}, executor)
    if common_code ~= 0 then return common_error end
    if not common or paths.resolve(common, executor) ~= state.common_directory then
        return "worktree repository identity changed"
    end
    local git_directory, directory_code, directory_error = git(state.worktree_path, {"rev-parse", "--absolute-git-dir"}, executor)
    if directory_code ~= 0 then return directory_error end
    if not git_directory or not paths.contains(state.common_directory .. "/worktrees", git_directory)
        or paths.resolve(git_directory, executor) ~= git_directory then
        return "worktree administrative directory changed"
    end
    local volume, volume_error = M.get_fs_volume(host_files_override)
    if not volume then return volume_error end
    local _, _, read_file = fs_helpers(volume)
    local backref, backref_error = read_file(git_directory .. "/gitdir")
    if not backref or backref:gsub("[\r\n]+$", "") ~= state.worktree_path .. "/.git" then
        return backref_error or "worktree backreference changed"
    end
    return nil
end

function M.plan_dedicated(workdir: string, attempt_id: string, write_roots: {string}, executor_override: string?): (State?, string?)
    local component = path_component(attempt_id)
    if not component then return nil, "unsafe attempt identifier" end
    local executor = executor_override or resolve_resource("bee.git.worktree.env:executor_ref", M.DEFAULT_EXECUTOR)
    local admitted, err = paths.admit(workdir, write_roots, executor)
    if not admitted then return nil, err end
    local repo, code, repo_error = git(admitted, {"rev-parse", "--show-toplevel"}, executor)
    if code ~= 0 or not repo then return nil, "resolve repository: " .. tostring(repo_error) end
    local base_commit, head_code, head_error = git(repo, {"rev-parse", "--verify", "HEAD"}, executor)
    if head_code ~= 0 or not base_commit then return nil, "repository has no HEAD: " .. tostring(head_error) end
    local base_ref, branch_code, branch_error = git(repo, {"symbolic-ref", "--quiet", "HEAD"}, executor)
    if branch_code ~= 0 and branch_code ~= 1 then return nil, branch_error end
    local metadata, metadata_code, metadata_error = git(repo, {"rev-parse", "--path-format=absolute", "--git-common-dir"}, executor)
    if metadata_code ~= 0 or not metadata then return nil, "cannot resolve Git common directory: " .. tostring(metadata_error) end
    local allowed, admission_error = paths.admit(metadata, write_roots, executor)
    if not allowed then return nil, admission_error end
    local state: State = {common_directory = allowed, attempt_id = attempt_id, working_directory = admitted, worktree_path = admitted .. "/.worktrees/" .. component,
        branch = "bee-worker-" .. component, repository = repo, base_ref = branch_code == 0 and base_ref or base_commit, base_commit = base_commit}
    local parent_error = safe_parent(state, executor)
    if parent_error then return nil, parent_error end
    local present, present_error = predicate({"test", "-e", state.worktree_path}, executor)
    if present == nil then return nil, present_error end
    local linked, linked_error = predicate({"test", "-L", state.worktree_path}, executor)
    if linked == nil then return nil, linked_error end
    local branch_present, branch_error = branch_exists(repo, state.branch, executor)
    if branch_present == nil then return nil, branch_error end
    if present or linked or branch_present then return nil, "worktree path or branch already exists" end
    return state, nil
end

function M.apply_dedicated(state: State, write_roots: {string}, executor_override: string?, host_files_override: string?): (string?, {string}?, State?, string?)
    local executor = executor_override or resolve_resource("bee.git.worktree.env:executor_ref", M.DEFAULT_EXECUTOR)
    for _, path in ipairs({state.working_directory, state.common_directory}) do
        local allowed, err = paths.admit(path, write_roots, executor)
        if allowed ~= path then return nil, nil, state, err or "planned directory no longer admitted" end
    end
    local parent_error = safe_parent(state, executor)
    if parent_error then return nil, nil, state, parent_error end
    local present, present_error = predicate({"test", "-e", state.worktree_path}, executor)
    if present == nil then return nil, nil, state, present_error end
    if present then
        local identity_error = owned_identity_error(state, executor, host_files_override)
        if identity_error then return nil, nil, state, identity_error end
    else
        local branch_present, branch_error = branch_exists(state.repository, state.branch, executor)
        if branch_present == nil then return nil, nil, state, branch_error end
        local args = {"worktree", "add"}
        if not branch_present then args[#args + 1] = "-b"; args[#args + 1] = state.branch end
        args[#args + 1] = "--"
        args[#args + 1] = state.worktree_path
        args[#args + 1] = branch_present and state.branch or state.base_commit
        local _, code, err = git(state.repository, args, executor)
        if code ~= 0 then return nil, nil, state, "git worktree add failed: " .. tostring(err) end
    end
    local physical, path_error = paths.resolve(state.worktree_path, executor)
    local branch, branch_code, branch_error = git(state.worktree_path, {"symbolic-ref", "--quiet", "HEAD"}, executor)
    if branch_code ~= 0 then return nil, nil, state, branch_error end
    if physical ~= state.worktree_path or branch ~= "refs/heads/" .. state.branch then
        return nil, nil, state, path_error or "worktree ownership changed"
    end
    local roots, err = M.detect_git_roots(state.worktree_path, write_roots, host_files_override)
    if not roots or #roots == 0 then return nil, nil, state, err or "Git metadata is outside write grants" end
    return state.worktree_path, roots, state, nil
end

function M.create_dedicated(workdir: string, attempt_id: string, write_roots: {string}, executor_override: string?, host_files_override: string?): (string?, {string}?, State?, string?)
    local state, err = M.plan_dedicated(workdir, attempt_id, write_roots, executor_override)
    if not state then return nil, nil, nil, err end
    return M.apply_dedicated(state, write_roots, executor_override, host_files_override)
end

function M.cleanup_dedicated(value: unknown, executor_override: string?): (boolean?, string?, string?)
    local state, state_error = M.decode_state(value)
    if not state then return nil, nil, state_error end
    local executor = executor_override or resolve_resource("bee.git.worktree.env:executor_ref", M.DEFAULT_EXECUTOR)
    local parent_error = safe_parent(state, executor)
    if parent_error then return nil, nil, parent_error end
    local linked, linked_error = predicate({"test", "-L", state.worktree_path}, executor)
    if linked == nil then return nil, nil, linked_error end
    if linked then return nil, nil, "owned worktree became a symlink" end
    local listing, list_code, list_error = git(state.repository, {"worktree", "list", "--porcelain"}, executor)
    if list_code ~= 0 or not listing then return nil, nil, "list worktrees: " .. tostring(list_error) end
    local registered = false
    for line in listing:gmatch("[^\n]+") do
        if line == "worktree " .. state.worktree_path then registered = true end
    end
    local exists, exists_error = predicate({"test", "-e", state.worktree_path}, executor)
    if exists == nil then return nil, nil, exists_error end
    if exists then
        if not registered then return nil, nil, "path is not the registered worktree" end
        local identity_error = owned_identity_error(state, executor)
        if identity_error then return nil, nil, identity_error end
        local branch, branch_code, branch_error = git(state.worktree_path, {"symbolic-ref", "--quiet", "HEAD"}, executor)
        if branch_code ~= 0 and branch_code ~= 1 then return nil, nil, branch_error end
        if branch_code == 1 or branch ~= "refs/heads/" .. state.branch then return true, "worktree HEAD changed; retained", nil end
        local tracked, tracked_code, tracked_error = git(state.worktree_path, {"ls-files", "-v", "-z"}, executor)
        if tracked_code ~= 0 or not tracked then return nil, nil, "inspect index: " .. tostring(tracked_error) end
        for record in tracked:gmatch("[^%z]+") do
            local flag = record:sub(1, 1)
            if flag == "S" or flag:match("%l") then return true, "index suppresses worktree change detection", nil end
        end
        local status, status_code, status_error = git(state.worktree_path, {"status", "--porcelain", "--untracked-files=all", "--ignored", "--ignore-submodules=none"}, executor)
        if status_code ~= 0 or not status then return nil, nil, "git status failed: " .. tostring(status_error) end
        if status ~= "" then return true, "uncommitted changes in worktree", nil end
        local _, merged, merge_error = git(state.worktree_path, {"merge-base", "--is-ancestor", "HEAD", state.base_ref}, executor)
        if merged == 1 then return true, "unmerged commits on branch " .. state.branch, nil end
        if merged ~= 0 then return nil, nil, "git merge-base failed: " .. tostring(merge_error) end
        local _, code, err = git(state.repository, {"worktree", "remove", "--", state.worktree_path}, executor)
        if code ~= 0 then return nil, nil, "git worktree remove failed: " .. tostring(err) end
    elseif registered then
        return nil, nil, "registered worktree is missing; retained for recovery"
    end
    local present_branch, branch_error = branch_exists(state.repository, state.branch, executor)
    if present_branch == nil then return nil, nil, branch_error end
    if not present_branch then return false, nil, nil end
    local _, merged, merge_error = git(state.repository, {"merge-base", "--is-ancestor", "refs/heads/" .. state.branch, state.base_ref}, executor)
    if merged == 1 then return true, "unmerged commits on branch " .. state.branch, nil end
    if merged ~= 0 then return nil, nil, "git merge-base failed: " .. tostring(merge_error) end
    local _, code, err = git(state.repository, {"branch", "-d", "--", state.branch}, executor)
    if code ~= 0 then return nil, nil, "git branch deletion failed: " .. tostring(err) end
    return false, nil, nil
end
return M
