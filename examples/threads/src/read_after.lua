-- MIT. Native contract adapter; the journal actor owns authorization and SQL.
local client = require("client")
local function main(owner: unknown, thread: unknown, capability: unknown, after: unknown): client.Reply
    if type(owner) ~= "string" or #owner == 0 or #owner > 160 or owner:find("%c") then
        return {seq = 0, rows = {}, error = "invalid"}
    end
    if type(thread) ~= "string" or #thread == 0 or #thread > 80 or thread:find("%c") then
        return {seq = 0, rows = {}, error = "invalid"}
    end
    if type(capability) ~= "string" or #capability ~= 36 then return {seq = 0, rows = {}, error = "invalid"} end
    if type(after) ~= "number" or after < 0 or after > 10000 or after ~= math.floor(after) then
        return {seq = 0, rows = {}, error = "invalid"}
    end
    return client.call(owner, "read", thread, "", "", "", math.floor(after), capability)
end
return {main = main}
