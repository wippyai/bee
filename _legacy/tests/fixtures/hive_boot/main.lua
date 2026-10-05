-- MIT. Disposable runtime boot proof; never loaded by Bee production.
local system = require("system")
local time = require("time")
local io = require("io")
local function main(expected_text: string, role: string)
    local expected = tonumber(expected_text)
    assert(expected and expected >= 2 and expected <= 100)
    local address = assert(system.node.addr())
    assert(io.print("BEE_HIVE_PROBE ready " .. address))
    local ticker = assert(time.ticker("100ms"))
    local ticks = ticker:channel()
    for _ = 1, 400 do
        local members = assert(system.cluster.members())
        local leader = role == "server" and assert(system.cluster.leader()) or "client"
        if #members == expected and leader ~= "" then
            for _, member in ipairs(members) do
                local meta = assert(member.meta)
                local port = tonumber(meta.internode_port or "")
                assert(port and port > 0 and port <= 65535, "invalid advertised internode port")
            end
            if role == "server" then assert(io.print("BEE_HIVE_PROBE leader " .. leader)) end
            assert(io.print("BEE_HIVE_PROBE formed " .. tostring(#members)))
            ticker:stop()
            time.after("60s"):receive()
            return
        end
        ticks:receive()
    end
    ticker:stop()
    local members = assert(system.cluster.members())
    local details: {string} = {}
    for _, member in ipairs(members) do
        local meta = member.meta or {}
        details[#details + 1] = member.id .. ":" .. (meta.raft_status or "-") .. ":" .. (meta.bootstrap_expect or "-")
            .. ":eligible=" .. (meta.raft_eligible or "-")
    end
    error("Runtime convergence failed: members=" .. tostring(#members) .. "/" .. tostring(expected)
        .. " leader=" .. tostring(system.cluster.leader()) .. " peers=" .. table.concat(details, ","))
end
return {main = main}
