-- MIT
local test = require("test")
local mcp = require("mcp")
local bounds = require("bounds")
local json_schema = require("json_schema")
local function define_tests()
    test.describe("MCP peer application tools", function()
        test.it("admits discovery and application results through the dispatcher output contracts", function()
            local values: {unknown} = {
                {tools = {}, diagnostics = {}},
                {id = "task-1", title = "Task", progress = 0, state = "open", owner = "agent"},
                {"first", "second"}, "complete", 12, true,
            }
            for _, name in ipairs({"app_tools", "call_tool"}) do
                local schema = assert(mcp.OUTPUT_SCHEMAS[name])
                for _, value in ipairs(values) do
                    test.is_nil(json_schema.validate(schema, {ok = true, value = value}))
                end
                test.not_nil(json_schema.validate(schema, {ok = "true", value = {}}))
                test.not_nil(json_schema.validate(schema, {ok = true, value = {}, invented = true}))
                test.not_nil(json_schema.validate(schema, {ok = false, error = {code = 12, message = "Failed"}}))
            end
        end)
        test.it("keeps omitted-node requests local and accepts a bounded peer", function()
            local local_request = assert(mcp.app_tools_arguments({arguments = {}}))
            test.is_nil(local_request.node)
            test.eq(local_request.operation, "list")
            local remote = assert(mcp.app_tools_arguments({arguments = {node = "runner-node"}}))
            test.eq(remote.node, "runner-node")
            local listed = assert(mcp.tests_arguments({arguments = {operation = "list", application = "sdk:app", node = "runner-node"}}))
            test.eq(listed.node, "runner-node")
            local status = assert(mcp.tests_arguments({arguments = {operation = "status", run_id = "run-1", node = "runner-node"}}))
            test.eq(status.node, "runner-node")
            test.is_nil(assert(mcp.tests_arguments({arguments = {operation = "status", run_id = "run-1"}})).node)
        end)
        test.it("publishes registry input and output schemas for local and peer discovery", function()
            local input = {type = "object", additionalProperties = false, required = {"title"},
                properties = {title = {type = "string"}}}
            local output = {type = "object", required = {"id"}, properties = {id = {type = "string"}}}
            local projection = mcp.app_projection({tools = {{alias = "demo_create", ref = "app.demo:create",
                definition_id = "app.demo:app", description = "Create an item", input_schema = input,
                output_schema = output, annotations = {}}}, diagnostics = {}}, {})
            local local_tools = assert(bounds.array(mcp.app_listing(projection, nil).tools, 64))
            local local_tool = assert(bounds.object(local_tools[1]))
            test.eq(assert(bounds.object(local_tool.input_schema)).type, "object")
            test.eq(assert(bounds.object(local_tool.output_schema)).type, "object")
            test.is_nil(local_tool.node)
            test.not_nil(json_schema.validate(local_tool.input_schema, {}))
            test.is_nil(json_schema.validate(local_tool.input_schema, {title = "Item"}))
            local peer_tools = assert(bounds.array(mcp.app_listing(projection, "runner-node").tools, 64))
            test.eq(assert(bounds.object(peer_tools[1])).node, "runner-node")
            test.not_nil(assert(bounds.object(peer_tools[1])).input_schema)
            test.not_nil(assert(bounds.object(peer_tools[1])).output_schema)
        end)
        test.it("uses the registry output contract and admits JSON when none is declared", function()
            local descriptor = {alias = "demo_result", ref = "app.demo:result", definition_id = "app.demo:app",
                description = "Return a result", input_schema = {type = "object"}, annotations = {readOnlyHint = true}}
            local projection = mcp.app_projection({tools = {descriptor}, diagnostics = {}}, {})
            local schema = assert(bounds.object(projection.listed[1].outputSchema))
            test.is_nil(json_schema.validate(schema, {ok = true, value = "complete"}))
            test.is_nil(json_schema.validate(schema, {ok = true, value = {"first", "second"}}))
            local declared = {alias = descriptor.alias, ref = descriptor.ref, definition_id = descriptor.definition_id,
                description = descriptor.description, input_schema = descriptor.input_schema, annotations = descriptor.annotations,
                output_schema = {type = "object", additionalProperties = false, required = {"id"}, properties = {id = {type = "string"}}}}
            local typed = mcp.app_projection({tools = {declared}, diagnostics = {}}, {})
            local output = assert(bounds.object(typed.listed[1].outputSchema))
            test.is_nil(json_schema.validate(output, {ok = true, value = {id = "result-1"}}))
            test.not_nil(json_schema.validate(output, {ok = true, value = "complete"}))
            test.not_nil(mcp.app_tool_reply(typed.tools.demo_result, {ok = true, value = {other = "result-1"}}))
        end)
        test.it("adds explicit app_tools calls and mutation keys without changing direct aliases", function()
            local request = assert(mcp.app_tools_arguments({arguments = {operation = "call", node = "runner-node",
                tool = "sdk_run", arguments = {configuration = "ci"}, idempotency_key = "run-1"}}))
            test.eq(request.tool, "sdk_run")
            test.eq(request.idempotency_key, "run-1")
            test.eq(assert(bounds.object(request.arguments)).configuration, "ci")
            local run = assert(mcp.tests_arguments({arguments = {operation = "run", application = "sdk:app", node = "runner-node",
                idempotency_key = "suite-1"}}))
            test.eq(run.idempotency_key, "suite-1")
            test.eq(assert(mcp.tool("app_tools")).operation, "bee.node.binding:app_tools")
            test.eq(assert(mcp.tool("tests")).operation, "bee.node.binding:tests_call")
        end)
        test.it("refuses malformed nodes and mixed discovery/call fields", function()
            for _, node in ipairs({false, 5, "*", "runner\n", string.rep("x", 161)}) do
                test.is_nil(mcp.app_tools_arguments({arguments = {node = node}}))
                test.is_nil(mcp.tests_arguments({arguments = {operation = "list", application = "sdk:app", node = node}}))
            end
            test.is_nil(mcp.app_tools_arguments({arguments = {node = "runner", tool = "sdk_run"}}))
            test.is_nil(mcp.app_tools_arguments({arguments = {operation = "call"}}))
            test.is_nil(mcp.app_tools_arguments({arguments = {operation = "call", tool = "sdk_run", arguments = false}}))
            test.is_nil(mcp.app_tools_arguments({arguments = {operation = "call", tool = "sdk_run", actor_id = "person"}}))
        end)
        test.it("advertises optional node and explicit call fields in the tool schemas", function()
            local tools = assert(bounds.object(assert(mcp.tool("app_tools")).schema.properties))
            for _, field in ipairs({"node", "operation", "tool", "arguments", "idempotency_key"}) do test.not_nil(tools[field]) end
            local tests = assert(bounds.object(assert(mcp.tool("tests")).schema.properties))
            test.not_nil(tests.node)
            test.not_nil(tests.idempotency_key)
        end)
    end)
end
return test.run_cases(define_tests)
