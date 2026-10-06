-- MIT. The MCP protocol library, pure: strict JSON-RPC decoding, a closed
-- tool catalog filtered by the binding, bounded tool arguments with the
-- transport budget, and binding validity under an epoch.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local mcp = require("mcp")
local gateway = require("gateway")
local registry = require("registry")
local json = require("json")
type Object = {[string]: unknown}

local function entry(id: string): Object
    local found, err = registry.get(id)
    if err or not found then error(id .. ": " .. tostring(err or "missing registry entry")) end
    return assert(bounds.object(found))
end

local function conforms(value: unknown, schema_value: unknown, location: string)
    local schema = assert(bounds.object(schema_value))
    local kind = schema.type
    if kind == "object" then
        if type(value) ~= "table" then error(location .. " must be an object") end
        local object = assert(bounds.object(value))
        local properties = assert(bounds.object(schema.properties))
        for _, name in ipairs(principals.strings(schema.required or {})) do
            if object[name] == nil then error(location .. " is missing " .. name) end
        end
        for name, child in pairs(object) do
            local child_schema = properties[name]
            if child_schema == nil and schema.additionalProperties == false then error(location .. " has unexpected " .. name) end
            if child_schema ~= nil then conforms(child, child_schema, location .. "." .. name) end
        end
    elseif kind == "array" then
        if type(value) ~= "table" then error(location .. " must be an array") end
        local item_schema = schema.items
        if item_schema == nil then error(location .. " has no item schema") end
        for index, child in ipairs(principals.items(value)) do conforms(child, item_schema, location .. "[" .. tostring(index) .. "]") end
    elseif kind == "string" then
        if type(value) ~= "string" then error(location .. " must be a string") end
    elseif kind == "integer" then
        if type(value) ~= "number" or value ~= math.floor(value) then error(location .. " must be an integer") end
    elseif kind == "boolean" then
        if type(value) ~= "boolean" then error(location .. " must be a boolean") end
    else
        error(location .. " has unsupported schema type " .. tostring(kind))
    end
end

local function define_tests()
    test.describe("Gateway MCP protocol", function()
        test.it("lists every tool with an input schema whose properties are a JSON object", function()
            -- A client validates tools/list as a whole: one schema whose
            -- properties arrive as a list makes it drop every tool.
            local names: {string} = {}
            for _, tool in ipairs(mcp.TOOLS) do names[#names + 1] = tool.name end
            local listed = principals.objects(mcp.list(names).tools)
            test.eq(#listed, #names)
            for _, tool in ipairs(listed) do
                local schema = assert(bounds.object(tool.inputSchema))
                local encoded = assert(json.encode(schema.properties))
                test.eq(tostring(tool.name) .. " " .. encoded:sub(1, 1), tostring(tool.name) .. " {")
            end
        end)
        test.it("publishes nested unconstrained session schemas as JSON objects", function()
            local listed = principals.objects(mcp.list({"session_send", "session_run"}).tools)
            for _, tool in ipairs(listed) do
                local encoded = assert(json.encode(tool.inputSchema))
                test.is_nil((encoded:find('"value":[]', 1, true)))
                test.is_true(encoded:find('"value":{}', 1, true) ~= nil)
            end
        end)
        test.it("discovers the production traits and overlay schema", function()
            for _, expected in ipairs({
                {id = "bee.gov.traits:authoring_trait", tools = {"bee.gov.binding:overlay_call"}},
                {id = "bee.gov.traits:application_delivery_trait", tools = {"bee.gov.binding:delivery_call"}},
                {id = "bee.gov.traits:application_publish_trait", tools = {"bee.gov.binding:delivery_call"}},
                {id = "bee.gov.traits:application_tests_trait", tools = {"bee.node.binding:tests_call"}},
            }) do
                local trait = entry(expected.id)
                test.eq(trait.kind, "registry.entry")
                test.eq((assert(bounds.object(trait.meta))).type, "agent.trait")
                local data = assert(bounds.object(trait.data))
                test.eq(#(principals.strings(data.tools)), #expected.tools)
                for index, tool in ipairs(expected.tools) do test.eq((principals.strings(data.tools))[index], tool) end
            end
            local overlay = entry("bee.gov.binding:overlay_call")
            local metadata = assert(bounds.object(overlay.meta))
            local encoded = metadata.input_schema
            if type(encoded) ~= "string" then error("overlay input schema is missing") end
            local schema, schema_error = json.decode(encoded)
            if schema_error or type(schema) ~= "table" then error("decode overlay input schema: " .. tostring(schema_error)) end
            local properties = assert(bounds.object((assert(bounds.object(schema))).properties))
            for _, name in ipairs({"operation", "overlay_id", "expected_revision", "idempotency_key"}) do
                test.not_nil(properties[name])
            end
        end)
        test.it("offers the application tests tool with the node's own request decoder", function()
            local tool = mcp.tool("tests")
            if not tool then error("tests tool") end
            test.eq(tool.operation, "bee.node.binding:tests_call")
            test.eq(tool.policies[1], "bee.gateway.env:tool_tests_policy_ref")
            test.is_true(mcp.is_tool_policy_reference(tool.policies[1]))
            test.not_nil(mcp.OUTPUT_SCHEMAS.tests)
            local properties = assert(bounds.object(tool.schema.properties))
            for _, name in ipairs({"operation", "application", "filter", "run_id"}) do test.not_nil(properties[name]) end
            test.eq((assert(bounds.object(tool.annotations))).readOnlyHint, false)
            local run = mcp.tests_arguments({arguments = {operation = "run", application = "tally", filter = "smoke"}})
            test.eq(run and run.operation, "run")
            test.eq(run and run.application, "tally")
            test.eq(run and run.filter, "smoke")
            local status = mcp.tests_arguments({arguments = {operation = "status", run_id = "run-1"}})
            test.eq(status and status.run_id, "run-1")
            local _, missing = mcp.tests_arguments({arguments = {operation = "run"}})
            test.eq(missing, "run needs an application")
            local _, extra = mcp.tests_arguments({arguments = {operation = "list", application = "tally", workspace_id = "w"}})
            test.not_nil(extra)
            local _, mixed = mcp.tests_arguments({arguments = {operation = "status", run_id = "run-1", application = "tally"}})
            test.eq(mixed, "status takes only run_id")
            test.is_true(mcp.INSTRUCTIONS:find("tests run", 1, true) ~= nil)
        end)
        test.it("decodes capability elevation requests with a bounded TTL", function()
            local tool = mcp.tool("request_capability")
            if not tool then error("request_capability tool") end
            test.eq(tool.operation, "bee.gateway.binding:request_capability")
            local properties = assert(bounds.object(tool.schema.properties))
            for _, name in ipairs({"capability", "parameters", "ttl_ms"}) do test.not_nil(properties[name]) end
            local chosen = mcp.capability_arguments({arguments = {capability = "app.database",
                parameters = {name = "journal"}, ttl_ms = 60000}})
            test.eq(chosen and chosen.capability, "app.database")
            test.eq(chosen and chosen.ttl_ms, 60000)
            local defaulted = mcp.capability_arguments({arguments = {capability = "threads.read"}})
            test.eq(defaulted and (assert(bounds.object(defaulted.parameters))) ~= nil, true)
            local _, missing = mcp.capability_arguments({arguments = {parameters = {}}})
            test.eq(missing, "capability is required and must be an identifier")
            local _, bad_ttl = mcp.capability_arguments({arguments = {capability = "threads.read", ttl_ms = 0}})
            test.eq(bad_ttl, "ttl_ms must be between 1 and 86400000")
            local _, bad_params = mcp.capability_arguments({arguments = {capability = "threads.read", parameters = "x"}})
            test.eq(bad_params, "parameters must be an object")
            local status = mcp.tool("capability_status")
            if not status then error("capability_status tool") end
            test.eq(status.operation, "bee.gateway.binding:capability_status")
            local polled = mcp.capability_status_arguments({arguments = {approval_id = "approval-1"}})
            test.eq(polled and polled.approval_id, "approval-1")
            local _, no_id = mcp.capability_status_arguments({arguments = {}})
            test.eq(no_id, "approval_id is required and must be an identifier")
            test.not_nil(mcp.OUTPUT_SCHEMAS.request_capability)
            test.not_nil(mcp.OUTPUT_SCHEMAS.capability_status)
        end)
        test.it("exercises a held process or HTTP elevation through its own tool with bounded arguments", function()
            local run = mcp.tool("process_run")
            if not run then error("process_run tool") end
            test.eq(run.operation, "bee.gateway.binding:process_run")
            local decoded = mcp.process_run_arguments({arguments = {approval_id = "approval-1",
                arguments = {"--jobs", "4"}, timeout_ms = 60000}})
            test.eq(decoded and decoded.approval_id, "approval-1")
            test.eq(decoded and #(principals.strings(decoded.arguments)), 2)
            test.eq(decoded and decoded.timeout_ms, 60000)
            local _, unnamed = mcp.process_run_arguments({arguments = {arguments = {}}})
            test.eq(unnamed, "approval_id is required and must be an identifier")
            local _, non_text = mcp.process_run_arguments({arguments = {approval_id = "approval-1", arguments = {1}}})
            test.eq(non_text, "arguments must be a list of strings")
            local _, slow = mcp.process_run_arguments({arguments = {approval_id = "approval-1", timeout_ms = 600001}})
            test.eq(slow, "timeout_ms must be between 1 and 600000")
            local http = mcp.tool("http_request")
            if not http then error("http_request tool") end
            test.eq(http.operation, "bee.gateway.binding:http_request")
            local request = mcp.http_request_arguments({arguments = {approval_id = "approval-1", method = "POST",
                url = "https://api.example.com/v1/items", headers = {Accept = "application/json"}, body = "{}"}})
            test.eq(request and request.url, "https://api.example.com/v1/items")
            test.eq(request and request.method, "POST")
            local _, no_url = mcp.http_request_arguments({arguments = {approval_id = "approval-1", method = "GET"}})
            test.eq(no_url, "url is required")
            test.not_nil(mcp.OUTPUT_SCHEMAS.process_run)
            test.not_nil(mcp.OUTPUT_SCHEMAS.http_request)
            local status = assert(bounds.object(mcp.OUTPUT_SCHEMAS.capability_status))
            local value = assert(bounds.object((assert(bounds.object(status.properties))).value))
            test.not_nil((assert(bounds.object(value.properties))).tools)
        end)
        test.it("offers installation requests as write tools apart from the read-only components tool", function()
            local listed = principals.objects(mcp.list({"components", "install_request", "uninstall_request", "install_status"}).tools)
            test.eq(#listed, 4)
            for _, item in ipairs(listed) do
                local annotations = assert(bounds.object(item.annotations))
                test.eq(annotations.readOnlyHint, item.name == "components")
                test.eq(annotations.destructiveHint, false)
            end
            for _, name in ipairs({"install_request", "uninstall_request", "install_status"}) do
                local tool = mcp.tool(name)
                if not tool then error(name .. " tool") end
                test.eq(tool.operation, "bee.gateway.binding:" .. name)
                test.eq(tool.policies[1], mcp.TOOL_POLICY_REFS.install)
                test.is_true(mcp.is_tool_policy_reference(tool.policies[1]))
                test.not_nil(mcp.OUTPUT_SCHEMAS[name])
            end
            local install = mcp.install_arguments({arguments = {component = "acme/tool", version = "1.2.0"}}, false)
            test.eq(install and install.version, "1.2.0")
            local newest = mcp.install_arguments({arguments = {component = "acme/tool"}}, false)
            test.is_nil(newest and newest.version)
            local _, removal_version = mcp.install_arguments({arguments = {component = "acme/tool", version = "1.2.0"}}, true)
            test.eq(removal_version, "unknown field version")
            local _, parameters = mcp.install_arguments({arguments = {component = "acme/tool", parameters = {}}}, false)
            test.eq(parameters, "unknown field parameters")
            local _, missing = mcp.install_arguments({arguments = {}}, false)
            test.eq(missing, "component is required as owner/name")
            local polled = mcp.install_status_arguments({arguments = {request_id = "approval-1"}})
            test.eq(polled and polled.request_id, "approval-1")
            local _, no_id = mcp.install_status_arguments({arguments = {}})
            test.eq(no_id, "request_id is required and must be an identifier")
        end)
        test.it("offers publication requests as one write tool and one read-only status", function()
            local listed = principals.objects(mcp.list({"components", "publish_request", "publish_status"}).tools)
            test.eq(#listed, 3)
            for _, item in ipairs(listed) do
                local annotations = assert(bounds.object(item.annotations))
                test.eq(annotations.readOnlyHint, item.name ~= "publish_request")
                test.eq(annotations.destructiveHint, false)
            end
            for _, name in ipairs({"publish_request", "publish_status"}) do
                local tool = mcp.tool(name)
                if not tool then error(name .. " tool") end
                test.eq(tool.operation, "bee.gateway.binding:" .. name)
                test.eq(tool.policies[1], mcp.TOOL_POLICY_REFS.hub_publish)
                test.is_true(mcp.is_tool_policy_reference(tool.policies[1]))
                test.not_nil(mcp.OUTPUT_SCHEMAS[name])
            end
            local request = mcp.hub_publish_arguments({arguments = {component = "bee/probe",
                version = "0.0.1-probe.1", visibility = "private", source = "/home/person/work/probe"}})
            test.eq(request and request.visibility, "private")
            local _, missing = mcp.hub_publish_arguments({arguments = {component = "bee/probe",
                version = "0.0.1-probe.1", visibility = "private"}})
            test.eq(missing, "source is required as an absolute locked source tree")
            local _, visibility = mcp.hub_publish_arguments({arguments = {component = "bee/probe",
                version = "0.0.1-probe.1", visibility = "internal", source = "/home/person/work/probe"}})
            test.eq(visibility, "visibility is required as public or private")
            local polled = mcp.hub_publish_status_arguments({arguments = {request_id = "approval-1"}})
            test.eq(polled and polled.request_id, "approval-1")
            local _, no_id = mcp.hub_publish_status_arguments({arguments = {}})
            test.eq(no_id, "request_id is required and must be an identifier")
        end)
        test.it("decodes one strict JSON-RPC request and refuses the rest", function()
            local call = mcp.decode({jsonrpc = "2.0", id = 7, method = "tools/list"})
            if not call then error("decode") end
            test.eq(call.method, "tools/list")
            test.eq(call.id, 7)
            local _, batch = mcp.decode({{jsonrpc = "2.0", id = 1, method = "ping"}})
            test.eq(batch, "request must be one JSON-RPC object")
            local _, version = mcp.decode({jsonrpc = "1.0", id = 1, method = "ping"})
            test.eq(version, "jsonrpc must be 2.0")
            local _, params = mcp.decode({jsonrpc = "2.0", id = 1, method = "ping", params = "x"})
            test.eq(params, "params must be an object")
            local _, id = mcp.decode({jsonrpc = "2.0", id = {}, method = "ping"})
            test.eq(id, "id must be a string or number")
            local notification = mcp.decode({jsonrpc = "2.0", method = "notifications/initialized"})
            if not notification then error("notification") end
            test.eq(notification.notification, true)
            local _, unnumbered = mcp.decode({jsonrpc = "2.0", method = "tools/list"})
            test.eq(unnumbered, "id is required")
            test.eq(mcp.failure(3, mcp.METHOD_NOT_FOUND, "no").error.code, mcp.METHOD_NOT_FOUND)
            test.eq(mcp.result(3, {a = 1}).result.a, 1)
            test.eq(mcp.initialize().protocolVersion, mcp.PROTOCOL)
        end)
        test.it("orients a connecting agent toward the docs, the authoring guide and delivery", function()
            local result = mcp.initialize(mcp.INSTRUCTIONS)
            test.eq(result.instructions, mcp.INSTRUCTIONS)
            test.is_nil(mcp.initialize().instructions)
            for _, phrase in ipairs({"docs", "components", "capabilities", "overlay", "guide", "include_example", "freeze", "delivery", "preflight", "Needs you", "session"}) do
                test.is_true(mcp.INSTRUCTIONS:find(phrase, 1, true) ~= nil, phrase)
            end
            local names: {[string]: boolean} = {session = true}
            for _, tool in ipairs(mcp.TOOLS) do names[tool.name] = true end
            for _, tool_name in ipairs({"docs", "components", "capabilities", "overlay", "delivery"}) do test.is_true(names[tool_name] == true, tool_name) end
        end)
        test.it("admits bounded full workspace sources while retaining body and owner protocol limits", function()
            test.eq(mcp.MAX_WORKSPACE_TEXT_BYTES, 65536)
            test.eq(mcp.MAX_WORKSPACE_BASE64_BYTES, 87384)
            -- The HTTP adapter applies this whole-request limit through http.request(max_body=...).
            -- It leaves room for JSON escaping a full 64 KiB text value while bounding its envelope.

            local workspace_tools = principals.objects(mcp.list({"overlay"}).tools)
            local input_schema = assert(bounds.object(workspace_tools[1].inputSchema))
            local properties = assert(bounds.object(input_schema.properties))
            test.not_nil(properties.overlay_id)
            test.is_nil(properties.workspace_id)
            local text_property = assert(bounds.object(properties.content))
            local base64_property = assert(bounds.object(properties.content_base64))
            test.eq(text_property.maxLength, mcp.MAX_WORKSPACE_TEXT_BYTES)
            test.eq(base64_property.maxLength, mcp.MAX_WORKSPACE_BASE64_BYTES)

            local source = string.rep("x", 20 * 1024)
            test.is_true(#source > 8192)
            local large = mcp.overlay_arguments({arguments = {operation = "put", overlay_id = "research-candidate",
                expected_revision = 2, idempotency_key = "large-source", path = "entries.json", content = source}})
            test.eq(large and large.content, source)
            local at_text_limit = mcp.overlay_arguments({arguments = {operation = "put", overlay_id = "research-candidate",
                expected_revision = 3, idempotency_key = "max-source", path = "entries.json",
                content = string.rep("x", mcp.MAX_WORKSPACE_TEXT_BYTES)}})
            test.eq(at_text_limit and #(at_text_limit.content or ""), mcp.MAX_WORKSPACE_TEXT_BYTES)
            local _, oversized_text = mcp.overlay_arguments({arguments = {operation = "put", overlay_id = "research-candidate",
                expected_revision = 4, idempotency_key = "oversized-source", path = "entries.json",
                content = string.rep("x", mcp.MAX_WORKSPACE_TEXT_BYTES + 1)}})
            test.eq(oversized_text, "content exceeds the 65,536-byte MCP chunk bound; put the first chunk, then append with offset")
            local append = mcp.overlay_arguments({arguments = {operation = "append", overlay_id = "research-candidate",
                expected_revision = 5, idempotency_key = "append-source", path = "entries.json", offset = 65536,
                result_digest = string.rep("a", 64), content = "more"}})
            test.eq(append and append.offset, 65536)

            -- 65,536 zero bytes in canonical padded base64 exercise the existing
            -- Governance decoder at the MCP allowance's exact decoded boundary.
            local full_base64 = string.rep("A", mcp.MAX_WORKSPACE_BASE64_BYTES - 2) .. "=="
            local binary = mcp.overlay_arguments({arguments = {operation = "put", overlay_id = "research-candidate",
                expected_revision = 5, idempotency_key = "max-binary", path = "assets/full.bin", content_base64 = full_base64}})
            test.eq(binary and binary.content_base64, full_base64)
            local _, invalid_base64 = mcp.overlay_arguments({arguments = {operation = "put", overlay_id = "research-candidate",
                expected_revision = 6, idempotency_key = "invalid-binary", path = "assets/invalid.bin", content_base64 = "!!!!"}})
            test.eq(invalid_base64, "invalid base64 content")
            -- A valid unpadded value at the encoded-length cap can decode to
            -- 65,538 bytes, so the MCP boundary checks decoded bytes as well.
            local _, oversized_decoded = mcp.overlay_arguments({arguments = {operation = "put", overlay_id = "research-candidate",
                expected_revision = 7, idempotency_key = "oversized-decoded", path = "assets/too-large.bin",
                content_base64 = string.rep("A", mcp.MAX_WORKSPACE_BASE64_BYTES)}})
            test.eq(oversized_decoded, "decoded content exceeds the MCP file bound")
            local _, oversized_base64 = mcp.overlay_arguments({arguments = {operation = "put", overlay_id = "research-candidate",
                expected_revision = 8, idempotency_key = "oversized-binary", path = "assets/large.bin",
                content_base64 = string.rep("A", mcp.MAX_WORKSPACE_BASE64_BYTES + 1)}})
            test.eq(oversized_base64, "content_base64 exceeds the MCP body bound")
        end)
        test.it("accepts a readiness answer only under this generation with the proof over this nonce", function()
            local generation = {epoch = 3, restarts = 1}
            local proof = gateway.proof("listener-secret", generation, "nonce-1")
            if not proof then error("proof") end
            test.is_true((gateway.verify("listener-secret", generation, "nonce-1", {epoch = 3, restarts = 1, proof = proof})))
            local _, other_nonce = gateway.verify("listener-secret", generation, "nonce-2", {epoch = 3, restarts = 1, proof = proof})
            test.eq((other_nonce).error.code, "DENIED")
            local _, other_restart = gateway.verify("listener-secret", generation, "nonce-1", {epoch = 3, restarts = 2, proof = proof})
            test.eq((other_restart).error.code, "CONFLICT")
            local _, other_epoch = gateway.verify("listener-secret", generation, "nonce-1", {epoch = 2, restarts = 1, proof = proof})
            test.eq((other_epoch).error.code, "CONFLICT")
            local _, stale_restart = gateway.verify("listener-secret", generation, "nonce-1", {epoch = 3, restarts = 0, proof = proof})
            test.eq((stale_restart).error.code, "CONFLICT")
            local stale_generation = {epoch = 2, restarts = 1}
            local stale_proof = gateway.proof("listener-secret", stale_generation, "nonce-1")
            local _, stale_proof_reply = gateway.verify("listener-secret", generation, "nonce-1", {epoch = 3, restarts = 1, proof = stale_proof})
            test.eq((stale_proof_reply).error.code, "DENIED")
            local forged = gateway.proof("another-secret", generation, "nonce-1")
            local _, forgery = gateway.verify("listener-secret", generation, "nonce-1", {epoch = 3, restarts = 1, proof = forged})
            test.eq((forgery).error.code, "DENIED")
            local _, missing = gateway.verify("listener-secret", generation, "nonce-1", {epoch = 3, restarts = 1})
            test.eq((missing).error.code, "DENIED")
            local _, unopened = gateway.verify("", generation, "nonce-1", {epoch = 3, restarts = 1, proof = proof})
            test.eq((unopened).error.code, "UNAVAILABLE")
        end)
        test.it("advertises only admitted tools from the closed catalog and bounds their arguments", function()
            test.eq(#mcp.list({"thread_read"}).tools, 1)
            local advertised = principals.objects(mcp.list({"thread_read"}).tools)
            local annotations = assert(bounds.object(advertised[1].annotations))
            test.eq(annotations.readOnlyHint, true)
            test.eq(annotations.destructiveHint, false)
            test.eq(#mcp.list({"thread_read", "thread_post"}).tools, 1)
            local message_tools = principals.objects(mcp.list({"thread_message"}).tools)
            test.eq(#message_tools, 1)
            local message_annotations = assert(bounds.object(message_tools[1].annotations))
            test.eq(message_annotations.readOnlyHint, false)
            test.eq(message_annotations.idempotentHint, true)
            test.eq(#mcp.list({}).tools, 0)
            local workspace_tools = principals.objects(mcp.list({"overlay"}).tools)
            test.eq(#workspace_tools, 1)
            test.eq(workspace_tools[1].name, "overlay")
            local workspace_annotations = assert(bounds.object(workspace_tools[1].annotations))
            test.eq(workspace_annotations.readOnlyHint, false)
            test.eq(mcp.tool("overlay") and mcp.tool("overlay").operation, "bee.gov.binding:overlay_call")
            local delivery_tools = principals.objects(mcp.list({"delivery"}).tools)
            test.eq(#delivery_tools, 1)
            test.eq(delivery_tools[1].name, "delivery")
            test.eq(mcp.tool("delivery") and mcp.tool("delivery").operation, "bee.gov.binding:delivery_call")
            local delivery_schema = assert(bounds.object(delivery_tools[1].inputSchema))
            local delivery_required = principals.strings(delivery_schema.required)
            local delivery_properties = assert(bounds.object(delivery_schema.properties))
            local delivery_operation = assert(bounds.object(delivery_properties.operation))
            test.eq(#delivery_required, 3)
            for _, field in ipairs(delivery_required) do test.is_true(field ~= "workspace_id") end
            test.not_nil(delivery_properties.workspace_id)
            test.not_nil(delivery_properties.source_overlay_id)
            test.is_nil(delivery_properties.source_workspace)
            test.eq(#(principals.strings(delivery_operation.enum)), 3)
            local preflight_found = false
            for _, operation in ipairs(principals.strings(delivery_operation.enum)) do
                if operation == "preflight" then preflight_found = true end
            end
            test.is_true(preflight_found)
            local delivery_annotations = assert(bounds.object(delivery_tools[1].annotations))
            test.eq(delivery_annotations.readOnlyHint, false)
            local components_tools = principals.objects(mcp.list({"components"}).tools)
            test.eq(#components_tools, 1)
            test.eq(mcp.tool("components") and mcp.tool("components").operation, "bee.hub.binding:call")
            local components_schema = assert(bounds.object(components_tools[1].inputSchema))
            local components_operation = assert(bounds.object((assert(bounds.object(components_schema.properties))).operation))
            local read_operations = principals.strings(components_operation.enum)
            test.eq(#read_operations, 9)
            local found_installed_source = false
            for _, operation in ipairs(read_operations) do
                if operation == "installed_source" then found_installed_source = true end
            end
            test.is_true(found_installed_source)
            for _, operation in ipairs({"catalog", "details", "inspect", "state", "files", "read_file", "installed", "installed_source", "plan"}) do
                local found = false
                for _, admitted in ipairs(read_operations) do if admitted == operation then found = true end end
                test.is_true(found)
                local request, request_error = mcp.components_arguments({arguments = {operation = operation, request = {}}})
                test.is_nil(request_error)
                test.eq(request and request.operation, operation)
            end
            local installed_bare = mcp.components_arguments({arguments = {operation = "installed"}})
            test.is_nil(installed_bare and installed_bare.request)
            local installed_empty = mcp.components_arguments({arguments = {operation = "installed", request = {}}})
            test.is_nil(installed_empty and installed_empty.request)
            local _, installed_body = mcp.components_arguments({arguments = {operation = "installed", request = {component = "x"}}})
            test.eq(installed_body, "installed takes no request body")
            for _, operation in ipairs({"apply", "status", "install", "uninstall", "update"}) do
                local _, mutation_error = mcp.components_arguments({arguments = {operation = operation, request = {}}})
                test.eq(mutation_error, "components operation is read-only")
            end
            local _, authority_error = mcp.components_arguments({arguments = {operation = "catalog", registry = "caller-selected"}})
            test.eq(authority_error, "unknown field registry")
            local publish_tools = principals.objects(mcp.list({"publish"}).tools)
            test.eq(#publish_tools, 1)
            test.eq(mcp.tool("publish") and mcp.tool("publish").operation, "bee.gov.binding:delivery_call")
            local publish_schema = assert(bounds.object(publish_tools[1].inputSchema))
            test.eq(#(principals.strings(publish_schema.required)), 2)
            local publish_request = mcp.publish_arguments({arguments = {workspace_id = "ws", source_overlay_id = "src", version = "1.0.1"}})
            test.eq(publish_request and publish_request.operation, "publish")
            -- An omitted destination is the binding's own workspace; the
            -- bound-workspace check below still refuses any other.
            local defaulted_publish = mcp.publish_arguments({arguments = {source_overlay_id = "src", version = "1.0.1"}}, "ws")
            test.eq(defaulted_publish and defaulted_publish.workspace_id, "ws")
            local _, unbound_publish = mcp.publish_arguments({arguments = {source_overlay_id = "src", version = "1.0.1"}}, nil)
            test.not_nil(unbound_publish)
            local digest = string.rep("0", 64)
            local defaulted_delivery = mcp.delivery_arguments({arguments = {operation = "request", source_overlay_id = "src",
                version = "1.0.1", snapshot_digest = digest}}, "ws")
            test.eq(defaulted_delivery and defaulted_delivery.workspace_id, "ws")
            local named_delivery = mcp.delivery_arguments({arguments = {operation = "request", workspace_id = "other",
                source_overlay_id = "src", version = "1.0.1", snapshot_digest = digest}}, "ws")
            test.eq(named_delivery and named_delivery.workspace_id, "other")
            local _, publish_smuggle = mcp.publish_arguments({arguments = {workspace_id = "ws", source_overlay_id = "src", version = "1.0.1", operation = "request"}})
            test.eq(publish_smuggle, "unknown field operation")
            local _, publish_workspace = mcp.publish_arguments({arguments = {workspace_id = "ws", source_workspace = "src", version = "1.0.1"}})
            test.eq(publish_workspace, "unknown field source_workspace")
            -- The destination is the binding's own workspace: a request may
            -- restate it, never name another, and an unbound subject names none.
            local bound_workspace = string.rep("a", 32)
            test.is_nil(mcp.bound_workspace({workspace_id = bound_workspace}, bound_workspace))
            test.contains(tostring(mcp.bound_workspace({workspace_id = string.rep("b", 32)}, bound_workspace)), "this binding's workspace")
            test.contains(tostring(mcp.bound_workspace({}, bound_workspace)), "this binding's workspace")
            test.eq(mcp.bound_workspace({workspace_id = bound_workspace}, nil), "this binding names no workspace")
            for _, removed in ipairs({"thread_launch", "run_status", "run_wait", "run_cancel", "session_directory", "session_inbox",
                "session_ack", "session_reply", "session_inbox_send", "thread_sessions", "launch_definitions", "thread_notify", "thread_wait"}) do
                test.is_nil(mcp.tool(removed))
                test.eq(#mcp.list({removed}).tools, 0)
            end
            test.is_nil(mcp.tool("thread_post"))
            test.is_nil(mcp.tool("unknown_tool"))
            test.eq(mcp.tool("thread_read") and mcp.tool("thread_read").operation, "bee.threads.binding:read_after")
            test.eq(mcp.tool("thread_message") and mcp.tool("thread_message").operation, "bee.threads.binding:record")
            local read = mcp.read_arguments({arguments = {cursor = 5, limit = 10}})
            test.eq(read and read.cursor, 5)
            test.eq(read and read.limit, 10)
            local _, unknown = mcp.read_arguments({arguments = {cursor = 5, filter = {}}})
            test.eq(unknown, "unknown field filter")
            local _, big = mcp.read_arguments({arguments = {limit = 1000}})
            test.is_true(tostring(big):find("limit must be", 1, true) ~= nil)
            local _, non_object_read = mcp.read_arguments({arguments = "cursor=5"})
            test.eq(non_object_read, "arguments must be an object")
            local _, array_read = mcp.read_arguments({arguments = {"cursor", 5}})
            test.eq(array_read, "arguments must be an object")
            -- Attempt and context scope isolation: callers cannot supply cross-attempt
            -- identifiers or context fields in tool arguments to escape their binding.
            local _, thread_override = mcp.read_arguments({arguments = {cursor = 0, thread_id = "other-thread"}})
            test.eq(thread_override, "unknown field thread_id")
            local _, attempt_override = mcp.read_arguments({arguments = {cursor = 0, attempt_id = "other-attempt"}})
            test.eq(attempt_override, "unknown field attempt_id")
            local message = mcp.message_arguments({arguments = {idempotency_key = "key", message_id = "m1", message_kind = "notification", content = {text = "hello"}}})
            test.eq(message and message.idempotency_key, "key")
            test.eq(message and (assert(bounds.object(message.body))).message_kind, "notification")
            local _, missing_key = mcp.message_arguments({arguments = {message_id = "m1", message_kind = "notification", content = {text = "hello"}}})
            test.is_true(tostring(missing_key):find("idempotency_key", 1, true) ~= nil)
            local _, sender_override = mcp.message_arguments({arguments = {idempotency_key = "key", message_id = "m1", message_kind = "notification", content = {text = "hello"}, sender_id = "foreign"}})
            test.eq(sender_override, "unknown field sender_id")
            local _, context_override = mcp.message_arguments({arguments = {idempotency_key = "key", message_id = "m1", message_kind = "notification", content = {text = "hello"}, context = {}}})
            test.eq(context_override, "unknown field context")
            local _, kind_override = mcp.message_arguments({arguments = {idempotency_key = "key", kind = "receipt", message_id = "m1", message_kind = "notification", content = {text = "hello"}}})
            test.eq(kind_override, "unknown field kind")
            for _, field in ipairs({"recipient_ids", "session", "member_thread", "in_reply_to", "outcome"}) do
                local candidate: {[string]: unknown} = {idempotency_key = "key", message_id = "m1", message_kind = "notification", content = {text = "hello"}}
                candidate[field] = "x"
                local _, refused = mcp.message_arguments({arguments = candidate})
                test.eq(refused, "unknown field " .. field)
            end
            local _, request_kind = mcp.message_arguments({arguments = {idempotency_key = "key", message_id = "m1", message_kind = "request", content = {text = "hello"}}})
            test.eq(request_kind, "message_kind is not progress or notification")
            local note_schema = (mcp.tool("thread_message"))
            test.contains(note_schema.description, "does not schedule execution")
            local workspace = mcp.overlay_arguments({arguments = {operation = "put", overlay_id = "research-candidate",
                expected_revision = 1, idempotency_key = "finding-1", path = "findings/one.md", content = "evidence"}})
            test.eq(workspace and workspace.operation, "put")
            test.eq(workspace and workspace.overlay_id, "research-candidate")
            test.is_nil(workspace and (assert(bounds.object(workspace))).workspace_id)
            test.eq(workspace and workspace.content, "evidence")
            local binary = mcp.overlay_arguments({arguments = {operation = "put", overlay_id = "research-candidate",
                expected_revision = 1, idempotency_key = "binary-1", path = "assets/proof.bin", content_base64 = "AP8="}})
            test.eq(binary and binary.content_base64, "AP8=")
            local _, workspace_context = mcp.overlay_arguments({arguments = {operation = "list", overlay_id = "research-candidate", thread_id = "other"}})
            test.eq(workspace_context, "unknown field thread_id")
            local _, workspace_identity = mcp.overlay_arguments({arguments = {operation = "list", workspace_id = "research-candidate"}})
            test.eq(workspace_identity, "unknown field workspace_id")
            local _, workspace_invalid = mcp.overlay_arguments({arguments = {operation = "freeze", overlay_id = "research-candidate"}})
            test.eq(workspace_invalid, "expected_revision and idempotency_key are required")
            local _, oversized_text = mcp.overlay_arguments({arguments = {operation = "put", overlay_id = "research-candidate",
                expected_revision = 1, idempotency_key = "large-text", path = "large.txt",
                content = string.rep("x", mcp.MAX_WORKSPACE_TEXT_BYTES + 1)}})
            test.eq(oversized_text, "content exceeds the 65,536-byte MCP chunk bound; put the first chunk, then append with offset")
            local _, oversized_base64 = mcp.overlay_arguments({arguments = {operation = "put", overlay_id = "research-candidate",
                expected_revision = 1, idempotency_key = "large-binary", path = "large.bin",
                content_base64 = string.rep("A", mcp.MAX_WORKSPACE_BASE64_BYTES + 4)}})
            test.eq(oversized_base64, "content_base64 exceeds the MCP body bound")
            local result = mcp.tool_result("{}", true)
            test.is_true(result.isError)
            test.eq(result.content[1].text, "{}")
        end)
        test.it("advertises output schemas, structured results and a changing tool list", function()
            test.eq(mcp.initialize().capabilities.tools.listChanged, true)
            local names: {string} = {}
            for _, tool in ipairs(mcp.TOOLS) do names[#names + 1] = tool.name end
            local listed = principals.objects(mcp.list(names).tools)
            for _, tool in ipairs(listed) do
                test.not_nil(tool.outputSchema)
                local output = assert(bounds.object(tool.outputSchema))
                test.eq(output.type, "object")
                test.not_nil(mcp.OUTPUT_SCHEMAS[tostring(tool.name)])
            end
            local fault = mcp.tool_error("NOT_FOUND", "no such session", "session", false, "call session_list")
            test.eq(fault.error.code, "NOT_FOUND")
            test.eq(fault.error.field, "session")
            test.eq(fault.error.retryable, false)
            test.eq(fault.error.remedy, "call session_list")
            local structured = mcp.tool_result("{}", false, {ok = true})
            test.eq((assert(bounds.object(structured.structuredContent))).ok, true)
            local capabilities = mcp.tool("capabilities")
            if not capabilities then error("capabilities tool") end
            test.eq(capabilities.annotations.readOnlyHint, true)
            test.eq(capabilities.operation, "bee.gateway.binding:surface")
        end)
        test.it("matches typed capability results to their advertised output schemas", function()
            local capabilities = {ok = true, value = {workspace_id = "workspace-a", thread_id = "thread-a", action_id = "agent-a",
                revision = 1, digest = string.rep("a", 64), tools = {{name = "thread_read", description = "Read",
                    policies = {"bee.gateway.env:tool_read_policy_ref"}, annotations = {readOnlyHint = true}}},
                traits = {{id = "bee.traits:read", title = "Read", tools = {"thread_read"}}},
                allowed_traits = {"bee.traits:read"}, active_traits = {},
                thread_access = {thread_id = "thread-a", note = "read"},
                authoring = {guide_tool = "overlay", guide_operation = "guide", preflight_tool = "delivery",
                    preflight_operation = "preflight", note = "read first"}}}
            conforms(capabilities, mcp.OUTPUT_SCHEMAS.capabilities, "capabilities")
            local envelope = assert(bounds.object(mcp.OUTPUT_SCHEMAS.capabilities.properties))
            local value = assert(bounds.object(envelope.value))
            local capabilities_schema = assert(bounds.object(value.properties))
            local traits = assert(bounds.object(capabilities_schema.traits))
            test.eq(traits.type, "array")
            test.not_nil((assert(bounds.object((assert(bounds.object(traits.items))).properties))).id)
        end)
        test.it("refuses workspace identity in capability arguments", function()
            local empty = mcp.capabilities_arguments({arguments = {}})
            test.not_nil(empty)
            local _, capability_field = mcp.capabilities_arguments({arguments = {workspace_id = "other"}})
            test.eq(capability_field, "unknown field workspace_id")
        end)
        test.it("holds a binding valid only under its epoch, before expiry and until revoked", function()
            local binding: gateway.Binding = {binding_id = "b", subject = "s", action_id = "a", attempt_id = "t", thread_id = "th", owner_incarnation = 1, carrier_epoch = 1, credential_generation = 1,
                tools = {"thread_read"}, hooks = {}, epoch = 2, expires_at = "2999-01-01T00:00:00.000Z", revoked = false, sealed = false, workspace_name = "a"}
            local ok = gateway.valid(binding, {epoch = 2, restarts = 0})
            test.is_true(ok)
            local _, epoch = gateway.valid(binding, {epoch = 3, restarts = 0})
            test.eq(epoch, "binding belongs to an earlier listener epoch")
            local _, earlier_epoch = gateway.valid(binding, {epoch = 1, restarts = 0})
            test.eq(earlier_epoch, "binding belongs to an earlier listener epoch")
            -- Listener service restarts alone do not invalidate persistent bindings.
            local ok_restarted = gateway.valid(binding, {epoch = 2, restarts = 4})
            test.is_true(ok_restarted)
            binding.expires_at = "2000-01-01T00:00:00.000Z"
            local _, expired = gateway.valid(binding, {epoch = 2, restarts = 0})
            test.eq(expired, "binding has expired")
            binding.revoked = true
            local _, revoked = gateway.valid(binding, {epoch = 2, restarts = 0})
            test.eq(revoked, "binding is revoked")
        end)
    end)
end
return require("test").run_cases(define_tests)
