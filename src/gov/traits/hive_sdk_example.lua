-- MIT
local json = require("json")
local M = {}
type Object = {[string]: unknown}
M.OVERLAY = "test_sdk"
M.APP = "app.test_sdk:app"
M.RUN = "app.test_sdk:run"
M.PEER = "app.test_sdk:peer"
M.TEST = "app.test_sdk:configuration_test"
M.RUN_SOURCE = [=[local process = require("process")
type Object = {[string]: unknown}
local function run(args: Object): Object
    local configuration = tostring(args.configuration)
    local multiplier = configuration == "ci" and 3 or 1
    local total = 0
    for _, value in ipairs(args.inputs :: {number}) do total = total + value * multiplier end
    return {ok = true, value = {configuration = configuration, total = total, worker_pid = tostring(process.pid())}}
end
return {run = run}]=]
M.PEER_SOURCE = [=[local hive = require("hive")
local process = require("process")
type Object = {[string]: unknown}
local function run(args: Object): Object
    local result, err = hive.call({node = args.node, application = "app.test_sdk:app", service = "test-sdk",
        operation = "run", arguments = {configuration = args.configuration, inputs = args.inputs}, timeout = "10s"})
    if err then return {ok = false, error = {code = "PEER_FAILED", message = err}} end
    return {ok = true, value = {source_pid = tostring(process.pid()), remote = result}}
end
return {run = run}]=]
M.TEST_SOURCE = [=[local funcs = require("funcs")
type Object = {[string]: unknown}
local function run(): boolean
    local result, err = funcs.call("app.test_sdk:run", {configuration = "ci", inputs = {1, 2, 3}})
    if err or type(result) ~= "table" then return false end
    local reply = result :: Object
    local value = type(reply.value) == "table" and reply.value :: Object or nil
    return reply.ok == true and value ~= nil and value.total == 18
end
return {run = run}]=]
function M.entries(node: string, workspace: string, audience: string): {Object}
    local input: Object = {type = "object", additionalProperties = false, required = {"configuration", "inputs"},
        properties = {configuration = {type = "string", enum = {"ci", "development"}},
            inputs = {type = "array", maxItems = 32, items = {type = "number"}}}}
    local output: Object = {type = "object", required = {"configuration", "total", "worker_pid"}, properties = {
        configuration = {type = "string"}, total = {type = "number"}, worker_pid = {type = "string"}}}
    local peer_input: Object = {type = "object", additionalProperties = false, required = {"node", "configuration", "inputs"},
        properties = {node = {type = "string", maxLength = 160}, configuration = input.properties.configuration,
            inputs = input.properties.inputs}}
    local function requirement(name: string, capability: string, parameters: Object, target: string): Object
        return {id = "app.test_sdk:" .. name, kind = "ns.requirement",
            meta = {value_kind = "security.policy", capability = capability, parameters = parameters,
                reason = "Run the configured test SDK on the approved peer"},
            data = {targets = {{entry = target, path = ".security.policies +="}}}}
    end
    return {
        {id = M.APP, kind = "process.lua", meta = {type = "bee.app", application = {api_version = 1,
            title = "Project test SDK", menus = {"bee.shell:apps_menu"}, lifetime = "view", revision = "1", instance_policy = "multiple"}},
            data = {source = 'local client = require("client")\nlocal process = require("process")\nlocal function main(value: unknown)\n    local launch = assert(client.launch(value))\n    client.ready(launch)\n    assert(process.events()):receive()\nend\nreturn {main = main}',
                method = "main", modules = {"process"}, imports = {client = "bee.app:client"}}},
        {id = M.RUN, kind = "function.lua", meta = {type = "tool", application_ref = M.APP, hive = "open",
            hive_service = "test-sdk", hive_operation = {name = "run", revision = "1", effect = "read",
                input = input, output = {type = "object", required = {"ok", "value"}, properties = {ok = {type = "boolean"}, value = output}}},
            llm_alias = "test_sdk_run", llm_description = "Run a project configuration on this application copy",
            input_schema = assert(json.encode(input)), output_schema = assert(json.encode(output))},
            data = {source = M.RUN_SOURCE, method = "run", modules = {"process"}}},
        {id = M.PEER, kind = "function.lua", meta = {type = "tool", application_ref = M.APP,
            llm_alias = "test_sdk_peer", llm_description = "Ask this application to run its copy on the approved peer",
            input_schema = assert(json.encode(peer_input)), output_schema = '{"type":"object"}'},
            data = {source = M.PEER_SOURCE, method = "run", modules = {"process"}, imports = {hive = "bee.hive:hive"}}},
        {id = M.TEST, kind = "function.lua", meta = {type = "test", application = M.APP, application_ref = M.APP,
            suite = "project-sdk", hive = "open", hive_service = "test-sdk",
            hive_operation = {name = "configuration_test", revision = "1", effect = "read", input = {type = "object"}, output = {type = "boolean"}}},
            data = {source = M.TEST_SOURCE, method = "run", modules = {"funcs"}}},
        {id = "app.test_sdk:trait", kind = "registry.entry", meta = {type = "agent.trait", application_ref = M.APP, title = "Project test SDK"},
            data = {prompt = "Use test_sdk_run for the local configuration. Use test_sdk_peer with the approved node for a peer call. app_tools with node lists exposed peer tools; tests with node lists/runs the associated suite and reads its run_id on that node. Retry remote mutations with the same request and idempotency_key. A timeout means outcome unknown.",
                tools = {M.RUN, M.PEER}}},
        requirement("agent_tools", "agent.tools", {tools = {M.RUN, M.PEER}}, M.APP),
        requirement("peer_call", "hive.call", {nodes = {node}, workspaces = {workspace}, applications = {M.APP},
            services = {"test-sdk"}, operations = {"run"}}, M.APP),
        requirement("expose_run", "hive.expose", {operations = {M.RUN}, mode = "open", audiences = {audience}}, M.RUN),
        requirement("expose_test", "hive.expose", {operations = {M.TEST}, mode = "open", audiences = {audience}}, M.TEST),
    }
end
return M
