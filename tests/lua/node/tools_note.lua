-- MIT. The tools a notes test application offers agents: add stores one note
-- and list reads them back, both in the application's own granted database,
-- and each reports the actor it ran as.
local funcs = require("funcs")
local security = require("security")
local sql = require("sql")

type Reply = {ok: boolean, value: unknown, error: {code: string, message: string}?}

local function fail(code: string, message: string): Reply
    return {ok = false, value = nil, error = {code = code, message = message}}
end

local function database(): (sql.DB?, string?)
    local granted, call_error = funcs.call("bee.gov.binding:granted_resources", {})
    if call_error then return nil, tostring(call_error) end
    local reply = granted :: {[string]: unknown}
    local value = type(reply) == "table" and reply.ok == true and reply.value :: {[string]: unknown} or nil
    local databases = value and value.databases :: {[string]: string} or nil
    local id = databases and databases.notes or nil
    if not id then return nil, "no granted notes database" end
    local db, db_error = sql.get(id)
    if not db then return nil, tostring(db_error) end
    local _, create_error = db:execute("CREATE TABLE IF NOT EXISTS notes (text TEXT NOT NULL)")
    if create_error then db:release(); return nil, tostring(create_error) end
    return db, nil
end

local function actor_id(): string
    local actor = security.actor()
    return actor and actor:id() or "none"
end

local function add(arguments: {text: string}): Reply
    local db, db_error = database()
    if not db then return fail("UNAVAILABLE", tostring(db_error)) end
    local _, insert_error = db:execute("INSERT INTO notes (text) VALUES (?)", {arguments.text})
    db:release()
    if insert_error then return fail("FAILED", tostring(insert_error)) end
    return {ok = true, value = {added = arguments.text, actor = actor_id()}, error = nil}
end

local function list(_arguments: unknown): Reply
    local db, db_error = database()
    if not db then return fail("UNAVAILABLE", tostring(db_error)) end
    local rows, query_error = db:query("SELECT text FROM notes ORDER BY rowid")
    db:release()
    if not rows then return fail("FAILED", tostring(query_error)) end
    local notes: {string} = {}
    for _, row in ipairs(rows) do notes[#notes + 1] = tostring(row.text) end
    return {ok = true, value = {notes = notes, actor = actor_id()}, error = nil}
end

return {add = add, list = list}
