-- MIT. Owns a workspace without a physical terminal or a desktop client.
local process = require("process")
local channel = require("channel")
local security = require("security")
local time = require("time")
local logger = require("logger")
local protocol = require("protocol")
local decode = require("decode")
local workspaces = require("workspaces")

local function main()
    local host = ""
    local ready = assert(process.listen("bee.host.ready", {message = true}))
    local function run()
        local events = assert(process.events())
        local policies: {security.Policy} = {}
        for _, name in ipairs({"bee.security.desktop:host_policy", "bee.security.desktop:host_spawn_policy", "bee.security.storage:workspace_storage_policy"}) do
            policies[#policies + 1] = assert(security.policy(name))
        end
        local self = tostring(process.pid())
        host = tostring(assert(process.with_options({}):with_context({["bee.host_owner"] = self})
            :with_scope(security.new_scope(policies)):spawn_monitored("bee.host:main", "bee:workers", self, workspaces.classic())))
        local started = false
        local deadline = time.after("10s")
        while true do
            local cases = {ready:case_receive(), events:case_receive()}
            if not started then cases[#cases + 1] = deadline:case_receive() end
            local selected = channel.select(cases)
            if not selected.ok then error("Headless supervisor channel closed") end
            if selected.channel == deadline then
                error("Workspace startup timed out")
            elseif selected.channel == events then
                local event = selected.value
                -- Cancellation already invalidates this execution context.
                -- The host handles cancellation/owner exit through its cleanup;
                -- do not issue new request/reply work on a canceled context.
                if event.kind == process.event.CANCEL then return end
                if event.kind == process.event.EXIT and tostring(event.from) == host then
                    host = ""
                    local failure = decode.exit_error(event.result)
                    error("Workspace host exited: " .. (failure or "unexpected exit"))
                end
            else
                local message = selected.value
                if tostring(message:from()) == host and not started then
                    local value = protocol.host(message:payload():data())
                    if not value then error("Invalid workspace readiness") end
                    started = true
                    logger:info("Bee workspace ready", {workspace_id = value.workspace_id})
                end
            end
        end
    end
    local ok, err = pcall(run)
    if host ~= "" then process.terminate(host) end
    process.unlisten(ready)
    if not ok then error(err) end
end

return {main = main}
