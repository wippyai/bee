-- MIT. Bootstrap choice does not imply authority in incoming control payloads.
local test = require("test")
local lifecycle = require("lifecycle")
local workspace = "0123456789abcdef0123456789abcdef"
local function define_tests()
    test.describe("Client supervisor lifecycle", function()
        test.it("defaults to detach and requires a versioned explicit supervisor choice", function()
            test.eq(assert(lifecycle.bootstrap(nil)).quit_mode, "detach")
            test.eq(assert(lifecycle.bootstrap({version = 1, quit_mode = "supervisor"})).quit_mode, "supervisor")
            test.is_nil(lifecycle.bootstrap({quit_mode = "supervisor"}))
            test.is_nil(lifecycle.bootstrap({version = 1, quit_mode = "shutdown"}))
            test.is_nil(lifecycle.bootstrap({version = 1, fullscreen = "yes"}))
            test.is_nil(lifecycle.bootstrap({version = 1, arguments = {"bad\nargument"}}))
            local args = {"space ; $HOME"}
            local options = lifecycle.bootstrap({version = 1, arguments = args, fullscreen = true})
            if not options then error("Missing launch options") end
            args[1] = "changed"
            test.eq(options.arguments[1], "space ; $HOME")
            test.is_true(options.fullscreen)
            test.is_nil(lifecycle.bootstrap({version = 1, secondary_application = ""}))
            test.is_nil(lifecycle.bootstrap({version = 1, secondary_application = "bad\napp"}))
            local secondary = lifecycle.bootstrap({version = 1, secondary_application = "probe:app"})
            if not secondary then error("Missing secondary launch") end
            test.eq(secondary.secondary_application, "probe:app")
        end)
        test.it("refuses foreign workspace and ambiguous shutdown control", function()
            local value = {version = 1, workspace_id = workspace, request_id = "control", op = "exit"}
            test.not_nil(lifecycle.control(value, workspace))
            value.op = "save"
            test.not_nil(lifecycle.control(value, workspace))
            test.is_nil(lifecycle.control(value, "ffffffffffffffffffffffffffffffff"))
            value.request_id = ""
            test.is_nil(lifecycle.control(value, workspace))
            test.is_nil(lifecycle.control({version = 1, workspace_id = workspace, request_id = "control", op = "state",
                shutdown = {version = 1, request_id = "q", id = "application", instance_id = "instance",
                    kind = "confirm", title = "Stop?", message = "", accept = "Stop"}}, workspace))
            test.not_nil(lifecycle.control({version = 1, workspace_id = workspace, request_id = "clear", op = "state"}, workspace))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
