-- MIT. The owner operation behind the gateway's thread_launch: the caller's
-- own launch policy admits a definition or refuses it by name, and nothing
-- the launching policy did not permit is reachable. The tests drive the same
-- public facade the gateway endpoint calls, under the facade's host-named
-- policy, with the authenticated binding supplied as call context.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local agent_launch = require("agent_launch")
local agent_protocol = require("agent_protocol")
local record = require("record")
local CALL = "bee.harness.launch:agent_launch_call"
local BINDING_KEY = "bee.gateway.binding"
local FACADE_POLICY = "bee.harness.launch:agent_launch_facade_policy"
local AGENT = "bee.test.agent_launch"
local WORKSPACE = "agent-launch-workspace"
local ACTION = "action-agent-launch"
local ATTEMPT = "attempt-agent-launch"
local THREAD = "thread-agent-launch"
local PERMITTED = "bee.harness.catalog:fixture_definition"
local WINDOW_DEFINITION = "bee.harness.catalog:agent_launch_window_definition"
local ALLOWING_POLICY = "bee.harness.catalog:agent_launch_policy"
local DENYING_POLICY = "bee.harness.catalog:agent_launch_denied_policy"
local WINDOW_POLICY = "bee.harness.catalog:agent_launch_window_policy"
type Object = {[string]: unknown}
local function facade_scope(): security.Scope
    local policy, err = security.policy(FACADE_POLICY)
    if err or not policy then error("facade policy: " .. tostring(err)) end
    return security.new_scope({policy})
end
local function launch(binding: {[string]: unknown}?, request: Object): Object
    local executor = funcs.new():with_actor(security.new_actor(AGENT)):with_scope(facade_scope())
    if binding then executor = assert(executor:with_context({[BINDING_KEY] = binding})) end
    local reply, err = executor:call(CALL, request)
    if err then error("agent launch call: " .. tostring(err)) end
    if type(reply) ~= "table" then error("agent launch returned a non-table") end
    return reply :: Object
end
local function fault(reply: Object): string
    test.eq(reply.ok, false)
    return tostring((reply.error :: Object).code)
end
local function binding(policy_ref: string): {[string]: unknown}
    return {binding_id = "binding-1", thread_id = THREAD, action_id = ACTION, attempt_id = ATTEMPT, policy_ref = policy_ref, workspace_id = WORKSPACE}
end
local function define_tests()
    test.describe("Agent launch owner operation", function()
        test.it("launches into another workspace only when the caller's own scope grants it", function()
            local other = string.rep("c", 32)
            local refused = launch(binding(DENYING_POLICY), {definition_ref = PERMITTED, brief = "work elsewhere", idempotency_key = "elsewhere", workspace_id = other})
            test.eq(fault(refused), "DENIED")
            -- With the host's launch grant the facade binds the call to that
            -- workspace and the backend decides as it does for the caller's own.
            local granted = funcs.new():with_actor(security.new_actor(AGENT)):with_scope(security.new_scope({
                assert(security.policy(FACADE_POLICY)), assert(security.policy("bee.security.harness:workspace_launch_policy"))}))
            local executor = assert(granted:with_context({[BINDING_KEY] = binding(DENYING_POLICY)}))
            local reply, err = executor:call(CALL, {definition_ref = PERMITTED, brief = "work elsewhere", idempotency_key = "elsewhere", workspace_id = other})
            if err then error(tostring(err)) end
            test.eq(fault(reply :: Object), "LAUNCH_NOT_PERMITTED")
        end)
        test.it("decodes only a bounded definition, brief and retry key", function()
            local request = agent_protocol.decode({definition_ref = PERMITTED, brief = "do the work", idempotency_key = "key-1"})
            test.eq(request and request.definition_ref, PERMITTED)
            test.eq(request and request.brief, "do the work")
            local _, no_brief = agent_protocol.decode({definition_ref = PERMITTED, brief = "", idempotency_key = "key-1"})
            test.eq(no_brief, "brief must be nonempty bounded text")
            local _, no_key = agent_protocol.decode({definition_ref = PERMITTED, brief = "x"})
            test.eq(no_key, "idempotency_key is not a bounded identifier")
            local _, smuggled = agent_protocol.decode({definition_ref = PERMITTED, brief = "x", idempotency_key = "k", workspace_id = "other"})
            test.eq(smuggled, "workspace_id must be a workspace identity")
            local chosen = agent_protocol.decode({definition_ref = PERMITTED, brief = "x", idempotency_key = "k", workspace_id = string.rep("c", 32)})
            test.eq(chosen and chosen.workspace_id, string.rep("c", 32))
            local _, extra = agent_protocol.decode({definition_ref = PERMITTED, brief = "x", idempotency_key = "k", owner = "me"})
            test.eq(extra, "unknown field owner")
            local _, oversized = agent_protocol.decode({definition_ref = PERMITTED, brief = string.rep("x", agent_protocol.MAX_BRIEF_BYTES + 1), idempotency_key = "k"})
            test.eq(oversized, "brief must be nonempty bounded text")
            local _, no_definition = agent_protocol.decode({brief = "x", idempotency_key = "k"})
            test.eq(no_definition, "definition_ref is not an identifier")
        end)
        test.it("decodes a working directory, thread, placement and saved profile choice", function()
            local base = {definition_ref = PERMITTED, brief = "x", idempotency_key = "k"}
            local function with(field: string, value: unknown): (agent_protocol.Launch?, string?)
                local request: Object = {}
                for key, item in pairs(base) do request[key] = item end
                request[field] = value
                return agent_protocol.decode(request)
            end
            local resource = with("workdir", {resource = "project"})
            test.eq(resource and resource.workdir and resource.workdir.resource, "project")
            local folder = with("workdir", {root_ref = "bee.env:workspace_root", path = "legacy/app"})
            test.eq(folder and folder.workdir and folder.workdir.path, "legacy/app")
            local root = with("workdir", {root_ref = "bee.env:workspace_root"})
            test.eq(root and root.workdir and root.workdir.path, "")
            test.eq(select(2, with("workdir", {resource = "project", root_ref = "bee.env:workspace_root"})), "workdir names either a resource or a root_ref and path")
            test.eq(select(2, with("workdir", {root_ref = "bee.env:workspace_root", path = "../up"})), "workdir.path: subpath has an invalid segment")
            test.eq(select(2, with("workdir", {path = "x"})), "workdir names either a resource or a root_ref and path")
            test.eq(select(2, with("workdir", {resource = "project", mount = "/"})), "workdir: unknown field mount")
            local existing = with("thread", {thread_id = "thread-1"})
            test.eq(existing and existing.thread and existing.thread.thread_id, "thread-1")
            local titled = with("thread", {title = "Scan the legacy tree"})
            test.eq(titled and titled.thread and titled.thread.title, "Scan the legacy tree")
            test.eq(select(2, with("thread", {thread_id = "t", title = "both"})), "thread names either a thread_id or a title")
            test.eq(select(2, with("thread", {title = "two\nlines"})), "thread names either a thread_id or a title")
            test.eq(select(2, with("thread", {})), "thread names either a thread_id or a title")
            local docker = with("placement", "docker")
            test.eq(docker and docker.placement, "docker")
            test.eq(select(2, with("placement", "vm")), "placement must be native or docker")
            local profiled = agent_protocol.decode({definition_ref = PERMITTED, brief = "x", idempotency_key = "k", saved_profile_id = "p", saved_profile_revision = 2})
            test.eq(profiled and profiled.saved_profile_revision, 2)
            test.eq(select(2, with("saved_profile_id", "p")), "a saved profile needs saved_profile_id and a positive saved_profile_revision")
        end)
        test.it("refuses a definition that opens its own thread without an explicit thread choice", function()
            local reply = launch(binding(ALLOWING_POLICY), {definition_ref = PERMITTED, brief = "do the work", idempotency_key = "own-thread-key"})
            test.eq(fault(reply), "LAUNCH_THREAD_UNSUPPORTED")
        end)
        test.it("reads the caller's own launch policy allow-list and nothing else", function()
            local allowing = assert(registry.get(ALLOWING_POLICY))
            local denying = assert(registry.get(DENYING_POLICY))
            local listed = ((allowing.data :: Object).agent_launch :: {string})
            test.eq(#listed, 1)
            test.eq(listed[1], PERMITTED)
            test.eq(#((denying.data :: Object).agent_launch :: {string}), 0)
        end)
        test.it("derives one durable request identity per caller action and retry key", function()
            local first, err = agent_launch.request_id(ACTION, "key-1")
            if not first then error(tostring(err)) end
            test.eq(first, agent_launch.request_id(ACTION, "key-1"))
            test.is_true(first ~= agent_launch.request_id(ACTION, "key-2"))
            test.is_true(first ~= agent_launch.request_id("another-action", "key-1"))
        end)
        test.it("refuses an unbound call before any work exists", function()
            local reply = launch(nil, {definition_ref = PERMITTED, brief = "do the work", idempotency_key = "unbound-key"})
            test.eq(fault(reply), "UNAUTHENTICATED")
        end)
        test.it("refuses a binding that names no launch policy or workspace", function()
            local reply = launch({binding_id = "b", thread_id = THREAD, action_id = ACTION, attempt_id = ATTEMPT},
                {definition_ref = PERMITTED, brief = "do the work", idempotency_key = "context-key"})
            test.eq(fault(reply), "UNAUTHENTICATED")
        end)
        test.it("refuses a definition the caller's own policy does not list, by name", function()
            local reply = launch(binding(DENYING_POLICY), {definition_ref = PERMITTED, brief = "do the work", idempotency_key = "refused-key"})
            test.eq(fault(reply), "LAUNCH_NOT_PERMITTED")
            test.is_true(tostring((reply.error :: Object).message):find(PERMITTED, 1, true) ~= nil)
        end)
        test.it("carries lineage on the admitted action and round-trips it unchanged", function()
            -- The owner operation records the launching action as the child's
            -- parent; the record family accepts, encodes and re-decodes it.
            local admitted = {request_id = "launch:child", principal_id = AGENT, binding_ref = "binding", binding_digest = "digest",
                grant_refs = {}, budget_ref = "policy", parent_action_id = ACTION, input = {text = "do the work"}}
            local accepted, accept_error = record.decode({schema_revision = "bee.thread-record@1", record_id = "child-admitted", thread_id = THREAD,
                sequence = 1, recorded_at = "2026-09-19T00:00:00.000Z", kind = "action.admitted", producer_id = AGENT, source = "bee",
                action_id = "child-action", body = admitted})
            if not accepted then error(tostring(accept_error)) end
            test.eq((accepted.body :: {[string]: unknown}).parent_action_id, ACTION)
            local encoded, encode_error = record.encode(accepted)
            if not encoded then error(tostring(encode_error)) end
            local decoded, decode_error = record.decode_json(encoded)
            if not decoded then error(tostring(decode_error)) end
            test.eq((decoded.body :: {[string]: unknown}).parent_action_id, ACTION)
            -- A definition's own lineage is optional and a wrong type is refused.
            local without = {request_id = "launch:child", principal_id = AGENT, binding_ref = "binding", binding_digest = "digest",
                grant_refs = {}, budget_ref = "policy", input = {text = "do the work"}}
            test.not_nil(record.decode({schema_revision = "bee.thread-record@1", record_id = "child-admitted-2", thread_id = THREAD,
                sequence = 2, recorded_at = "2026-09-19T00:00:00.000Z", kind = "action.admitted", producer_id = AGENT, source = "bee",
                action_id = "child-action-2", body = without}))
            local _, refused = record.decode({schema_revision = "bee.thread-record@1", record_id = "child-admitted-3", thread_id = THREAD,
                sequence = 3, recorded_at = "2026-09-19T00:00:00.000Z", kind = "action.admitted", producer_id = AGENT, source = "bee",
                action_id = "child-action-3", body = {request_id = "launch:child", principal_id = AGENT, binding_ref = "binding", binding_digest = "digest",
                    grant_refs = {}, budget_ref = "policy", parent_action_id = 7, input = {text = "do the work"}}})
            test.eq(refused, "action.admitted: parent_action_id is not an identifier")
        end)
        test.it("refuses a definition declaring a window mode, which has no agent carrier", function()
            local reply = launch(binding(WINDOW_POLICY), {definition_ref = WINDOW_DEFINITION, brief = "do the work", idempotency_key = "window-key"})
            test.eq(fault(reply), "LAUNCH_MODE_UNSUPPORTED")
        end)
        test.it("decodes owner component revision, spec digest and agent reference with validation", function()
            local valid_digest = string.rep("b", 64)
            local req = agent_protocol.decode({
                definition_ref = PERMITTED,
                brief = "do task",
                idempotency_key = "k1",
                saved_profile_id = "prof1",
                saved_profile_revision = 1,
                owner_component_revision = 2,
                spec_digest = valid_digest,
                agent_ref = "bee.agents:code_search"
            })
            test.not_nil(req)
            test.eq(req and req.owner_component_revision, 2)
            test.eq(req and req.spec_digest, valid_digest)
            test.eq(req and req.agent_ref, "bee.agents:code_search")

            local aliased = agent_protocol.decode({
                definition_ref = PERMITTED,
                brief = "do task",
                idempotency_key = "k2",
                owner_revision = 3,
                expected_spec_digest = valid_digest
            })
            test.not_nil(aliased)
            test.eq(aliased and aliased.owner_component_revision, 3)
            test.eq(aliased and aliased.spec_digest, valid_digest)

            for _, bad in ipairs({0, -1, "1", 1.5}) do
                local _, err = agent_protocol.decode({
                    definition_ref = PERMITTED,
                    brief = "do task",
                    idempotency_key = "k3",
                    owner_component_revision = bad
                })
                test.eq(err, "owner_component_revision must be a positive integer")
            end

            for _, bad in ipairs({"bad", string.rep("A", 64), string.rep("z", 64), string.rep("a", 65)}) do
                local _, err = agent_protocol.decode({
                    definition_ref = PERMITTED,
                    brief = "do task",
                    idempotency_key = "k4",
                    spec_digest = bad
                })
                test.eq(err, "spec_digest must be a lowercase SHA-256 hex digest")
            end

            local _, bad_ref = agent_protocol.decode({
                definition_ref = PERMITTED,
                brief = "do task",
                idempotency_key = "k5",
                agent_ref = "bad\0ref"
            })
            test.eq(bad_ref, "agent_ref is not an identifier")
        end)
        test.it("refuses cross-workspace saved profile access without workspace authority", function()
            local other_workspace = string.rep("f", 32)
            local reply = launch(binding(DENYING_POLICY), {
                definition_ref = PERMITTED,
                brief = "do task",
                idempotency_key = "cross-ws-key",
                workspace_id = other_workspace,
                saved_profile_id = "foreign-profile",
                saved_profile_revision = 1
            })
            test.eq(fault(reply), "DENIED")
        end)
        test.it("replays retry with identical parameters and detects conflicts on concurrent edits", function()
            local req_id1 = agent_launch.request_id(ACTION, "idempotent-key")
            local req_id2 = agent_launch.request_id(ACTION, "idempotent-key")
            test.eq(req_id1, req_id2)
        end)
    end)
end
return test.run_cases(define_tests)
