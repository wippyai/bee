-- MIT. Protocol and argument parsing for Files application.
-- Validates file targets, line ranges, and safe workspace paths.
-- Never admits private paths such as .wippy or traversal escapes.
local arguments = require("arguments")
local M = {}

local PRIVATE_PREFIX = ".wippy"
local MAX_PATH_LENGTH = 512

type Target = {
    path: string,
    line: integer?,
    end_line: integer?,
}

-- Verifies and normalizes a relative workspace subpath.
-- Disallows absolute paths, directory traversal, and private state trees.
function M.verify_path(raw: unknown): (string?, string?)
    if type(raw) ~= "string" or #raw == 0 then
        return nil, "path must be a non-empty string"
    end
    if #raw > MAX_PATH_LENGTH then
        return nil, "path exceeds maximum length"
    end
    if raw:find("[%c]") then
        return nil, "path contains control characters"
    end
    -- Disallow absolute paths
    if raw:sub(1, 1) == "/" or raw:sub(1, 1) == "\\" then
        return nil, "path must be relative to workspace root"
    end
    -- Normalize slashes and split segments
    local normalized = raw:gsub("\\", "/")
    -- Strip leading "./" if present
    while normalized:sub(1, 2) == "./" do
        normalized = normalized:sub(3)
    end
    -- Strip trailing "/" if present
    while #normalized > 1 and normalized:sub(-1) == "/" do
        normalized = normalized:sub(1, -2)
    end
    if normalized == "" or normalized == "." then
        return "", nil
    end

    local segments: {string} = {}
    for segment in normalized:gmatch("[^/]+") do
        if segment == ".." then
            return nil, "path cannot contain traversal (..)"
        end
        if segment ~= "." then
            segments[#segments + 1] = segment
        end
    end

    if #segments == 0 then
        return "", nil
    end

    -- Check for private state
    if segments[1] == PRIVATE_PREFIX or segments[1] == ".git" then
        return nil, "access to private state is denied"
    end

    return table.concat(segments, "/"), nil
end

local function parse_line_num(s: string?): integer?
    if not s then return nil end
    local n = tonumber(s)
    if n and n == math.floor(n) and n >= 1 and n <= 1000000 then
        return math.floor(n)
    end
    return nil
end

-- Decodes line range strings like "42", "42-50", "42:50".
function M.decode_range(raw: unknown): (integer?, integer?)
    if type(raw) ~= "string" or #raw == 0 then
        return nil, nil
    end
    local s1, s2 = raw:match("^(%d+)%s*[-:]%s*(%d+)$")
    if s1 and s2 then
        local start_line = parse_line_num(s1)
        local end_line = parse_line_num(s2)
        if start_line and end_line and end_line >= start_line then
            return start_line, end_line
        elseif start_line and end_line then
            return end_line, start_line
        end
    end
    local single = raw:match("^(%d+)$")
    if single then
        local line = parse_line_num(single)
        return line, nil
    end
    return nil, nil
end

-- Decodes launch arguments into a Target.
-- Supports:
--   {"path/to/file.lua"}
--   {"path/to/file.lua", "42"}
--   {"path/to/file.lua", "42-50"}
--   {"path/to/file.lua:42"}
--   {"path/to/file.lua:42-50"}
--   {"--file", "path/to/file.lua", "--line", "42", "--end-line", "50"}
function M.decode_target(args: {string}?): (Target?, string?)
    if not args or #args == 0 then
        return nil, nil
    end

    local file_path: string? = nil
    local line_str: string? = nil
    local end_line_str: string? = nil

    local index = 1
    while index <= #args do
        local arg = args[index]
        if arg == "--file" or arg == "-f" then
            index = index + 1
            file_path = args[index]
        elseif arg == "--line" or arg == "-l" then
            index = index + 1
            line_str = args[index]
        elseif arg == "--end-line" or arg == "-e" then
            index = index + 1
            end_line_str = args[index]
        elseif not file_path then
            file_path = arg
        elseif not line_str then
            line_str = arg
        end
        index = index + 1
    end

    if not file_path or file_path == "" then
        return nil, "no file specified in arguments"
    end

    -- Check if file_path has embedded line like "foo.lua:42" or "foo.lua:42-50"
    local embedded_path, embedded_range = file_path:match("^(.-):(%d+.*)$")
    if embedded_path and embedded_path ~= "" then
        file_path = embedded_path
        if not line_str then
            line_str = embedded_range
        end
    end

    local clean_path, path_err = M.verify_path(file_path)
    if not clean_path then
        return nil, path_err
    end

    local start_line: integer? = nil
    local end_line: integer? = nil

    if line_str then
        start_line, end_line = M.decode_range(line_str)
        if not start_line then return nil, "invalid line range" end
    end
    if end_line_str and not end_line then
        end_line = parse_line_num(end_line_str)
        if not end_line or not start_line or end_line < start_line then return nil, "invalid end line" end
    end

    return {
        path = clean_path,
        line = start_line,
        end_line = end_line,
    }, nil
end

-- Formats a target as a display string.
function M.format_target(target: Target): string
    if not target.line then
        return target.path
    end
    if target.end_line and target.end_line ~= target.line then
        return target.path .. ":" .. tostring(target.line) .. "-" .. tostring(target.end_line)
    end
    return target.path .. ":" .. tostring(target.line)
end

function M.decode_navigation(raw: unknown): Target?
    local args = arguments.decode(raw)
    if not args then return nil end
    local target = M.decode_target(args)
    if not target or target.path == "" then return nil end
    return target
end

return M
