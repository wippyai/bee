-- MIT. Pure comparison of resolved operations. Equality of request names is
-- insufficient: resource identity, operation scope and template meaning count.
local M = {}
type Object = {[string]: unknown}
type Grant = {capability: string, template_revision: integer, operation: string,
    resource: string, scope: Object, parameters: Object?}
type Change = {before: Grant?, after: Grant?}
type Diff = {added: {Change}, widened: {Change}, narrowed: {Change},
    removed: {Change}, changed: {Change}, requires_approval: boolean}

local function plain(raw: unknown, maximum: integer): string?
    if type(raw) ~= "string" or #raw == 0 or #raw > maximum or raw:find("%c") then return nil end
    return raw
end
local function object(raw: unknown): Object?
    if type(raw) ~= "table" then return nil end
    for key in pairs(raw :: table) do if type(key) ~= "string" then return nil end end
    return raw :: Object
end
local function dense(raw: unknown, maximum: integer): ({unknown}?, string?)
    if type(raw) ~= "table" then return nil, "grant set must be a list" end
    local count = 0
    for key in pairs(raw :: table) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil, "grant set must be dense" end
        count = count + 1
    end
    if count > maximum then return nil, "grant set exceeds bound" end
    local capacity: integer = count > 0 and count or 1
    local result: {unknown} = table.create(capacity, 0)
    for index = 1, count do
        local value = (raw :: table)[index]
        if value == nil then return nil, "grant set must be dense" end
        result[index] = value
    end
    return result, nil
end
local function strings(raw: unknown): {string}?
    local rows = dense(raw, 16)
    if not rows or #rows == 0 then return nil end
    local result: {string} = {}
    local seen: {[string]: boolean} = {}
    for _, item in ipairs(rows) do
        local value = plain(item, 160)
        if not value or seen[value] then return nil end
        result[#result + 1], seen[value] = value, true
    end
    table.sort(result)
    return result
end
local SCOPE_FIELDS: {[string]: boolean} = {subpath = true, path_prefix = true, methods = true,
    definitions = true, scope = true, name = true}
local function valid_path(value: string, absolute: boolean): boolean
    if value:find("\\", 1, true) or value:find("//", 1, true) then return false end
    if absolute then
        if value:sub(1, 1) ~= "/" or (#value > 1 and value:sub(-1) == "/") then return false end
    elseif value:sub(1, 1) == "/" or (#value > 1 and value:sub(-1) == "/") then return false end
    if not absolute and value == "." then return true end
    for segment in value:gmatch("[^/]+") do
        if segment == "." or segment == ".." or not segment:match("^[A-Za-z0-9_.-]+$") then return false end
    end
    return true
end
local function normalize(raw: unknown): (Grant?, string?)
    local item = object(raw)
    local scope = item and object(item.scope) or nil
    if not item or not scope or not plain(item.capability, 80) or not plain(item.operation, 80)
        or not plain(item.resource, 160) or type(item.template_revision) ~= "number"
        or item.template_revision < 1 or item.template_revision ~= math.floor(item.template_revision) then
        return nil, "resolved grant is malformed"
    end
    for key in pairs(item) do
        if key ~= "capability" and key ~= "template_revision" and key ~= "operation"
            and key ~= "resource" and key ~= "scope" and key ~= "parameters" then
            return nil, "resolved grant has an unknown field"
        end
    end
    local copy: Object = {}
    for key, value in pairs(scope) do
        if not SCOPE_FIELDS[key] then return nil, "resolved grant scope is unknown" end
        if key == "methods" or key == "definitions" then
            local values = strings(value)
            if not values then return nil, "resolved grant set scope is malformed" end
            copy[key] = values
        else
            if not plain(value, 160) then return nil, "resolved grant scalar scope is malformed" end
            if key == "subpath" and not valid_path(value :: string, false) then return nil, "resolved grant subpath is malformed" end
            if key == "path_prefix" and not valid_path(value :: string, true) then return nil, "resolved grant path prefix is malformed" end
            copy[key] = value
        end
    end
    local params = item.parameters == nil and nil or object(item.parameters)
    if item.parameters ~= nil and not params then return nil, "resolved grant parameters are malformed" end
    return {capability = item.capability :: string, template_revision = item.template_revision :: integer,
        operation = item.operation :: string, resource = item.resource :: string,
        scope = copy, parameters = params}, nil
end
local function path_contains(parent: string, child: string): boolean
    if parent == child or parent == "/" or parent == "." then return true end
    return child:sub(1, #parent + 1) == parent .. "/"
end
local function set_contains(parent: {string}, child: {string}): boolean
    local members: {[string]: boolean} = {}
    for _, value in ipairs(parent) do members[value] = true end
    for _, value in ipairs(child) do if not members[value] then return false end end
    return true
end
local function scope_contains(parent: Object, child: Object): boolean
    for key, value in pairs(parent) do
        local next_value = child[key]
        if next_value == nil then return false end
        if key == "subpath" or key == "path_prefix" then
            if not path_contains(value :: string, next_value :: string) then return false end
        elseif key == "methods" or key == "definitions" then
            if not set_contains(value :: {string}, next_value :: {string}) then return false end
        elseif value ~= next_value then return false end
    end
    for key in pairs(child) do if parent[key] == nil then return false end end
    return true
end
local function same_operation(left: Grant, right: Grant): boolean
    return left.operation == right.operation and left.resource == right.resource
end
local function same_meaning(left: Grant, right: Grant): boolean
    return same_operation(left, right) and left.capability == right.capability
        and left.template_revision == right.template_revision
end
local function covered(target: Grant, others: {Grant}): boolean
    for _, other in ipairs(others) do
        if same_meaning(target, other) and scope_contains(other.scope, target.scope) then return true end
    end
    local set_key: string? = nil
    if target.scope.methods then set_key = "methods" end
    if target.scope.definitions then set_key = "definitions" end
    if not set_key then return false end
    local members: {[string]: boolean} = {}
    for _, other in ipairs(others) do
        if same_meaning(target, other) and type(other.scope[set_key]) == "table" then
            local compatible = true
            for key, value in pairs(other.scope) do
                if key ~= set_key then
                    local target_value = target.scope[key]
                    if target_value == nil then compatible = false
                    elseif key == "subpath" or key == "path_prefix" then
                        if not path_contains(value :: string, target_value :: string) then compatible = false end
                    elseif value ~= target_value then compatible = false end
                end
            end
            for key in pairs(target.scope) do
                if key ~= set_key and other.scope[key] == nil then compatible = false end
            end
            if compatible then
                for _, value in ipairs(other.scope[set_key] :: {string}) do members[value] = true end
            end
        end
    end
    for _, value in ipairs(target.scope[set_key] :: {string}) do
        if not members[value] then return false end
    end
    return true
end
local function decode_set(raw: unknown): ({Grant}?, string?)
    local rows, rows_error = dense(raw, 128)
    if not rows then return nil, rows_error end
    local result: {Grant} = {}
    for _, value in ipairs(rows) do
        local grant, grant_error = normalize(value)
        if not grant then return nil, grant_error end
        result[#result + 1] = grant
    end
    return result, nil
end

function M.compare(installed_raw: unknown, proposed_raw: unknown): (Diff?, string?)
    local installed, old_error = decode_set(installed_raw)
    local proposed, new_error = decode_set(proposed_raw)
    if not installed or not proposed then return nil, old_error or new_error end
    local diff: Diff = {added = {}, widened = {}, narrowed = {}, removed = {}, changed = {}, requires_approval = false}
    local revision_pairs: {[integer]: boolean} = {}
    for _, next_grant in ipairs(proposed) do
        if not covered(next_grant, installed) then
            local changed_index: integer? = nil
            local widened_index: integer? = nil
            for old_index, old_grant in ipairs(installed) do
                if same_operation(old_grant, next_grant) then
                    if not same_meaning(old_grant, next_grant) and not revision_pairs[old_index] then
                        changed_index = old_index
                        break
                    elseif same_meaning(old_grant, next_grant)
                        and scope_contains(next_grant.scope, old_grant.scope) then
                        widened_index = old_index
                    end
                end
            end
            if changed_index then
                revision_pairs[changed_index] = true
                diff.changed[#diff.changed + 1] = {before = installed[changed_index], after = next_grant}
            elseif widened_index then
                diff.widened[#diff.widened + 1] = {before = installed[widened_index], after = next_grant}
            else
                diff.added[#diff.added + 1] = {after = next_grant}
            end
        end
    end
    for index, old_grant in ipairs(installed) do
        if not revision_pairs[index] and not covered(old_grant, proposed) then
            local narrower: Grant? = nil
            for _, next_grant in ipairs(proposed) do
                if same_meaning(old_grant, next_grant)
                    and scope_contains(old_grant.scope, next_grant.scope) then
                    narrower = next_grant
                    break
                end
            end
            if narrower then diff.narrowed[#diff.narrowed + 1] = {before = old_grant, after = narrower}
            else diff.removed[#diff.removed + 1] = {before = old_grant} end
        end
    end
    diff.requires_approval = #diff.added > 0 or #diff.widened > 0 or #diff.changed > 0
    return diff, nil
end
return M
