-- MIT. .gitignore pattern matcher.
-- Parses .gitignore rules and determines if a file or directory is ignored.
-- Always ignores private .wippy state and .git.
local M = {}

type Rule = {
    pattern: string,
    lua_pattern: string,
    negate: boolean,
    dir_only: boolean,
    anchored: boolean,
    prefix: string,
}

type Matcher = {
    rules: {Rule},
    ignored: (Matcher, path: string, is_dir: boolean) -> boolean,
    add_rules: (Matcher, content: string, prefix: string?) -> (),
}

local function escape_lua_magic(s: string): string
    return s:gsub("([%^%$%(%)%%%.%[%]%+%-])", "%%%1")
end

-- Converts a gitignore glob to a Lua pattern.
local function glob_to_lua_pattern(glob: string): string
    -- Handle ** wildcard
    local tokens: {string} = {}
    local i = 1
    local len = #glob
    while i <= len do
        if glob:sub(i, i + 1) == "**" then
            if glob:sub(i + 2, i + 2) == "/" then
                tokens[#tokens + 1] = "(.-/)"
                i = i + 3
            elseif i > 1 and glob:sub(i - 1, i - 1) == "/" then
                tokens[#tokens + 1] = "(.*)"
                i = i + 2
            else
                tokens[#tokens + 1] = ".*"
                i = i + 2
            end
        elseif glob:sub(i, i) == "*" then
            tokens[#tokens + 1] = "[^/]*"
            i = i + 1
        elseif glob:sub(i, i) == "?" then
            tokens[#tokens + 1] = "[^/]"
            i = i + 1
        else
            tokens[#tokens + 1] = escape_lua_magic(glob:sub(i, i))
            i = i + 1
        end
    end
    return table.concat(tokens)
end

local function matches_glob(glob: string, path: string): boolean
    local parts: {string} = {}
    local segments: {string} = {}
    for part in glob:gmatch("[^/]+") do parts[#parts + 1] = part end
    for segment in path:gmatch("[^/]+") do segments[#segments + 1] = segment end
    local memo: {[string]: boolean} = {}
    local function match_at(i: integer, j: integer): boolean
        local key = tostring(i) .. ":" .. tostring(j)
        local cached = memo[key]
        if cached ~= nil then return cached end
        local result: boolean
        if i > #parts then
            result = j > #segments
        elseif parts[i] == "**" then
            result = match_at(i + 1, j) or (j <= #segments and match_at(i, j + 1))
        else
            result = j <= #segments
                and segments[j]:match("^" .. glob_to_lua_pattern(parts[i]) .. "$") ~= nil
                and match_at(i + 1, j + 1)
        end
        memo[key] = result
        return result
    end
    return match_at(1, 1)
end

local function parse_rule(line: string, prefix: string): Rule?
    -- Trim whitespace and carriage returns
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\r", "")
    if trimmed == "" or trimmed:sub(1, 1) == "#" then
        return nil
    end

    local negate = false
    if trimmed:sub(1, 1) == "!" then
        negate = true
        trimmed = trimmed:sub(2)
    end

    if trimmed == "" then
        return nil
    end

    local dir_only = false
    if trimmed:sub(-1) == "/" then
        dir_only = true
        trimmed = trimmed:sub(1, -2)
    end

    local anchored = false
    if trimmed:sub(1, 1) == "/" then
        anchored = true
        trimmed = trimmed:sub(2)
    elseif trimmed:find("/", 1, true) then
        anchored = true
    end

    local lua_pat = glob_to_lua_pattern(trimmed)

    return {
        pattern = trimmed,
        lua_pattern = "^" .. lua_pat .. "$",
        negate = negate,
        dir_only = dir_only,
        anchored = anchored,
        prefix = prefix,
    }
end

local MatcherMethods = {}

function MatcherMethods.add_rules(self: Matcher, content: string, prefix: string?)
    local base_prefix = prefix or ""
    if base_prefix ~= "" and base_prefix:sub(-1) ~= "/" then
        base_prefix = base_prefix .. "/"
    end
    for line in content:gmatch("[^\n]+") do
        local rule = parse_rule(line, base_prefix)
        if rule then
            self.rules[#self.rules + 1] = rule
        end
    end
end

-- Checks if a relative path is ignored.
function MatcherMethods.ignored(self: Matcher, path: string, is_dir: boolean): boolean
    -- Strip leading "./" or "/"
    local clean = path:gsub("^%./", ""):gsub("^/", "")

    -- Always ignore .wippy and .git
    local first_seg = clean:match("^([^/]+)")
    if first_seg == ".wippy" or first_seg == ".git" then
        return true
    end

    local ignored = false
    local basename = clean:match("([^/]+)$") or clean

    for _, rule in ipairs(self.rules) do
        if not (rule.dir_only and not is_dir) then
            local matches = false
            if rule.anchored then
                local rel_path: string? = clean
                if rule.prefix ~= "" then
                    if clean:sub(1, #rule.prefix) == rule.prefix then
                        rel_path = clean:sub(#rule.prefix + 1)
                    else
                        rel_path = nil
                    end
                end
                if rel_path then
                    if matches_glob(rule.pattern, rel_path) then
                        matches = true
                    elseif is_dir and matches_glob(rule.pattern, rel_path .. "/") then
                        matches = true
                    end
                end
            else
                -- Non-anchored matches against basename or full relative path
                if matches_glob(rule.pattern, basename) then
                    matches = true
                elseif matches_glob(rule.pattern, clean) then
                    matches = true
                end
            end

            if matches then
                ignored = not rule.negate
            end
        end
    end

    return ignored
end

function M.new(content: string?, prefix: string?): Matcher
    local matcher: Matcher = {
        rules = {},
        ignored = MatcherMethods.ignored,
        add_rules = MatcherMethods.add_rules,
    }
    if content and content ~= "" then
        matcher:add_rules(content, prefix)
    end
    return matcher
end

return M
