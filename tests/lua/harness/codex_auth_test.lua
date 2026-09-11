-- MIT. The Codex authentication-path gate. Only the actual pinned Codex
-- executable can close it, so this proof runs when BEE_CODEX_BIN names it:
-- an isolated home with no login state, a nonsecret sentinel key, and a
-- controlled local endpoint that records the authorization header. The
-- admitted profile's launch is run as prepared by the driver. Without the
-- executable the gate stays open and the capability says so.
local test = require("test")
local exec = require("exec")
local env = require("env")
local time = require("time")
local launch = require("launch")
local quote = require("quote")
local SENTINEL = "sk-sentinel-bee-000"
local function read_all(stream): string
    local content = ""
    while true do
        local chunk: unknown = stream:read(65536)
        if type(chunk) ~= "string" or chunk == "" then break end
        content = content .. (chunk :: string)
    end
    return content
end
-- Runs one shell command line; the command carries no single quotes, and
-- values that might are passed through the environment.
local function shell(command: string, environment: {[string]: string}?): (string, integer)
    local executor = assert(exec.get("bee.placement.native:executor"))
    local proc, exec_error = executor:exec("sh -c '" .. command .. "'", {env = environment or {}})
    if not proc then error("exec " .. command .. ": " .. tostring(exec_error)) end
    local stdout = proc:stdout_stream()
    local started, start_error = proc:start()
    if not started then error("start " .. command .. ": " .. tostring(start_error)) end
    local output = read_all(stdout)
    local code = proc:wait()
    stdout:close()
    executor:release()
    return output, math.floor(tonumber(code) or -1)
end
local function fixture_bin(): string
    local bin, err = env.get("bee.harness.catalog:fixture_bin")
    if err or type(bin) ~= "string" or bin == "" then error("BEE_FIXTURE_BIN is not set for the test runtime") end
    return bin
end
local function codex_bin(): string?
    local bin, err = env.get("bee.harness.catalog:codex_bin")
    if err or type(bin) ~= "string" or bin == "" then return nil end
    return bin
end
local function define_tests()
    test.describe("Codex authentication path", function()
        test.it("sends the projected API key to the configured endpoint from an isolated home, or reports the gate open", function()
            local codex = codex_bin()
            if not codex then
                test.eq(launch.CODEX_AUTHENTICATION, "unproven")
                return
            end
            local version = shell(codex .. " --version")
            test.is_true(version:find("codex", 1, true) ~= nil)
            local root = ".wippy/codex-auth-" .. tostring(math.floor(time.now():unix_nano() / 1000))
            local record = root .. "/endpoint.jsonl"
            local endpoint_executor = assert(exec.get("bee.placement.native:executor"))
            local _ = shell("mkdir -p " .. root .. "/home/.codex " .. root .. "/work")
            local endpoint, endpoint_error = endpoint_executor:exec(fixture_bin() .. "/endpoint " .. record)
            if not endpoint then error("endpoint: " .. tostring(endpoint_error)) end
            local endpoint_out = endpoint:stdout_stream()
            local endpoint_started, endpoint_start_error = endpoint:start()
            if not endpoint_started then error("start endpoint: " .. tostring(endpoint_start_error)) end
            local port: string? = nil
            for _ = 1, 100 do
                local written = shell("cat " .. record .. ".port 2>/dev/null")
                port = written:match("%d+")
                if port then break end
                time.sleep("50ms")
            end
            if not port then error("the endpoint did not report its port") end
            -- The configuration the enablement needs: a provider that takes the
            -- key from OPENAI_API_KEY and speaks the responses API over HTTP to
            -- the host-configured base URL. Nothing here is a secret.
            local config = table.concat({'model_provider = "bee"', 'model = "gpt-5"', "[model_providers.bee]", 'name = "bee"',
                'base_url = "http://127.0.0.1:' .. tostring(port) .. '/v1"', 'env_key = "OPENAI_API_KEY"', 'wire_api = "responses"'}, "\\n")
            local escaped = config:gsub('"', '\\"'):gsub("\n", "\\n")
            shell('printf "%b\\n" "' .. escaped .. '" > ' .. root .. "/home/.codex/config.toml")
            local written_config = shell("cat " .. root .. "/home/.codex/config.toml")
            -- Never launch against a provider by accident: the local endpoint
            -- must be configured before the executable runs.
            if not written_config:find("model_providers.bee", 1, true) then error("the isolated configuration was not written: [" .. written_config .. "]") end
            -- The admitted launch exactly as the driver prepares it: the brief on
            -- stdin, read until end of file, which needs a runtime that can
            -- close stdin; without that the gate stays open here too.
            local specification = launch.specification({profile_id = "exec", brief = "say hi", sandbox = "read-only", resume_ref = nil})
            test.eq(specification.stdin_eof, true)
            local argv: {string} = {codex}
            for _, item in ipairs(specification.argv) do argv[#argv + 1] = item end
            local home = shell("cd " .. root .. "/home && pwd")
            home = home:gsub("%s+$", "")
            local executor = assert(exec.get("bee.placement.native:executor"))
            local proc, proc_error = executor:exec(quote.line(argv), {work_dir = root .. "/work", env = {HOME = home, CODEX_HOME = home .. "/.codex", OPENAI_API_KEY = SENTINEL, PATH = "/usr/bin:/bin"}})
            if not proc then error("exec codex: " .. tostring(proc_error)) end
            local stdout = proc:stdout_stream()
            local stderr = proc:stderr_stream()
            local handle = proc :: {[string]: unknown}
            if type(handle.close_stdin) ~= "function" then
                proc:close(true)
                stdout:close()
                stderr:close()
                executor:release()
                endpoint:signal(9)
                endpoint:wait()
                endpoint:close(true)
                endpoint_out:close()
                endpoint_executor:release()
                shell("rm -rf " .. root)
                test.eq(launch.CODEX_AUTHENTICATION, "unproven")
                return
            end
            local started, start_error = proc:start()
            if not started then error("start codex: " .. tostring(start_error)) end
            proc:write_stdin(specification.stdin or "say hi")
            local closed, close_error = (handle.close_stdin :: (unknown) -> (unknown, unknown))(proc)
            if not closed then error("close stdin: " .. tostring(close_error)) end
            local out = read_all(stdout)
            local err = read_all(stderr)
            local exit_code = proc:wait()
            stdout:close()
            stderr:close()
            executor:release()
            endpoint:signal(9)
            endpoint:wait()
            endpoint:close(true)
            endpoint_out:close()
            endpoint_executor:release()
            local recorded = shell("cat " .. record)
            if not recorded:find('"path": "/v1/responses"', 1, true) or not recorded:find('"authorization": "Bearer ' .. SENTINEL .. '"', 1, true) or not out:find('"type":"thread.started"', 1, true) then
                local config_written = shell("cat " .. root .. "/home/.codex/config.toml")
                error("authentication path not proven; exit " .. tostring(exit_code) .. "; endpoint [" .. recorded:sub(1, 300):gsub(SENTINEL, "<sentinel>") .. "]; config [" .. config_written:sub(1, 300) .. "]; stdout [" .. out:sub(1, 400):gsub(SENTINEL, "<sentinel>") .. "]; stderr [" .. err:sub(1, 600):gsub(SENTINEL, "<sentinel>") .. "]")
            end
            test.is_nil(out:find(SENTINEL, 1, true))
            test.is_nil(err:find(SENTINEL, 1, true))
            shell("rm -rf " .. root)
        end)
    end)
end
return test.run_cases(define_tests)
