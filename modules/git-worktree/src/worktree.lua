-- MIT. Git worktree management: detection, dedicated worktree creation,
-- unmerged status checking and cleanup.
local exec = require("exec")
local fs = require("fs")
local registry = require("registry")
local git_roots = require("git_roots")

local M = {}
M.DEFAULT_EXECUTOR = "bee.git_worktree:git_executor"
M.DEFAULT_HOST_FILES = "bee.git_worktree:host_files"

local function quote_posix(argument: string): string
    if #argument > 0 and not argument:find("[^%w%._/:=@%-]") then return argument end
    return "'" .. argument:gsub("'", "'\\''") .. "'"
end

local function quote_line(argv: {string}): string
    local parts: {string} = {}
    for index, argument in ipairs(argv) do parts[index] = quote_posix(argument) end
    return table.concat(parts, " ")
end

local function resolve_resource(ref_name: string, default_val: string): string
    local entry, err = registry.get(ref_name)
    if not err and entry and type(entry.data) == "table" and type(entry.data.resource_ref) == "string" and entry.data.resource_ref ~= "" then
        return entry.data.resource_ref
    end
    return default_val
end

function M.run_git(args: {string}, executor_override: string?): (string?, integer?, string?)
    local executor_ref = executor_override or resolve_resource("bee.git_worktree:executor_ref", M.DEFAULT_EXECUTOR)
    local executor, executor_error = exec.get(executor_ref)
    if not executor then return nil, nil, "executor " .. executor_ref .. " unavailable: " .. tostring(executor_error) end
    local proc, exec_error = executor:exec(quote_line(args))
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
    local out_chunks: {string} = {}
    while true do
        local chunk = stdout:read(4096)
        if not chunk or chunk == "" then break end
        out_chunks[#out_chunks + 1] = tostring(chunk)
    end
    stdout:close()
    local err_chunks: {string} = {}
    if stderr then
        while true do
            local chunk = stderr:read(4096)
            if not chunk or chunk == "" then break end
            err_chunks[#err_chunks + 1] = tostring(chunk)
        end
        stderr:close()
    end
    local code, wait_error = proc:wait()
    executor:release()
    if wait_error then return nil, nil, "wait failed: " .. tostring(wait_error) end
    local exit_code = (type(code) == "number") and math.floor(code) or -1
    return table.concat(out_chunks), exit_code, table.concat(err_chunks)
end

function M.get_fs_volume(host_files_override: string?): (any?, string?)
    local host_files_ref = host_files_override or resolve_resource("bee.git_worktree:host_files_ref", M.DEFAULT_HOST_FILES)
    local volume, err = fs.get(host_files_ref)
    if not volume then return nil, "host files " .. host_files_ref .. " unavailable: " .. tostring(err) end
    return volume, nil
end

local function fs_helpers(volume: any)
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
    local volume, volume_err = M.get_fs_volume(host_files_override)
    if not volume then return nil, volume_err end
    local exists, is_directory, read_file = fs_helpers(volume)
    local detected, detect_error = git_roots.detect(workdir, exists, is_directory, read_file)
    if not detected then return nil, detect_error end
    return git_roots.writable_roots(detected, write_roots)
end

function M.create_dedicated(workdir: string, attempt_id: string, write_roots: {string}, executor_override: string?, host_files_override: string?): (string?, {string}?, any?, string?)
    local volume, volume_err = M.get_fs_volume(host_files_override)
    if not volume then return nil, nil, nil, volume_err end
    local exists, is_directory, read_file = fs_helpers(volume)

    local repo, repo_err = git_roots.find_repository(workdir, exists)
    if not repo then
        return nil, nil, nil, repo_err or ("no git repository found for working directory " .. workdir)
    end

    local branch = "bee-worker-" .. attempt_id
    local worktree_path = workdir .. "/.worktrees/" .. attempt_id

    local head_cmd: {string} = {"git", "-C", repo, "rev-parse", "HEAD"}
    local head_out, head_code, head_err = M.run_git(head_cmd, executor_override)
    if head_code ~= 0 or not head_out then
        return nil, nil, nil, "git rev-parse HEAD failed: " .. tostring(head_err or "exit " .. tostring(head_code))
    end
    local base_commit = head_out:gsub("%s+", "")

    local branch_cmd: {string} = {"git", "-C", repo, "symbolic-ref", "--short", "HEAD"}
    local branch_out, branch_code, _ = M.run_git(branch_cmd, executor_override)
    local base_ref = base_commit
    if branch_code == 0 and branch_out then
        local current_branch = branch_out:gsub("%s+", "")
        if current_branch ~= "" and current_branch ~= "HEAD" then
            base_ref = current_branch
        end
    end

    local add_cmd: {string} = {"git", "-C", repo, "worktree", "add", "-b", branch, worktree_path}
    local add_out, add_code, add_err = M.run_git(add_cmd, executor_override)
    if add_code ~= 0 then
        return nil, nil, nil, "git worktree add failed: " .. tostring(add_err or ("exit " .. tostring(add_code)))
    end

    local detected, detect_error = git_roots.detect(worktree_path, exists, is_directory, read_file)
    if not detected then
        local rm_cmd: {string} = {"git", "-C", repo, "worktree", "remove", "--force", worktree_path}
        local del_cmd: {string} = {"git", "-C", repo, "branch", "-D", branch}
        M.run_git(rm_cmd, executor_override)
        M.run_git(del_cmd, executor_override)
        return nil, nil, nil, "detect git roots for dedicated worktree: " .. tostring(detect_error)
    end
    local extra_roots, admit_error = git_roots.writable_roots(detected, write_roots)
    if not extra_roots then
        local rm_cmd: {string} = {"git", "-C", repo, "worktree", "remove", "--force", worktree_path}
        local del_cmd: {string} = {"git", "-C", repo, "branch", "-D", branch}
        M.run_git(rm_cmd, executor_override)
        M.run_git(del_cmd, executor_override)
        return nil, nil, nil, "admit git roots for dedicated worktree: " .. tostring(admit_error)
    end

    local state = {
        worktree_path = worktree_path,
        branch = branch,
        repository = repo,
        base_ref = base_ref,
    }
    return worktree_path, extra_roots, state, nil
end

function M.cleanup_dedicated(state: any, executor_override: string?): (boolean?, string?, string?)
    if type(state) ~= "table" then return false, nil, nil end
    local worktree_path = type(state.worktree_path) == "string" and state.worktree_path or nil
    local branch = type(state.branch) == "string" and state.branch or nil
    local repository = type(state.repository) == "string" and state.repository or nil
    local base_ref = type(state.base_ref) == "string" and state.base_ref or nil
    if not worktree_path or not branch or not repository then
        return false, nil, nil
    end

    local wt_path: string = worktree_path :: string
    local br: string = branch :: string
    local repo: string = repository :: string

    local status_cmd: {string} = {"git", "-C", wt_path, "status", "--porcelain"}
    local status_out, status_code, status_err = M.run_git(status_cmd, executor_override)
    if status_code ~= 0 then
        return nil, nil, "git status failed: " .. tostring(status_err or ("exit " .. tostring(status_code)))
    end
    if status_out and status_out:gsub("%s+", "") ~= "" then
        return true, "uncommitted changes in worktree", nil
    end

    if base_ref then
        local merge_cmd: {string} = {"git", "-C", repo, "merge-base", "--is-ancestor", br, base_ref :: string}
        local merge_out, merge_code, merge_err = M.run_git(merge_cmd, executor_override)
        if merge_code == 1 then
            return true, "unmerged commits on branch " .. br, nil
        elseif merge_code ~= 0 then
            return nil, nil, "git merge-base failed: " .. tostring(merge_err or ("exit " .. tostring(merge_code)))
        end
    end

    local rm_cmd: {string} = {"git", "-C", repo, "worktree", "remove", "--force", wt_path}
    local rm_out, rm_code, rm_err = M.run_git(rm_cmd, executor_override)
    if rm_code ~= 0 then
        return nil, nil, "git worktree remove failed: " .. tostring(rm_err or ("exit " .. tostring(rm_code)))
    end

    local branch_cmd: {string} = {"git", "-C", repo, "branch", "-D", br}
    M.run_git(branch_cmd, executor_override)
    return false, nil, nil
end

return M
