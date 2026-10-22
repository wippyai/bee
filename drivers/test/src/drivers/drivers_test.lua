local test = require("test")
local fs = require("fs")
local drivers = require("drivers")
local placements = require("placements")

local CLAUDE_HOME = "/home/node"

local function recording(path: string): string
    local volume = assert(fs.get("bee.drivers.tests:fixtures"))
    return assert(volume:readfile(path))
end

local function joined(list: {string}): string return table.concat(list, " ") end

local function contains(list: {string}, item: string): boolean
    for _, candidate in ipairs(list) do if candidate == item then return true end end
    return false
end

local function without(capability: string): {[string]: any}
    local allows: {string} = {}
    for _, item in ipairs(placements.DOCKER.allows) do if item ~= capability then allows[#allows + 1] = item end end
    return {kind = "container", mounts = placements.DOCKER.mounts, network = "bridge", allows = allows}
end

local function read(driver_id: string, path: string, size: integer): (any, integer, integer)
    local reader = assert(drivers.reader(driver_id, false))
    local content = recording(path)
    local terminal: any = nil
    local observations, problems = 0, 0
    for offset = 1, #content, size do
        local step = assert(reader:feed(content:sub(offset, offset + size - 1)))
        observations = observations + #step.observations
        problems = problems + #step.problems
        terminal = step.terminal or terminal
    end
    local last = assert(reader:finish())
    observations = observations + #last.observations
    return last.terminal or terminal, observations, problems
end

local function define_tests()
    test.describe("Driver library", function()
        test.it("lists the activated drivers with their options, profiles and credentials", function()
            local list = assert(drivers.list())
            local ids: {string} = {}
            for _, driver in ipairs(list) do
                ids[#ids + 1] = driver.id
                test.is_true(driver.unattended, driver.id .. " declares an unattended mode")
            end
            test.eq(joined(ids), "agy claude codex grok muse opencode")
            local claude = assert(drivers.get("claude"))
            test.eq(claude.title, "Claude Code")
            local model = nil
            for _, option in ipairs(claude.options) do if option.name == "model" then model = option end end
            test.eq(assert(model).label, "Model")
            test.is_true(#claude.profiles > 0)
            test.is_true(contains(claude.capabilities, "bypass"))
            test.is_true(contains(claude.capabilities, "profile-option"))
            test.is_true(contains(assert(drivers.get("codex")).capabilities, "write-anywhere"))
            test.eq(claude.credentials.files[1].path, ".claude/.credentials.json")
            test.is_true(claude.credentials.files[1].write_back)
            test.is_true(contains(claude.credentials.variables, "CLAUDE_CODE_OAUTH_TOKEN"))
        end)
        test.it("names an unknown driver as not found", function()
            local driver, err = drivers.get("nonexistent")
            test.is_nil(driver)
            test.is_true(errors.is(err, errors.NOT_FOUND))
            local launch, launch_err = drivers.launch("nonexistent", {brief = "x", home = CLAUDE_HOME, placement = placements.DOCKER})
            test.is_nil(launch)
            test.is_true(errors.is(launch_err, errors.NOT_FOUND))
        end)
        test.it("launches an unattended Claude run in a container with the driver's MCP configuration", function()
            local launch = assert(drivers.launch("claude", {brief = "say pong", home = CLAUDE_HOME, placement = placements.DOCKER,
                unattended = true, options = {model = "sonnet"}}))
            test.eq(launch.executable, "claude")
            local argv = joined(launch.argv)
            test.is_true(argv:find("--permission-mode bypassPermissions", 1, true) ~= nil, argv)
            test.is_true(argv:find("--model sonnet", 1, true) ~= nil, argv)
            test.is_true(contains(launch.argv, "--strict-mcp-config"), argv)
            test.eq(launch.argv[#launch.argv], "say pong")
            test.eq(launch.environment.CLAUDE_CONFIG_DIR, CLAUDE_HOME .. "/.claude")
        end)
        test.it("renders the host gateway as the CLI's only MCP server", function()
            local launch = assert(drivers.launch("claude", {brief = "say pong", home = CLAUDE_HOME, placement = placements.DOCKER,
                gateway = {endpoint = "172.17.0.1:9000", action_id = "run-1", tools = {"kb_search"}, hooks = {}, token_environment = "RUN_GATEWAY_TOKEN"}}))
            local argv = joined(launch.argv)
            test.is_true(argv:find("http://172.17.0.1:9000/mcp/run-1", 1, true) ~= nil, argv)
            test.is_true(argv:find("${RUN_GATEWAY_TOKEN}", 1, true) ~= nil, argv)
        end)
        test.it("launches an unattended Codex run with the brief on stdin", function()
            local launch = assert(drivers.launch("codex", {brief = "say pong", home = CLAUDE_HOME, placement = placements.DOCKER, unattended = true}))
            test.eq(launch.executable, "codex")
            test.is_true(contains(launch.argv, "--dangerously-bypass-approvals-and-sandbox"), joined(launch.argv))
            test.eq(launch.stdin, "say pong")
        end)
        test.it("refuses unattended runs a placement does not allow to bypass permissions", function()
            local launch, err = drivers.launch("claude", {brief = "x", home = CLAUDE_HOME, placement = without("bypass"), unattended = true})
            test.is_nil(launch)
            test.is_true(errors.is(err, errors.INVALID))
            test.is_true(tostring(err):find("permission capabilities exceed", 1, true) ~= nil, tostring(err))
        end)
        test.it("refuses an explicit option the unattended mode sets differently", function()
            local launch, err = drivers.launch("claude", {brief = "x", home = CLAUDE_HOME, placement = placements.DOCKER,
                unattended = true, options = {permission_mode = "plan"}})
            test.is_nil(launch)
            test.is_true(tostring(err):find("permission_mode conflicts with unattended", 1, true) ~= nil, tostring(err))
        end)
        test.it("refuses reserved names as options and a launch without a placement", function()
            local launch, err = drivers.launch("claude", {brief = "x", home = CLAUDE_HOME, placement = placements.DOCKER, options = {placement = {}}})
            test.is_nil(launch)
            test.is_true(errors.is(err, errors.INVALID))
            local unplaced, unplaced_err = drivers.launch("claude", {brief = "x", home = CLAUDE_HOME})
            test.is_nil(unplaced)
            test.is_true(errors.is(unplaced_err, errors.INVALID))
        end)
        test.it("reads a recorded Claude stream fed in chunks into records and one terminal report", function()
            local terminal, observations, problems = read("claude", "/claude/stream-json-2/plain.jsonl", 37)
            test.is_true(observations > 0)
            test.eq(problems, 0)
            test.eq(terminal.outcome, "succeeded")
            test.eq(terminal.answer, "pong")
        end)
        test.it("reads a recorded Codex stream with provider notices", function()
            local terminal, observations = read("codex", "/codex/exec-json-1/tool.jsonl", 64)
            test.is_true(observations > 0)
            test.eq(terminal.outcome, "succeeded")
        end)
        test.it("reports frames that are not JSON as problems", function()
            local reader = assert(drivers.reader("claude", false))
            local step = assert(reader:feed("not json\n"))
            test.eq(#step.problems, 1)
            test.eq(step.problems[1].index, 1)
            test.eq(#step.observations, 0)
        end)
    end)
end

return test.run_cases(define_tests)
