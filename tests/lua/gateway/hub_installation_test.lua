-- MIT. Hub consent and governed request routing.
local test = require("test")
local surface = require("surface")
local catalog = require("catalog")
local mcp = require("mcp")
local installer = require("installer")
local installation = require("installation")
local bounds = require("bounds")
type Object = {[string]: unknown}
local function define_tests()
    test.describe("Hub Library access", function()
        test.it("grants all admitted Hub tools through one trait and preserves the ceiling", function()
            local names = {"components", "install_request", "uninstall_request", "install_status"}
            local raw = {tools = {}, traits = {}, base_tools = {}, active_traits = {}, fixed_context = {}, dynamic_keys = {},
                access = {policy = "hub-access", traits = {"bee.hub:library"}}}
            local prepared = assert((surface.prepare(raw, mcp.TOOLS, names)))
            test.is_nil(surface.select(prepared, {"bee.hub:library"}, {}))
            local granted = assert(surface.grant(prepared, {"bee.hub:library"}))
            local selected = assert(surface.select(granted, {"bee.hub:library"}, {}))
            local offered = assert(catalog.select(granted.catalog, granted.ceiling, granted.base_tools, granted.allowed_traits, selected.active))
            test.eq(#offered, 4)
            local partial = assert((surface.prepare(raw, mcp.TOOLS, {"components", "install_status"})))
            local partial_grant = assert(surface.grant(partial, {"bee.hub:library"}))
            local partial_selection = assert(surface.select(partial_grant, {"bee.hub:library"}, {}))
            test.eq(#assert(catalog.select(partial_grant.catalog, partial_grant.ceiling, partial_grant.base_tools,
                partial_grant.allowed_traits, partial_selection.active)), 2)
            raw.traits = {{id = "hub:spoof", title = "Spoof", prompt = "Spoof", tools = {"install_status"}}}
            test.is_nil((surface.prepare(raw, mcp.TOOLS, names)))
        end)
        test.it("routes a configured application to the destination and exposes its staging fault", function()
            local approvals, stages = 0, 0
            local binding = {binding_id = "binding", subject = "agent", thread_id = "thread", action_id = "action",
                attempt_id = "attempt", workspace_id = "workspace"}
            local port = {approvals = function(_operation: string, _request: Object): installer.Reply
                approvals = approvals + 1
                return {ok = false, value = nil, error = {code = "UNEXPECTED", message = "no second approval"}}
            end, hub = function(request: Object, manage: boolean): Object
                test.is_false(manage)
                if request.operation == "installed" then return {ok = true, value = {roots = {}}} end
                local input = assert(bounds.object(request.request))
                local parameters = assert(bounds.array(input.parameters, 128))
                test.eq(assert(bounds.object(parameters[1])).value, "Team progress")
                return {ok = true, value = {route = "governed", component = "bee/progress", version = "1.0.0",
                    artifact_digest = string.rep("a", 64)}}
            end, governed = function(request: Object): installer.Reply
                if request.operation == "status" then return {ok = false, value = nil, error = {code = "NOT_FOUND", message = "absent"}} end
                stages = stages + 1
                test.eq(request.operation, "stage_hub")
                test.eq(request.workspace_id, "workspace")
                test.eq(assert(bounds.object(assert(bounds.array(request.parameters, 128))[1])).value, "Team progress")
                return {ok = false, value = nil, error = {code = "DENIED", message = "fixture refuses staging"}}
            end}
            local reply = installer.request(port, binding, "approval", "install", {component = "bee/progress", version = "1.0.0",
                parameters = {{name = "app.progress:title", value = "Team progress"}}})
            test.is_false(reply.ok)
            test.eq(assert(reply.error).code, "DENIED")
            test.eq(assert(reply.error).message, "fixture refuses staging")
            test.eq(stages, 1)
            test.eq(approvals, 0)
        end)
        test.it("pins application removal to its activation and polling reads the recorded effect", function()
            local binding = {binding_id = "binding", subject = "agent", thread_id = "thread", action_id = "action",
                attempt_id = "attempt", workspace_id = "workspace"}
            local current = {intent_id = "library-intent", observed_intent_id = "library-intent", source_node = "node",
                source_workspace = "hub:bee/progress", version = "1.0.0", artifact_digest = string.rep("a", 64),
                workspace_id = "workspace", phase = "settled", outcome = "applied"}
            local view: Object = {}
            local removals, consumes = 0, 0
            local port: installer.Port = {hub = function(_request: Object, _manage: boolean): Object
                error("application removal never calls legacy Hub apply")
            end, governed = function(request: Object): installer.Reply
                if request.operation == "activations" then return {ok = true, value = {workspace_id = "workspace", activations = {current}}} end
                if request.operation == "status" then return {ok = true, value = current} end
                test.eq(request.operation, "uninstall")
                test.eq(request.expected_intent_id, "library-intent")
                test.eq(request.receipt_key, installation.effect_key("approval"))
                removals = removals + 1
                return {ok = true, value = {removed = true}}
            end, approvals = function(operation: string, request: Object): installer.Reply
                if operation == "request" then
                    view = {requester_id = "agent", thread_id = "thread", workspace_id = "workspace", policy = "approval-policy",
                        proposal = request.proposal, proposal_digest = string.rep("b", 64), owner_incarnation = 1,
                        state = "decided", decision = "approved"}
                    test.eq(assert(bounds.object(assert(bounds.object(request.proposal)).payload)).route, "governed")
                    return {ok = true, value = {approval_id = "approval"}}
                end
                if operation == "read" then return {ok = true, value = view} end
                if operation == "consume" then
                    consumes = consumes + 1
                    view.consumed_effect, view.consumer_id = request.effect_key, "agent"
                    return {ok = true, value = {}}
                end
                test.eq(operation, "complete_installation_effect")
                view.effect_completed_at, view.effect_result = "recorded", request.result
                return {ok = true, value = {}}
            end}
            test.is_true(installer.request(port, binding, "approval-policy", "uninstall", {component = "bee/progress"}).ok)
            test.eq(assert(bounds.object(installer.status(port, binding, "approval-policy", {request_id = "approval"}).value)).status, "approved")
            test.eq(removals, 0)
            test.eq(assert(bounds.object(installer.apply_approved(port, binding, "approval-policy", {request_id = "approval"}).value)).status, "applied")
            test.eq(assert(bounds.object(installer.status(port, binding, "approval-policy", {request_id = "approval"}).value)).status, "applied")
            test.eq(assert(bounds.object(installer.apply_approved(port, binding, "approval-policy", {request_id = "approval"}).value)).status, "applied")
            test.eq(removals, 1)
            test.eq(consumes, 1)
        end)
        test.it("retains typed parameters in the approved legacy request and rejects malformed values", function()
            local decoded = assert(installation.decode("install", {component = "vendor/library", version = "1.0.0",
                parameters = {{name = "settings:count", value = 3}, {name = "settings:enabled", value = false}}}))
            test.eq(decoded.parameters[1].value, 3)
            test.eq(decoded.parameters[2].value, false)
            local context = {binding_id = "binding", thread_id = "thread", action_id = "action", attempt_id = "attempt"}
            local proposal = assert(installation.proposal({digest = string.rep("a", 64), ready = true, base_revision = 1,
                request = installation.request("install", decoded.component, decoded.version, decoded.parameters),
                modules = {}, policy_changes = {}, migrations = {}, starts = {}}, context))
            local verified = assert(installation.verify({requester_id = "agent", thread_id = "thread", workspace_id = "workspace",
                policy = "approval", proposal = proposal}, "agent", "workspace", "approval", context))
            local request = installation.apply_request(verified)
            local values = assert(bounds.array(request.parameters, 128))
            test.eq(assert(bounds.object(values[1])).value, 3)
            test.eq(assert(bounds.object(values[2])).value, false)
            test.is_nil(installation.decode("install", {component = "vendor/library", parameters = {{name = "count"}}}))
            test.is_nil(installation.decode("uninstall", {component = "vendor/library", parameters = {}}))
        end)
    end)
end
return test.run_cases(define_tests)
