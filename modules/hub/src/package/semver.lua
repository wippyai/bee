-- MIT. Compact strict SemVer comparison and constraint selection for Hub plans.
local M = {}
type Version = {raw: string, major: string, minor: string, patch: string, prerelease: {string}}

local function trim(value: string): string
    return value:match("^%s*(.-)%s*$") or ""
end

local function number_part(value: string): boolean
    return value == "0" or value:match("^[1-9]%d*$") ~= nil
end

local function numeric_compare(left: string, right: string): integer
    if #left ~= #right then return #left < #right and -1 or 1 end
    if left == right then return 0 end
    return left < right and -1 or 1
end

local function parse_identifiers(raw: string, numeric_zero: boolean): {string}?
    if raw == "" or raw:match("^%.") or raw:match("%.$") or raw:find("..", 1, true) then return nil end
    local identifiers: {string} = {}
    for identifier in raw:gmatch("[^%.]+") do
        if not identifier:match("^[0-9A-Za-z-]+$") then return nil end
        if not numeric_zero and identifier:match("^%d+$") and not number_part(identifier) then return nil end
        identifiers[#identifiers + 1] = identifier
    end
    return identifiers
end

function M.parse(raw: unknown): Version?
    if type(raw) ~= "string" then return nil end
    if raw == "" or #raw > 128 or raw ~= trim(raw) then return nil end
    local value: string = raw
    if value:sub(1, 1) == "v" then value = value:sub(2) end
    local plus = value:find("+", 1, true)
    if plus then
        if not parse_identifiers(value:sub(plus + 1), true) then return nil end
        value = value:sub(1, plus - 1)
    end
    local identifiers: {string} = {}
    local dash = value:find("-", 1, true)
    if dash then
        local parsed = parse_identifiers(value:sub(dash + 1), false)
        if not parsed then return nil end
        identifiers = parsed
        value = value:sub(1, dash - 1)
    end
    local major, minor, patch = value:match("^(%d+)%.(%d+)%.(%d+)$")
    if type(major) ~= "string" or type(minor) ~= "string" or type(patch) ~= "string" then return nil end
    if not number_part(major) or not number_part(minor) or not number_part(patch) then return nil end
    return {raw = raw, major = major, minor = minor, patch = patch, prerelease = identifiers}
end

local function compare_version(left: Version, right: Version): integer
    for _, field in ipairs({"major", "minor", "patch"}) do
        local result = numeric_compare(left[field], right[field])
        if result ~= 0 then return result end
    end
    local count = math.max(#left.prerelease, #right.prerelease)
    if count == 0 then return 0 end
    if #left.prerelease == 0 then return 1 end
    if #right.prerelease == 0 then return -1 end
    for index = 1, count do
        local a, b = left.prerelease[index], right.prerelease[index]
        if not a then return -1 end
        if not b then return 1 end
        if a ~= b then
            local a_number, b_number = a:match("^%d+$") ~= nil, b:match("^%d+$") ~= nil
            if a_number and b_number then return numeric_compare(a, b) end
            if a_number then return -1 end
            if b_number then return 1 end
            return a < b and -1 or 1
        end
    end
    return 0
end

function M.compare(left: string, right: string): (integer?, string?)
    local a, b = M.parse(left), M.parse(right)
    if not a or not b then return nil, "versions must be strict SemVer" end
    return compare_version(a, b), nil
end

type Comparator = {op: string, version: Version?, major: string?, minor: string?}
type Set = {Comparator}

local function parse_wildcard(raw: string): Comparator?
    if raw == "*" or raw == "x" or raw == "X" then return {op = "*"} end
    local major = raw:match("^(%d+)%.[xX%*]$")
    if major and number_part(major) then return {op = "major", major = major} end
    local minor
    major, minor = raw:match("^(%d+)%.(%d+)%.[xX%*]$")
    if major and minor and number_part(major) and number_part(minor) then return {op = "minor", major = major, minor = minor} end
    return nil
end

local function parse_comparator(token: string): (Comparator?, string?)
    local op, raw = "=", token
    for _, candidate in ipairs({">=", "<=", "!=", "^", "~", ">", "<", "="}) do
        if token:sub(1, #candidate) == candidate then
            op, raw = candidate, token:sub(#candidate + 1)
            break
        end
    end
    if raw == "" then return nil, "constraint comparator needs a version" end
    local wildcard = parse_wildcard(raw)
    if wildcard then
        if op ~= "=" then return nil, "wildcards only allow exact matching" end
        return wildcard, nil
    end
    local version = M.parse(raw)
    if not version then return nil, "constraint contains an unsupported version" end
    return {op = op, version = version}, nil
end

local function parse_set(raw: string): (Set?, string?)
    raw = trim(raw)
    if raw == "" or raw:find("|", 1, true) then return nil, "constraint set is malformed" end
    if raw:match("^,") or raw:match(",$") or raw:match(",%s*,") then return nil, "constraint set is malformed" end
    raw = raw:gsub(",", " ")
    local set: Set = {}
    for token in raw:gmatch("%S+") do
        local comparator, problem = parse_comparator(token)
        if not comparator then return nil, problem end
        set[#set + 1] = comparator
    end
    if #set == 0 then return nil, "constraint set is empty" end
    return set, nil
end

local function parse_constraint(raw: unknown): ({Set}?, string?)
    if type(raw) ~= "string" then return nil, "constraint must be a string" end
    local value = trim(raw)
    if value == "" then return nil, "constraint is empty" end
    local sets: {Set} = {}
    local cursor = 1
    while true do
        local start, finish = value:find("||", cursor, true)
        local segment = start and value:sub(cursor, start - 1) or value:sub(cursor)
        local set, problem = parse_set(segment)
        if not set then return nil, problem end
        sets[#sets + 1] = set
        if not finish then break end
        cursor = finish + 1
    end
    return sets, nil
end

local function same_core(left: Version, right: Version): boolean
    return left.major == right.major and left.minor == right.minor and left.patch == right.patch
end

local function allows(version: Version, comparator: Comparator): boolean
    if comparator.op == "*" then return true end
    if comparator.op == "major" then return version.major == comparator.major end
    if comparator.op == "minor" then return version.major == comparator.major and version.minor == comparator.minor end
    local base = comparator.version
    if not base then return false end
    local compared = compare_version(version, base)
    if comparator.op == "=" then return compared == 0 end
    if comparator.op == "!=" then return compared ~= 0 end
    if comparator.op == ">" then return compared > 0 end
    if comparator.op == ">=" then return compared >= 0 end
    if comparator.op == "<" then return compared < 0 end
    if comparator.op == "<=" then return compared <= 0 end
    if comparator.op == "~" then
        return compared >= 0 and version.major == base.major and version.minor == base.minor
    end
    if comparator.op == "^" then
        if compared < 0 then return false end
        if base.major ~= "0" then return version.major == base.major end
        if base.minor ~= "0" then return version.major == "0" and version.minor == base.minor end
        return version.major == "0" and version.minor == "0" and version.patch == base.patch
    end
    return false
end

local function set_matches(version: Version, set: Set): boolean
    if #version.prerelease > 0 then
        local targeted = false
        for _, comparator in ipairs(set) do
            if comparator.version and #comparator.version.prerelease > 0 and same_core(version, comparator.version) then
                targeted = true
                break
            end
        end
        if not targeted then return false end
    end
    for _, comparator in ipairs(set) do
        if not allows(version, comparator) then return false end
    end
    return true
end

function M.matches(version: string, constraint: string): (boolean?, string?)
    local parsed = M.parse(version)
    if not parsed then return nil, "version must be strict SemVer" end
    local sets, problem = parse_constraint(constraint)
    if not sets then return nil, problem end
    for _, set in ipairs(sets) do
        if set_matches(parsed, set) then return true, nil end
    end
    return false, nil
end

local function dense_strings(value: unknown, label: string): ({string}?, string?)
    if type(value) ~= "table" then return nil, label .. " must be a dense list" end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil, label .. " must be a dense list" end
        count = count + 1
    end
    if count ~= #value then return nil, label .. " must be a dense list" end
    local result: {string} = {}
    for index = 1, count do
        if type(value[index]) ~= "string" then return nil, label .. " must contain strings" end
        result[index] = value[index]
    end
    return result, nil
end

function M.select(versions: {string}, constraints: {string}): (string?, string?)
    local candidates, candidate_problem = dense_strings(versions, "versions")
    if not candidates then return nil, candidate_problem end
    local requested, constraint_problem = dense_strings(constraints, "constraints")
    if not requested then return nil, constraint_problem end
    local best: string? = nil
    local best_version: Version? = nil
    for _, raw in ipairs(candidates) do
        local parsed = M.parse(raw)
        if not parsed then return nil, "versions must contain strict SemVer" end
        local accepted = not (#requested == 0 and #parsed.prerelease > 0)
        for _, constraint in ipairs(requested) do
            local matches, problem = M.matches(raw, constraint)
            if problem then return nil, problem end
            if not matches then accepted = false break end
        end
        if accepted and (not best_version or compare_version(parsed, best_version) > 0) then
            best, best_version = raw, parsed
        end
    end
    if not best then return nil, "no version satisfies constraints" end
    return best, nil
end

return M
