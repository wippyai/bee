-- MIT. Host-scoped native contract methods. The caller's security actor owns data.
local security = require("security")
local protocol = require("protocol")
local resources = require("resources")
local store = require("store")
local function open_store(): (any, string?)
    local resource, resource_error = resources.database()
    if not resource then return nil, resource_error end
    return store.open(resource)
end
local function identity(): string?
    local actor = security.actor()
    return actor and protocol.id(actor:id()) or nil
end
local function claim(value: unknown): protocol.Reply
    if type(value) ~= "table" then return protocol.reply("Invalid request") end
    local actor, thread, run = identity(), protocol.id(value.thread), protocol.id(value.run)
    if not actor or not thread or not run then return protocol.reply("Invalid actor, thread or run") end
    local db, err = open_store()
    if not db then return protocol.reply(err or "Journal unavailable") end
    local created, claim_error = db:claim(actor, thread, run)
    db:close()
    local reply = protocol.reply(claim_error)
    reply.created = created == true
    return reply
end
local function append(value: unknown): protocol.Reply
    if type(value) ~= "table" then return protocol.reply("Invalid request") end
    local actor, thread, run = identity(), protocol.id(value.thread), protocol.id(value.run)
    local key, kind, body = protocol.id(value.key), protocol.id(value.kind), value.body
    if not actor or not thread or not run or not key or not kind or type(body) ~= "string" or #body > 16384 then return protocol.reply("Invalid event") end
    local db, err = open_store()
    if not db then return protocol.reply(err or "Journal unavailable") end
    local seq, append_error = db:append(actor, thread, run, key, kind, body)
    db:close()
    local reply = protocol.reply(append_error)
    reply.seq = seq or 0
    return reply
end
local function read_after(value: unknown): protocol.Reply
    if type(value) ~= "table" then return protocol.reply("Invalid request") end
    local actor, thread, after = identity(), protocol.id(value.thread), protocol.cursor(value.after)
    if not actor or not thread or not after then return protocol.reply("Invalid actor, thread or cursor") end
    local db, err = open_store()
    if not db then return protocol.reply(err or "Journal unavailable") end
    local events, read_error = db:read(actor, thread, after)
    db:close()
    local reply = protocol.reply(read_error)
    if events then reply.events = events end
    return reply
end
return {claim = claim, append = append, read_after = read_after}
