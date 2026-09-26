-- MIT. The MCP protocol library, pure: strict JSON-RPC decoding, a closed
-- tool catalog filtered by the binding, bounded tool arguments with the
-- transport budget, and binding validity under an epoch.
local test = require("test")
local mcp = require("mcp")
local gateway = require("gateway")
local registry = require("registry")
local json = require("json")
type Object = {[string]: unknown}

local function entry(id: string): Object
    local found, err = registry.get(id)
    if err or not found then error(id .. ": " .. tostring(err or "missing registry entry")) end
    return found :: Object
end

local function define_tests()
    test.describe("Gateway MCP protocol", function()
        test.it("lists every tool with an input schema whose properties are a JSON object", function()
            -- A client validates tools/list as a whole: one schema whose
            -- properties arrive as a list makes it drop every tool.
            local names: {string} = {}
            for _, tool in ipairs(mcp.TOOLS) do names[#names + 1] = tool.name end
            local listed = mcp.list(names).tools :: {{[string]: unknown}}
            test.eq(#listed, #names)
            for _, tool in ipairs(listed) do
                local schema = tool.inputSchema :: {[string]: unknown}
                local encoded = assert(json.encode(schema.properties))
                test.eq(tostring(tool.name) .. " " .. encoded:sub(1, 1), tostring(tool.name) .. " {")
            end
        end)
        test.it("discovers the production traits and overlay schema", function()
            for _, expected in ipairs({
                {id = "bee.gov.traits:authoring_trait", tools = {"bee.gov.binding:overlay_call"}},
                {id = "bee.gov.traits:application_delivery_trait", tools = {"bee.gov.binding:delivery_call"}},
                {id = "bee.gov.traits:application_publish_trait", tools = {"bee.gov.binding:delivery_call"}},
                {id = "bee.node.traits:metadata_trait", tools = {"bee.node.binding:describe", "bee.node.binding:update_metadata"}},
            }) do
                local trait = entry(expected.id)
                test.eq(trait.kind, "registry.entry")
                test.eq((trait.meta :: Object).type, "agent.trait")
                local data = trait.data :: Object
                test.eq(#(data.tools :: {string}), #expected.tools)
                for index, tool in ipairs(expected.tools) do test.eq((data.tools :: {string})[index], tool) end
            end
            local overlay = entry("bee.gov.binding:overlay_call")
            local metadata = overlay.meta :: Object
            local encoded = metadata.input_schema
            if type(encoded) ~= "string" then error("overlay input schema is missing") end
            local schema, schema_error = json.decode(encoded)
            if schema_error or type(schema) ~= "table" then error("decode overlay input schema: " .. tostring(schema_error)) end
            local properties = (schema :: Object).properties :: Object
            for _, name in ipairs({"operation", "overlay_id", "expected_revision", "idempotency_key"}) do
                test.not_nil(properties[name])
            end
        end)
        test.it("carries an optional workspace identity into a launch and refuses any other value", function()
            local chosen = mcp.launch_arguments({arguments = {definition_ref = "d", brief = "b", idempotency_key = "k", workspace_id = string.rep("a", 32)}})
            test.eq(chosen and chosen.workspace_id, string.rep("a", 32))
            local own = mcp.launch_arguments({arguments = {definition_ref = "d", brief = "b", idempotency_key = "k"}})
            test.is_nil(own and own.workspace_id)
            local _, malformed = mcp.launch_arguments({arguments = {definition_ref = "d", brief = "b", idempotency_key = "k", workspace_id = "Other"}})
            test.eq(malformed, "workspace_id must be a workspace identity")
        end)
        test.it("carries working directory, thread, placement and saved profile choices into a launch", function()
            local chosen = mcp.launch_arguments({arguments = {definition_ref = "d", brief = "b", idempotency_key = "k",
                workdir = {root_ref = "bee.env:workspace_root", path = "legacy/app"}, thread = {title = "Scan"}, placement = "native",
                saved_profile_id = "p", saved_profile_revision = 1}})
            if not chosen then error("launch arguments") end
            test.eq((chosen.workdir :: Object).path, "legacy/app")
            test.eq((chosen.thread :: Object).title, "Scan")
            test.eq(chosen.placement, "native")
            local _, both = mcp.launch_arguments({arguments = {definition_ref = "d", brief = "b", idempotency_key = "k", thread = {thread_id = "t", title = "x"}}})
            test.eq(both, "thread names either a thread_id or a title")
            local _, escaping = mcp.launch_arguments({arguments = {definition_ref = "d", brief = "b", idempotency_key = "k", workdir = {root_ref = "r", path = "../x"}}})
            test.eq(escaping, "workdir.path: subpath has an invalid segment")
            local _, placement = mcp.launch_arguments({arguments = {definition_ref = "d", brief = "b", idempotency_key = "k", placement = "vm"}})
            test.eq(placement, "placement must be native or docker")
            local tool = mcp.tool("thread_launch")
            if not tool then error("thread_launch tool") end
            local properties = tool.schema.properties :: Object
            for _, name in ipairs({"workspace_id", "workdir", "thread", "placement", "saved_profile_id", "saved_profile_revision"}) do test.not_nil(properties[name]) end
            test.is_true(tool.description:find("PLACEMENT_UNAVAILABLE", 1, true) ~= nil)
        end)
        test.it("decodes capability elevation requests with a bounded TTL", function()
            local tool = mcp.tool("request_capability")
            if not tool then error("request_capability tool") end
            test.eq(tool.operation, "bee.gateway.binding:request_capability")
            local properties = tool.schema.properties :: Object
            for _, name in ipairs({"capability", "parameters", "ttl_ms"}) do test.not_nil(properties[name]) end
            local chosen = mcp.capability_arguments({arguments = {capability = "app.database",
                parameters = {name = "journal"}, ttl_ms = 60000}})
            test.eq(chosen and chosen.capability, "app.database")
            test.eq(chosen and chosen.ttl_ms, 60000)
            local defaulted = mcp.capability_arguments({arguments = {capability = "threads.read"}})
            test.eq(defaulted and (defaulted.parameters :: Object) ~= nil, true)
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
        test.it("offers installation requests as write tools apart from the read-only components tool", function()
            local listed = mcp.list({"components", "install_request", "uninstall_request", "install_status"}).tools :: {Object}
            test.eq(#listed, 4)
            for _, item in ipairs(listed) do
                local annotations = item.annotations :: Object
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
        test.it("admits bounded full workspace sources while retaining body and owner protocol limits", function()
            test.eq(mcp.MAX_WORKSPACE_TEXT_BYTES, 65536)
            test.eq(mcp.MAX_WORKSPACE_BASE64_BYTES, 87384)
            -- The HTTP adapter applies this whole-request limit through http.request(max_body=...).
            -- It leaves room for JSON escaping a full 64 KiB text value while bounding its envelope.

            local workspace_tools = mcp.list({"overlay"}).tools :: {{[string]: unknown}}
            local input_schema = workspace_tools[1].inputSchema :: {[string]: unknown}
            local properties = input_schema.properties :: {[string]: unknown}
            test.not_nil(properties.overlay_id)
            test.is_nil(properties.workspace_id)
            local text_property = properties.content :: {[string]: unknown}
            local base64_property = properties.content_base64 :: {[string]: unknown}
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
            test.is_true(gateway.verify("listener-secret", generation, "nonce-1", {epoch = 3, restarts = 1, proof = proof}))
            local _, other_nonce = gateway.verify("listener-secret", generation, "nonce-2", {epoch = 3, restarts = 1, proof = proof})
            test.eq((other_nonce :: {error: {code: string}}).error.code, "DENIED")
            local _, other_restart = gateway.verify("listener-secret", generation, "nonce-1", {epoch = 3, restarts = 2, proof = proof})
            test.eq((other_restart :: {error: {code: string}}).error.code, "CONFLICT")
            local _, other_epoch = gateway.verify("listener-secret", generation, "nonce-1", {epoch = 2, restarts = 1, proof = proof})
            test.eq((other_epoch :: {error: {code: string}}).error.code, "CONFLICT")
            local _, stale_restart = gateway.verify("listener-secret", generation, "nonce-1", {epoch = 3, restarts = 0, proof = proof})
            test.eq((stale_restart :: {error: {code: string}}).error.code, "CONFLICT")
            local stale_generation = {epoch = 2, restarts = 1}
            local stale_proof = gateway.proof("listener-secret", stale_generation, "nonce-1")
            local _, stale_proof_reply = gateway.verify("listener-secret", generation, "nonce-1", {epoch = 3, restarts = 1, proof = stale_proof})
            test.eq((stale_proof_reply :: {error: {code: string}}).error.code, "DENIED")
            local forged = gateway.proof("another-secret", generation, "nonce-1")
            local _, forgery = gateway.verify("listener-secret", generation, "nonce-1", {epoch = 3, restarts = 1, proof = forged})
            test.eq((forgery :: {error: {code: string}}).error.code, "DENIED")
            local _, missing = gateway.verify("listener-secret", generation, "nonce-1", {epoch = 3, restarts = 1})
            test.eq((missing :: {error: {code: string}}).error.code, "DENIED")
            local _, unopened = gateway.verify("", generation, "nonce-1", {epoch = 3, restarts = 1, proof = proof})
            test.eq((unopened :: {error: {code: string}}).error.code, "UNAVAILABLE")
        end)
        test.it("advertises only admitted tools from the closed catalog and bounds their arguments", function()
            test.eq(#mcp.list({"thread_read"}).tools, 1)
            local advertised = mcp.list({"thread_read"}).tools :: {{[string]: unknown}}
            local annotations = advertised[1].annotations :: {[string]: unknown}
            test.eq(annotations.readOnlyHint, true)
            test.eq(annotations.destructiveHint, false)
            test.eq(#mcp.list({"thread_read", "thread_wait", "thread_post"}).tools, 2)
            local message_tools = mcp.list({"thread_message"}).tools :: {{[string]: unknown}}
            test.eq(#message_tools, 1)
            local message_annotations = message_tools[1].annotations :: {[string]: unknown}
            test.eq(message_annotations.readOnlyHint, false)
            test.eq(message_annotations.idempotentHint, true)
            test.eq(#mcp.list({}).tools, 0)
            local workspace_tools = mcp.list({"overlay"}).tools :: {{[string]: unknown}}
            test.eq(#workspace_tools, 1)
            test.eq(workspace_tools[1].name, "overlay")
            local workspace_annotations = workspace_tools[1].annotations :: {[string]: unknown}
            test.eq(workspace_annotations.readOnlyHint, false)
            test.eq(mcp.tool("overlay") and mcp.tool("overlay").operation, "bee.gov.binding:overlay_call")
            local delivery_tools = mcp.list({"delivery"}).tools :: {{[string]: unknown}}
            test.eq(#delivery_tools, 1)
            test.eq(delivery_tools[1].name, "delivery")
            test.eq(mcp.tool("delivery") and mcp.tool("delivery").operation, "bee.gov.binding:delivery_call")
            local delivery_schema = delivery_tools[1].inputSchema :: {[string]: unknown}
            local delivery_required = delivery_schema.required :: {string}
            local delivery_properties = delivery_schema.properties :: {[string]: unknown}
            local delivery_operation = delivery_properties.operation :: {[string]: unknown}
            test.eq(#delivery_required, 3)
            for _, field in ipairs(delivery_required) do test.is_true(field ~= "workspace_id") end
            test.not_nil(delivery_properties.workspace_id)
            test.not_nil(delivery_properties.source_overlay_id)
            test.is_nil(delivery_properties.source_workspace)
            test.eq(#(delivery_operation.enum :: {string}), 3)
            local preflight_found = false
            for _, operation in ipairs(delivery_operation.enum :: {string}) do
                if operation == "preflight" then preflight_found = true end
            end
            test.is_true(preflight_found)
            local delivery_annotations = delivery_tools[1].annotations :: {[string]: unknown}
            test.eq(delivery_annotations.readOnlyHint, false)
            local components_tools = mcp.list({"components"}).tools :: {{[string]: unknown}}
            test.eq(#components_tools, 1)
            test.eq(mcp.tool("components") and mcp.tool("components").operation, "bee.hub.binding:call")
            local components_schema = components_tools[1].inputSchema :: {[string]: unknown}
            local components_operation = (components_schema.properties :: {[string]: unknown}).operation :: {[string]: unknown}
            local read_operations = components_operation.enum :: {string}
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
            local publish_tools = mcp.list({"publish"}).tools :: {{[string]: unknown}}
            test.eq(#publish_tools, 1)
            test.eq(mcp.tool("publish") and mcp.tool("publish").operation, "bee.gov.binding:delivery_call")
            local publish_schema = publish_tools[1].inputSchema :: {[string]: unknown}
            test.eq(#(publish_schema.required :: {string}), 2)
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
            local wait_only = mcp.list({"thread_wait"}).tools :: {{[string]: unknown}}
            test.eq(#wait_only, 1)
            test.eq(wait_only[1].name, "thread_wait")
            test.is_nil(mcp.tool("thread_post"))
            test.is_nil(mcp.tool("unknown_tool"))
            test.eq(mcp.tool("thread_read") and mcp.tool("thread_read").operation, "bee.threads.service:read_after")
            test.eq(mcp.tool("thread_message") and mcp.tool("thread_message").operation, "bee.threads.service:record")
            local read = mcp.read_arguments({arguments = {cursor = 5, limit = 10}})
            test.eq(read and read.cursor, 5)
            test.eq(read and read.limit, 10)
            local _, unknown = mcp.read_arguments({arguments = {cursor = 5, filter = {}}})
            test.eq(unknown, "unknown field filter")
            local _, big = mcp.read_arguments({arguments = {limit = 1000}})
            test.is_true(tostring(big):find("limit must be", 1, true) ~= nil)
            local _, non_object_read = mcp.read_arguments({arguments = "cursor=5"})
            test.eq(non_object_read, "arguments must be an object")
            local _, non_object_wait = mcp.wait_arguments({arguments = 12345})
            test.eq(non_object_wait, "arguments must be an object")
            local _, array_read = mcp.read_arguments({arguments = {"cursor", 5}})
            test.eq(array_read, "arguments must be an object")
            -- Attempt and context scope isolation: callers cannot supply cross-attempt
            -- identifiers or context fields in tool arguments to escape their binding.
            local _, thread_override = mcp.read_arguments({arguments = {cursor = 0, thread_id = "other-thread"}})
            test.eq(thread_override, "unknown field thread_id")
            local _, attempt_override = mcp.read_arguments({arguments = {cursor = 0, attempt_id = "other-attempt"}})
            test.eq(attempt_override, "unknown field attempt_id")
            local _, wait_thread_override = mcp.wait_arguments({arguments = {after_sequence = 0, thread_id = "other-thread"}})
            test.eq(wait_thread_override, "unknown field thread_id")
            local _, context_override = mcp.wait_arguments({arguments = {after_sequence = 0, context = {}}})
            test.eq(context_override, "unknown field context")
            local wait = mcp.wait_arguments({arguments = {after_sequence = 3, wait_ms = 90000}})
            test.eq(wait and wait.after_sequence, 3)
            test.eq(wait and wait.wait_ms, 90000)
            test.eq(wait and wait.transport_budget_ms, mcp.TRANSPORT_BUDGET_MS)
            local defaults = mcp.wait_arguments({})
            test.eq(defaults and defaults.after_sequence, 0)
            test.eq(defaults and defaults.wait_ms, mcp.TRANSPORT_BUDGET_MS)
            local _, negative = mcp.wait_arguments({arguments = {wait_ms = -1}})
            test.eq(negative, "wait_ms must be a nonnegative integer")
            local message = mcp.message_arguments({arguments = {idempotency_key = "key", message_id = "m1", message_kind = "notification", recipient_ids = {}, content = {text = "hello"}}})
            test.eq(message and message.idempotency_key, "key")
            test.eq(message and (message.body :: {[string]: unknown}).message_kind, "notification")
            local _, missing_key = mcp.message_arguments({arguments = {message_id = "m1", message_kind = "notification", recipient_ids = {}, content = {text = "hello"}}})
            test.is_true(tostring(missing_key):find("idempotency_key", 1, true) ~= nil)
            local _, sender_override = mcp.message_arguments({arguments = {idempotency_key = "key", message_id = "m1", message_kind = "notification", recipient_ids = {}, content = {text = "hello"}, sender_id = "foreign"}})
            test.eq(sender_override, "unknown field sender_id")
            local _, context_override = mcp.message_arguments({arguments = {idempotency_key = "key", message_id = "m1", message_kind = "notification", recipient_ids = {}, content = {text = "hello"}, context = {}}})
            test.eq(context_override, "unknown field context")
            local _, kind_override = mcp.message_arguments({arguments = {idempotency_key = "key", kind = "receipt", message_id = "m1", message_kind = "notification", recipient_ids = {}, content = {text = "hello"}}})
            test.eq(kind_override, "unknown field kind")
            local workspace = mcp.overlay_arguments({arguments = {operation = "put", overlay_id = "research-candidate",
                expected_revision = 1, idempotency_key = "finding-1", path = "findings/one.md", content = "evidence"}})
            test.eq(workspace and workspace.operation, "put")
            test.eq(workspace and workspace.overlay_id, "research-candidate")
            test.is_nil(workspace and (workspace :: {[string]: unknown}).workspace_id)
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
            local listed = mcp.list(names).tools :: {{[string]: unknown}}
            for _, tool in ipairs(listed) do
                test.not_nil(tool.outputSchema)
                local output = tool.outputSchema :: {[string]: unknown}
                test.eq(output.type, "object")
            end
            local fault = mcp.tool_error("NOT_FOUND", "no such session", "session", false, "call thread_sessions")
            test.eq(fault.error.code, "NOT_FOUND")
            test.eq(fault.error.field, "session")
            test.eq(fault.error.retryable, false)
            test.eq(fault.error.remedy, "call thread_sessions")
            local structured = mcp.tool_result("{}", false, {ok = true})
            test.eq((structured.structuredContent :: {[string]: unknown}).ok, true)
            local capabilities = mcp.tool("capabilities")
            if not capabilities then error("capabilities tool") end
            test.eq(capabilities.annotations.readOnlyHint, true)
            test.eq(capabilities.operation, "bee.gateway.binding:surface")
            local definitions = mcp.tool("launch_definitions")
            if not definitions then error("launch_definitions tool") end
            test.eq(definitions.annotations.readOnlyHint, true)
            test.eq(definitions.operation, "bee.harness.launch:launch_definitions_call")
        end)
        test.it("pages session discovery with stable cursors", function()
            local first = mcp.sessions_arguments({arguments = {limit = 2}})
            test.eq(first and first.cursor, 0)
            test.eq(first and first.limit, 2)
            local next_page = mcp.sessions_arguments({arguments = {cursor = 2, limit = 2}})
            test.eq(next_page and next_page.cursor, 2)
            local _, bad_cursor = mcp.sessions_arguments({arguments = {cursor = -1}})
            test.not_nil(bad_cursor)
            local _, bad_limit = mcp.sessions_arguments({arguments = {limit = 65}})
            test.eq(bad_limit, "limit must be between 1 and 64")
            local _, unknown = mcp.sessions_arguments({arguments = {workspace_id = "other"}})
            test.eq(unknown, "unknown field workspace_id")
            local empty = mcp.capabilities_arguments({arguments = {}})
            test.not_nil(empty)
            local _, capability_field = mcp.capabilities_arguments({arguments = {workspace_id = "other"}})
            test.eq(capability_field, "unknown field workspace_id")
            local bound = string.rep("c", 32)
            local scoped = mcp.launch_definitions_arguments({arguments = {}}, bound)
            test.eq(scoped and scoped.workspace_id, bound)
            local named = mcp.launch_definitions_arguments({arguments = {workspace_id = string.rep("d", 32)}}, bound)
            test.eq(named and named.workspace_id, string.rep("d", 32))
            test.not_nil(mcp.bound_workspace(named :: {[string]: unknown}, bound))
        end)
        test.it("advertises session discovery, addressing and one-shot notices over the bound subject", function()
            local sessions = mcp.tool("thread_sessions")
            if not sessions then error("thread_sessions is not in the catalog") end
            test.eq(sessions.operation, "bee.threads.service:get")
            test.eq(sessions.annotations.readOnlyHint, true)
            test.eq(sessions.policies[1], mcp.TOOL_POLICY_REFS.read)
            local notify = mcp.tool("thread_notify")
            if not notify then error("thread_notify is not in the catalog") end
            test.eq(notify.operation, "bee.threads.service:notify")
            test.eq(notify.annotations.readOnlyHint, false)
            test.eq(notify.policies[1], mcp.TOOL_POLICY_REFS.message)
            test.eq(#((notify.schema.required :: {string})), 2)
            local listed = mcp.sessions_arguments({arguments = {}})
            test.not_nil(listed)
            test.not_nil(mcp.sessions_arguments({}))
            local _, sessions_field = mcp.sessions_arguments({arguments = {workspace_id = "other"}})
            test.eq(sessions_field, "unknown field workspace_id")
            local notice = mcp.notify_arguments({arguments = {session = "action-b", idempotency_key = "wait-for-b"}})
            test.eq(notice and notice.session, "action-b")
            test.eq(notice and notice.idempotency_key, "wait-for-b")
            local _, notice_thread = mcp.notify_arguments({arguments = {session = "action-b", idempotency_key = "k", thread_id = "other"}})
            test.eq(notice_thread, "unknown field thread_id")
            local _, notice_session = mcp.notify_arguments({arguments = {idempotency_key = "k"}})
            test.eq(notice_session, "session is required and must be an identifier")
            local addressed = mcp.message_arguments({arguments = {idempotency_key = "key", message_id = "go", message_kind = "notification", session = "action-a", content = {text = "go ahead"}}})
            test.eq(addressed and addressed.session, "action-a")
            test.eq(#(((addressed :: {[string]: unknown}).body :: {[string]: unknown}).recipient_ids :: {string}), 0)
            local _, named_recipients = mcp.message_arguments({arguments = {idempotency_key = "key", message_id = "go", message_kind = "notification", session = "action-a",
                recipient_ids = {"someone"}, content = {text = "go ahead"}}})
            test.eq(named_recipients, "a message to a session names no recipient_ids; the session is the recipient")
            local _, missing_recipients = mcp.message_arguments({arguments = {idempotency_key = "key", message_id = "go", message_kind = "notification", content = {text = "go ahead"}}})
            test.is_true(tostring(missing_recipients):find("recipient_ids", 1, true) ~= nil)
            for _, field in ipairs({"recipient_action_ids", "sender_action_id"}) do
                local arguments: {[string]: unknown} = {idempotency_key = "key", message_id = "go", message_kind = "notification", session = "action-a", content = {text = "go ahead"}}
                arguments[field] = field == "sender_action_id" and "forged" or {"forged"}
                local _, refused = mcp.message_arguments({arguments = arguments})
                test.eq(refused, "unknown field " .. field)
            end
            local message_schema = (mcp.tool("thread_message") :: mcp.Tool).schema
            test.not_nil((message_schema.properties :: {[string]: unknown}).session)
        end)
        test.it("decodes exact action inbox tools without accepting caller identity or thread overrides", function()
            local directory = mcp.tool("session_directory")
            test.eq(directory and directory.operation, "bee.threads.service:inbox_describe")
            test.eq(directory and directory.policies[2], mcp.TOOL_POLICY_REFS.discover)
            local send = mcp.tool("session_send")
            test.eq(send and send.operation, "bee.threads.service:inbox_send")
            test.eq(send and send.policies[2], mcp.TOOL_POLICY_REFS.send_grant)
            local base = {address = {node_id = "node-a", action_id = "action-b"}, grant_epoch = 3,
                idempotency_key = "key", message_id = "m1", content = {text = "hello"}}
            local parsed = mcp.inbox_message_arguments({arguments = base}, false)
            test.eq(parsed and (parsed.address :: {[string]: unknown}).action_id, "action-b")
            local forged: {[string]: unknown} = {}
            for key, value in pairs(base) do forged[key] = value end
            forged.sender_action_id = "forged"
            local _, refused = mcp.inbox_message_arguments({arguments = forged}, false)
            test.eq(refused, "unknown field sender_action_id")
            local reply: {[string]: unknown} = {}
            for key, value in pairs(base) do reply[key] = value end
            reply.in_reply_to = {thread_id = "thread-b", record_id = "record-b"}
            reply.outcome = "succeeded"
            test.not_nil(mcp.inbox_message_arguments({arguments = reply}, true))
            local _, missing = mcp.inbox_message_arguments({arguments = base}, true)
            test.is_true(tostring(missing):find("reply correlation", 1, true) ~= nil)
            local ack = mcp.inbox_ack_arguments({arguments = {inbox_sequence = 8, idempotency_key = "ack-8"}})
            test.eq(ack and ack.inbox_sequence, 8)
            local _, outside = mcp.inbox_page_arguments({arguments = {after_sequence = 0, limit = 65}})
            test.eq(outside, "after_sequence and limit are outside inbox bounds")
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
