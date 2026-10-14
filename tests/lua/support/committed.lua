local cdc = require("cdc")
local channel = require("channel")
local time = require("time")
type Object = {[string]: unknown}
local M = {}

function M.await(tables: {string}, read: () -> Object, ready: (Object) -> boolean, timeout: string?, label: string): Object
    local changes = assert(cdc.stream("bee:changes", {tables = tables, ops = {"insert", "update", "delete"}}))
    local source = assert(changes:channel())
    local deadline = timeout and time.after(timeout) or nil
    local ok, result = pcall(function(): Object
        while true do
            local value = read()
            if ready(value) then return value end
            local cases = {source:case_receive()}
            if deadline then cases[#cases + 1] = deadline:case_receive() end
            local selected = channel.select(cases)
            assert(selected.channel ~= deadline and selected.ok, label .. " did not commit its completion")
        end
    end)
    changes:close()
    if not ok then error(result) end
    return result :: Object
end

return M
