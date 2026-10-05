-- MIT. Probe capture drains both pipes and honors an explicit caller wait bound.
local test = require("test")
local env = require("env")
local json = require("json")
local channel = require("channel")
local time = require("time")
local probe_capture = require("probe_capture")
local probe_version = require("probe_version")
local driver_locate = require("driver_locate")

type Stream = probe_capture.Stream
type Process = probe_capture.Process

local function define_tests()
    test.describe("Locate probe process capture", function()
        test.it("authorizes nonsecret host home and environment presence facts", function()
            local home, home_error = env.get("bee.env:machine_home")
            test.is_nil(home_error)
            test.is_true(type(home) == "string" and home:sub(1, 1) == "/")
            local raw, read_error = env.get("bee.harness.launch:host_environment_names")
            test.is_nil(read_error)
            if type(raw) ~= "string" then error("host presence metadata is unavailable") end
            local decoded, decode_error = json.decode(raw)
            test.is_nil(decode_error)
            if type(decoded) ~= "table" then error("host presence metadata is malformed") end
            local found = false
            for _, value in ipairs(decoded) do
                if type(value) ~= "string" then error("host presence metadata contains a non-string name") end
                if value == "PATH" then found = true end
                test.is_false(value:find("=", 1, true) ~= nil)
            end
            test.is_true(found)
        end)

        test.it("drains stdout and stderr concurrently", function()
            local stderr_drained = channel.new(1)
            local drained_while_stdout_open = false
            local stdout: Stream = {
                read = function(_self, _size)
                    local selected = channel.select({stderr_drained:case_receive(), time.after("20ms"):case_receive()})
                    drained_while_stdout_open = selected.ok and selected.channel == stderr_drained
                    return nil, nil
                end,
                close = function(_self) end,
            }
            local stderr: Stream = {
                read = function(_self, _size)
                    stderr_drained:send(true)
                    return nil, nil
                end,
                close = function(_self) end,
            }
            local process: Process = {
                wait = function(_self) return 0, nil end,
                close = function(_self, _force) end,
            }
            local released = false
            local output, code, capture_error = probe_capture.capture(process, stdout, stderr,
                function() released = true end, 100)
            test.not_nil(output)
            test.eq(code, 0)
            test.is_nil(capture_error)
            test.is_true(drained_while_stdout_open)
            test.is_true(released)
        end)

        test.it("waits for completion when the caller declares no time bound", function()
            local ready = channel.new(1)
            local released = false
            coroutine.spawn(function() ready:send(true) end)
            local stdout: Stream = {read = function(_self, _size) ready:receive(); return nil, nil end, close = function(_self) end}
            local stderr: Stream = {read = function(_self, _size) return nil, nil end, close = function(_self) end}
            local process: Process = {wait = function(_self) return 0, nil end, close = function(_self, _force) error("must observe completion") end}
            local output, code, failure = probe_capture.capture(process, stdout, stderr, function() released = true end, 0)
            test.eq(output, ""); test.eq(code, 0); test.is_nil(failure); test.is_true(released)
        end)
        test.it("closes the process, streams, and executor at its deadline", function()
            local waiting = channel.new(2)
            local streams_closed = 0
            local function blocked_stream(): Stream
                return {
                    read = function(_self, _size)
                        channel.select({waiting:case_receive(), time.after("100ms"):case_receive()})
                        return nil, nil
                    end,
                    close = function(_self) streams_closed = streams_closed + 1 end,
                }
            end
            local closed = false
            local process: Process = {
                wait = function(_self)
                    channel.select({waiting:case_receive(), time.after("100ms"):case_receive()})
                    return 0, nil
                end,
                close = function(_self, force)
                    closed = force
                    waiting:send(true)
                    waiting:send(true)
                end,
            }
            local released = false
            local output, code, capture_error = probe_capture.capture(process, blocked_stream(), blocked_stream(),
                function() released = true end, 15)
            test.is_nil(output)
            test.is_nil(code)
            test.is_true(type(capture_error) == "string" and capture_error:find("timed out", 1, true) ~= nil)
            test.is_true(closed)
            test.eq(streams_closed, 2)
            test.is_true(released)
        end)

        test.it("classifies a missing executable as unavailable", function()
            local version, present = probe_version.read("bee-cli-not-installed", {}, function(argv)
                test.eq(argv[1], "bee-cli-not-installed")
                return nil, nil, "executable was not found", true
            end)
            test.is_nil(version)
            test.eq(present, false)
            local result, locate_error = driver_locate.evaluate({provider = "fixture", executable = "fixture-cli"}, {
                profile_id = "window", configured = true, executable = {present = present},
                platform = {os = "linux", arch = "x86_64", compatible = true}})
            if not result then error(tostring(locate_error)) end
            test.eq(result.status, "missing")
        end)
    end)
end

return test.run_cases(define_tests)
