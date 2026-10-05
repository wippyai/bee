-- MIT. What a display does when the node it shows goes quiet: only the node's
-- supervisor exiting means the node stopped; an owner that exits restarts, and
-- a node that becomes unreachable may still run, so the display reconnects.
local test = require("test")
local watch = require("watch")

local function define_tests()
    test.describe("display watch", function()
        local function lost(kind: string, from: string, target: string, origin: string): string
            return watch.lost(kind, from, {owner = "owner", supervisor = "supervisor", target = target, origin = origin})
        end
        test.it("stops when the node it runs in stops", function()
            test.eq(lost("exit", "supervisor", "node-a", "node-a"), "stop")
        end)
        test.it("shows its own node again when another node stops", function()
            test.eq(lost("exit", "supervisor", "node-b", "node-a"), "home")
        end)
        test.it("reconnects when the owner restarts", function()
            test.eq(lost("exit", "owner", "node-a", "node-a"), "reconnect")
        end)
        test.it("reconnects when the node becomes unreachable, since it may still run", function()
            test.eq(lost("monitor_down", "owner", "node-a", "node-a"), "reconnect")
            test.eq(lost("monitor_down", "supervisor", "node-a", "node-a"), "reconnect")
            test.eq(lost("monitor_down", "supervisor", "node-b", "node-a"), "reconnect")
        end)
        test.it("ignores processes it does not follow", function()
            test.eq(lost("exit", "someone", "node-a", "node-a"), "none")
        end)
    end)
end

return test.run_cases(define_tests)
