-- MIT. A fresh boot must retain the Hive name and serve a real display under
-- the display command's declared authority, including in strict security mode.
local test = require("test")
local process = require("process")
local channel = require("channel")
local system = require("system")
local time = require("time")
local tty = require("tty")
local registry = require("registry")
local security = require("security")
local bounds = require("bounds")

local SERVICE = "bee.hive.service:supervisor_service"
local NAME = "bee.hive.supervisor"

local function diagnostic(): string
    local state = assert(system.supervisor.state(SERVICE))
    return state.status .. ": " .. tostring(state.details)
end

local function define_tests()
    test.describe("Fresh node boot residency", function()
        test.it("registers the Hive supervisor and serves a display desktop", function()
            local holder, lookup_error = process.registry.lookup(NAME, process.registry.LOCAL)
            test.not_nil(holder, NAME .. " did not register: " .. tostring(lookup_error) .. "; " .. diagnostic())
            local entry = assert(registry.get("bee.shell:main"))
            local meta = assert(bounds.object(entry.meta))
            local command = assert(bounds.object(meta.command))
            local declared = assert(bounds.object(command.security))
            local actor = assert(bounds.object(declared.actor))
            local policies: {security.Policy} = {}
            for _, id in ipairs(assert(bounds.ids(declared.policies))) do
                policies[#policies + 1] = assert(security.policy(id))
            end
            local view = assert(tty.viewport({width = 100, height = 30}))
            local lifecycle = assert(process.events())
            local updates = assert(view:updates())
            local pid = assert(process.with_options({terminal = assert(view:grant())})
                :with_actor(assert(security.new_actor(assert(bounds.id(actor.id)))))
                :with_scope(assert(security.new_scope(policies)))
                :spawn_monitored("bee.shell:main", "bee:workers"))
            local deadline = time.after("10s")
            local rendered = false
            while not rendered do
                local snapshot = view:snapshot()
                local screen = snapshot and table.concat(snapshot.rows, "\n") or ""
                rendered = screen:find(" BEE ", 1, true) ~= nil and screen:find("Desktop ", 1, true) ~= nil
                if rendered then break end
                local selected = channel.select({updates:case_receive(), lifecycle:case_receive(), deadline:case_receive()})
                if selected.channel == deadline or (selected.channel == lifecycle
                    and selected.value.kind == process.event.EXIT and tostring(selected.value.from) == tostring(pid)) then
                    assert(process.cancel(pid))
                    view:close()
                    error("display could not reach booted Hive: " .. diagnostic() .. "; screen was\n" .. screen)
                end
            end
            test.eq(tostring(process.registry.lookup(NAME, process.registry.LOCAL)), tostring(holder), "Hive must remain resident")
            assert(process.cancel(pid))
            view:close()
        end)
    end)
end

return test.run_cases(define_tests)
