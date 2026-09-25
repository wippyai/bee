-- MIT. Actual function scopes: callers can manage identities without SQL grants.
local funcs = require("funcs")
local sql = require("sql")
local function no_database()
    local handle, err = sql.get("bee.env:client_db")
    if handle then handle:release(); error("Desktop operation leaked direct database authority") end
    assert(err)
end
local function call(name: string, request: unknown, code: string): unknown
    local result, err = funcs.new():call("bee.client:" .. name, request)
    if err then error(tostring(err)) end
    if type(result) ~= "table" or result.code ~= code then error("Unexpected desktop operation result") end
    return result
end
local function count(value: unknown, expected: integer): string
    if type(value) ~= "table" or type(value.desktops) ~= "table" or #value.desktops ~= expected then error("Invalid desktop catalog size") end
    local first: unknown = value.desktops[1]
    if type(first) ~= "table" or type(first.desktop_id) ~= "string" or first.is_default ~= true then error("Missing default desktop identity") end
    return first.desktop_id
end
local function main(mode: string)
    no_database()
    local list = {version = 1, database_resource = "bee.env:client_db"}
    local allocate = {version = 1, database_resource = "bee.env:client_db", desktop_id = string.rep("e", 32)}
    if mode == "none" then
        call("list_desktops", list, "DENIED")
        call("allocate_desktop", allocate, "DENIED")
    elseif mode == "capacity" then
        for index = 1, 31 do
            call("allocate_desktop", {version = 1, database_resource = "bee.env:client_db", desktop_id = string.format("%032x", index)}, "OK")
        end
        count(call("list_desktops", list, "OK"), 33)
        call("allocate_desktop", {version = 1, database_resource = "bee.env:client_db", desktop_id = string.rep("f", 32)}, "CAPACITY")
        call("allocate_desktop", allocate, "OK")
        count(call("list_desktops", list, "OK"), 33)
    elseif mode == "reader" then
        count(call("list_desktops", list, "OK"), 2)
        call("allocate_desktop", {version = 1, database_resource = "bee.env:client_db", desktop_id = string.rep("f", 32)}, "DENIED")
        count(call("list_desktops", list, "OK"), 2)
    else
        assert(mode == "seed" or mode == "verify")
        local default = count(call("list_desktops", list, "OK"), mode == "seed" and 1 or 2)
        call("allocate_desktop", {version = 1, database_resource = "bee.env:client_db", desktop_id = default}, "CONFLICT")
        local first = call("allocate_desktop", allocate, "OK")
        if type(first) ~= "table" or first.desktop_id ~= allocate.desktop_id then error("Allocation identity changed") end
        call("allocate_desktop", allocate, "OK")
        count(call("list_desktops", list, "OK"), 2)
        call("list_desktops", {version = 1, database_resource = "bee.client.db:foreign"}, "DENIED")
        call("allocate_desktop", {version = 1, database_resource = "bee.client.db:foreign", desktop_id = allocate.desktop_id}, "DENIED")
        call("list_desktops", {version = 1, database_resource = "/tmp/client.db"}, "INVALID_ARGUMENT")
        call("list_desktops", {version = 1, database_resource = "bee.env:client_db", actor = "owner"}, "INVALID_ARGUMENT")
        call("allocate_desktop", {version = 1, database_resource = "bee.env:client_db", desktop_id = "bad"}, "INVALID_ARGUMENT")
        call("allocate_desktop", {version = 1, database_resource = "bee.env:client_db", desktop_id = allocate.desktop_id, label = "unexpected"}, "INVALID_ARGUMENT")
    end
    no_database()
end
return {main = main}
