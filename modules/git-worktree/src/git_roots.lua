-- MIT. Resolve Git metadata directories that an edit-capable CLI
-- needs when its admitted working directory is a repository or worktree.
-- Paths come from Git's small metadata files; no shell or Git process runs.
local M = {}
M.MAX_PATH_BYTES = 8192
M.MAX_METADATA_BYTES = 4096
type ReadFile = (string) -> (string?, string?)
type Exists = (string) -> (boolean?, string?)
type IsDirectory = (string) -> (boolean?, string?)

function M.normalize(path: string, base: string?): (string?, string?)
    if path == "" or #path > M.MAX_PATH_BYTES or path:find("[%c]") then return nil, "Git metadata path is invalid" end
    if path:sub(1, 1) ~= "/" then
        if not base or base:sub(1, 1) ~= "/" then return nil, "Git metadata path has no absolute base" end
        path = base .. "/" .. path
    end
    local parts: {string} = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 then parts[#parts] = nil end
        elseif part ~= "." and part ~= "" then
            parts[#parts + 1] = part
        end
    end
    local normalized = "/" .. table.concat(parts, "/")
    if #normalized > M.MAX_PATH_BYTES then return nil, "Git metadata path is too long" end
    return normalized, nil
end

local function metadata_path(content: string?, label: string): (string?, string?)
    if type(content) ~= "string" or #content == 0 or #content > M.MAX_METADATA_BYTES then
        return nil, label .. " is empty or too large"
    end
    local value = (content :: string):gsub("[\r\n]+$", "")
    if value == "" or value:find("[%c]") then return nil, label .. " is malformed" end
    return value, nil
end

local function required_directory(path: string, is_directory: IsDirectory, label: string): string?
    local directory, err = is_directory(path)
    if err then return "inspect " .. label .. ": " .. err end
    if directory ~= true then return label .. " is not a directory" end
    return nil
end

local function parent(path: string): string
    if path == "/" then return "/" end
    local value = path:match("^(.*)/[^/]+$") or "/"
    return value == "" and "/" or value
end

function M.find_repository(workdir: string, exists: Exists): (string?, string?)
    local absolute_workdir, workdir_error = M.normalize(workdir, nil)
    if not absolute_workdir then return nil, workdir_error end
    local repository = absolute_workdir
    local marker = repository == "/" and "/.git" or repository .. "/.git"
    while true do
        local present, exists_error = exists(marker)
        if exists_error then return nil, "inspect .git: " .. exists_error end
        if present == true then return repository, nil end
        if repository == "/" then return nil, nil end
        repository = parent(repository)
        marker = repository == "/" and "/.git" or repository .. "/.git"
    end
end

function M.detect(workdir: string, exists: Exists, is_directory: IsDirectory, read_file: ReadFile): ({string}?, string?)
    local absolute_workdir, workdir_error = M.normalize(workdir, nil)
    if not absolute_workdir then return nil, workdir_error end
    local repository, repository_error = M.find_repository(absolute_workdir, exists)
    if repository_error then return nil, repository_error end
    if not repository then return {}, nil end
    local marker = repository == "/" and "/.git" or repository .. "/.git"

    local marker_is_directory, marker_error = is_directory(marker)
    if marker_error then return nil, "inspect .git: " .. marker_error end
    local git_dir: string
    if marker_is_directory == true then
        git_dir = marker
    else
        local content, read_error = read_file(marker)
        if not content then return nil, "read .git: " .. tostring(read_error or "unavailable") end
        local line, line_error = metadata_path(content, ".git file")
        if not line then return nil, line_error end
        local target = line:match("^gitdir: (.+)$")
        if not target then return nil, ".git file must contain one gitdir path" end
        local resolved, path_error = M.normalize(target, repository)
        if not resolved then return nil, path_error end
        git_dir = resolved
    end
    local git_error = required_directory(git_dir, is_directory, "Git directory")
    if git_error then return nil, git_error end

    local common_marker = git_dir .. "/commondir"
    local common_present, common_exists_error = exists(common_marker)
    if common_exists_error then return nil, "inspect commondir: " .. common_exists_error end
    local common_dir = git_dir
    if common_present == true then
        local content, read_error = read_file(common_marker)
        if not content then return nil, "read commondir: " .. tostring(read_error or "unavailable") end
        local target, target_error = metadata_path(content, "commondir")
        if not target then return nil, target_error end
        local resolved, path_error = M.normalize(target, git_dir)
        if not resolved then return nil, path_error end
        common_dir = resolved
    end
    local common_error = required_directory(common_dir, is_directory, "Git common directory")
    if common_error then return nil, common_error end

    local result: {string} = {git_dir}
    if common_dir ~= git_dir then result[2] = common_dir end
    table.sort(result)
    return result, nil
end

local function contains(root: string, path: string): boolean
    if root == "/" then return path:sub(1, 1) == "/" end
    return path == root or path:sub(1, #root + 1) == root .. "/"
end

function M.writable_roots(paths: {string}, write_roots: {string}): ({string}?, string?)
    local admitted: {string} = {}
    for _, raw_root in ipairs(write_roots) do
        local root, root_error = M.normalize(raw_root, nil)
        if not root then return nil, "write-granted root is invalid: " .. tostring(root_error) end
        admitted[#admitted + 1] = root
    end
    local result: {string} = {}
    local seen: {[string]: boolean} = {}
    for _, raw_path in ipairs(paths) do
        local path, path_error = M.normalize(raw_path, nil)
        if not path then return nil, "Git writable root is invalid: " .. tostring(path_error) end
        local allowed = false
        for _, root in ipairs(admitted) do
            if contains(root, path) then allowed = true; break end
        end
        -- Git metadata may live above or beside the writable workdir. In that
        -- case the host must not widen the CLI sandbox, but it need not refuse
        -- an otherwise valid launch.
        if not allowed then return {}, nil end
        if not seen[path] then
            seen[path] = true
            result[#result + 1] = path
        end
    end
    table.sort(result)
    return result, nil
end

return M
