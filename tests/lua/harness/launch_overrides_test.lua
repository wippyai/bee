-- MIT. Overrides launch behaviour.
local test = require("test")
local principals = require("principals")
local funcs = require("funcs")
local bounds = require("bounds")
local fixture = require("fixture")
local REQUESTER = fixture.REQUESTER
local DEFINITION = fixture.DEFINITION
local POLICY = fixture.POLICY
local ROOT = fixture.ROOT
local fresh = fixture.fresh
local workspace_id = fixture.workspace_id
local scope = fixture.scope
local call = fixture.call
local call_setup = fixture.call_setup
local call_as = fixture.call_as
local value = fixture.value
local code = fixture.code
local with_entry = fixture.with_entry
local refusal_message = fixture.refusal_message
local associations = fixture.associations
local with_overrides = fixture.with_overrides
local function define_tests()
    test.describe("Launch overrides", function()
        local workspace = fixture.prepare()
        test.it("admits for the requester, obtaining an attempt-bound grant and projection in the requester's authority", function()
            local request_id = fresh("request")
            local admitted = value(call("bee.tests.harness.launch:admit", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(admitted.requester, REQUESTER)
            test.eq(admitted.attempt_id, "attempt:" .. request_id)
            test.eq(admitted.thread_id, "thread:" .. request_id)
            local carrier_request = assert(bounds.object(admitted.request))
            test.eq(carrier_request.owner_id, REQUESTER)
            test.eq(carrier_request.workspace_id, workspace, "approval workspace was lost at launch admission")
            local resources = principals.objects(carrier_request.resources)
            test.eq(#resources, 1)
            test.eq(resources[1].root_ref, ROOT)
            local projections = principals.strings(carrier_request.projections)
            test.eq(#projections, 1)
            local listed = value(call("bee.credentials.binding:list", {workspace_id = workspace}))
            local found = false
            for _, projection in ipairs(principals.objects(listed.projections)) do
                if projection.projection_id == projections[1] then
                    found = true
                    test.eq(projection.subject, REQUESTER)
                    test.eq(projection.attempt_id, "attempt:" .. request_id)
                end
            end
            test.is_true(found)
            local replay = value(call("bee.tests.harness.launch:admit", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq((principals.strings((assert(bounds.object(replay.request))).projections))[1], projections[1])
            test.eq(code(call("bee.tests.harness.launch:admit", {request_id = fresh("request"), definition_ref = DEFINITION, workspace_id = workspace, brief = "ping", thread_id = "t"})), "FORBIDDEN")
            -- Bound to the same workspace, so the refusal is the launch policy's.
            local outsider = funcs.new():with_actor(principals.actor("bee.test.other", workspace)):with_scope(scope())
            local denied, err = outsider:call("bee.tests.harness.launch:admit", {request_id = fresh("request"), definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"})
            if err then error(tostring(err)) end
            test.eq(code(principals.reply(denied)), "FORBIDDEN")
        end)
        test.it("admits workdir, thread and placement overrides only where the definition and its policy both allow them", function()
            value(call("bee.resources.binding:associate", {workspace_id = workspace, name = "alternate", root_ref = ROOT, subpath = "", allowed_access = "write"}))
            local refused_request = fresh("override-refused")
            test.eq(code(call("bee.tests.harness.launch:admit", {request_id = refused_request, definition_ref = DEFINITION, workspace_id = workspace,
                brief = "ping", workdir = "alternate"})), "FORBIDDEN")
            test.eq(code(call("bee.tests.harness.launch:admit", {request_id = refused_request, definition_ref = DEFINITION, workspace_id = workspace,
                brief = "ping", thread_title = "Chosen title"})), "FORBIDDEN")
            test.eq(code(call("bee.threads.binding:get", {thread_id = "thread:" .. refused_request})), "NOT_FOUND")
            -- The definition alone allowing an override is not enough: the
            -- host policy must admit it as well.
            with_overrides({"brief", "workdir", "thread", "placement"}, {}, function()
                local plan = value(call("bee.tests.harness.launch:resolve", {definition_ref = DEFINITION}))
                test.eq(#(principals.strings(plan.overrides)), 1)
                test.eq((principals.strings(plan.overrides))[1], "brief")
                test.eq(plan.placement_kind, "native")
                test.eq(code(call("bee.tests.harness.launch:admit", {request_id = refused_request, definition_ref = DEFINITION, workspace_id = workspace,
                    brief = "ping", workdir = "alternate"})), "FORBIDDEN")
                test.eq(code(call("bee.tests.harness.launch:admit", {request_id = refused_request, definition_ref = DEFINITION, workspace_id = workspace,
                    brief = "ping", thread_title = "Chosen title"})), "FORBIDDEN")
            end)
            with_overrides({"brief"}, {"workdir", "thread", "placement"}, function()
                test.eq(code(call("bee.tests.harness.launch:admit", {request_id = refused_request, definition_ref = DEFINITION, workspace_id = workspace,
                    brief = "ping", workdir = "alternate"})), "FORBIDDEN")
            end)
            test.eq(code(call("bee.threads.binding:get", {thread_id = "thread:" .. refused_request})), "NOT_FOUND")
            with_overrides({"brief", "workdir", "thread"}, {"workdir", "thread"}, function()
                local plan = value(call("bee.tests.harness.launch:resolve", {definition_ref = DEFINITION}))
                test.eq(#(principals.strings(plan.overrides)), 3)
                local request_id = fresh("override-workdir")
                local admitted = value(call("bee.tests.harness.launch:admit", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace,
                    brief = "ping", workdir = "alternate", thread_title = "Chosen title"}))
                local carrier_request = assert(bounds.object(admitted.request))
                test.eq(carrier_request.working_directory, "alternate")
                local resources = principals.objects(carrier_request.resources)
                test.eq(#resources, 1)
                test.eq(resources[1].name, "alternate")
                test.eq(admitted.thread_id, "thread:" .. request_id)
                local created = value(call("bee.threads.binding:get", {thread_id = admitted.thread_id}))
                test.eq((assert(bounds.object(created.summary))).title, "Chosen title")
                -- An existing thread the requester belongs to replaces the new one.
                local chosen = fresh("override-thread")
                value(call("bee.threads.binding:create", {thread_id = chosen, idempotency_key = fresh("create"), title = "Existing"}))
                local joined = value(call("bee.tests.harness.launch:admit", {request_id = fresh("override-existing"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", thread_id = chosen}))
                test.eq(joined.thread_id, chosen)
                local foreign_owner = fresh("foreign-owner")
                local foreign_thread = fresh("foreign-thread")
                value(call_as(foreign_owner, "bee.threads.binding:create", {thread_id = foreign_thread,
                    idempotency_key = fresh("foreign-create"), title = "Foreign"}))
                test.eq(code(call("bee.tests.harness.launch:admit", {request_id = fresh("override-foreign"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", thread_id = foreign_thread})), "DENIED")
                test.eq(code(call("bee.tests.harness.launch:admit", {request_id = fresh("override-both"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", thread_id = chosen, thread_title = "Both"})), "INVALID")
            end)
        end)
        test.it("admits the exact named thread while retaining thread override and membership checks", function()
            local selected = fresh("definition-thread")
            value(call("bee.threads.binding:create", {thread_id = selected, idempotency_key = fresh("create"), title = "Named"}))
            with_entry(DEFINITION, function(changed)
                changed.thread_policy = {kind = "named", thread_ref = selected}
            end, function()
                local admitted = value(call("bee.tests.harness.launch:admit", {request_id = fresh("named-thread"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", thread_id = selected}))
                test.eq(admitted.thread_id, selected)
                test.eq(code(call("bee.tests.harness.launch:admit", {request_id = fresh("different-thread"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", thread_id = fresh("other")})), "FORBIDDEN")
                test.eq(code(call("bee.tests.harness.launch:admit", {request_id = fresh("named-title"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", thread_title = "New thread"})), "FORBIDDEN")
                test.eq(code(call_as(fresh("nonmember"), "bee.tests.harness.launch:admit", {request_id = fresh("named-nonmember"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", thread_id = selected})), "DENIED")
            end)
        end)
        test.it("refuses a placement other than the host's before any thread or grant exists", function()
            local native = value(call("bee.tests.harness.launch:admit", {request_id = fresh("placement-native"), definition_ref = DEFINITION,
                workspace_id = workspace, brief = "ping", placement = "native"}))
            test.eq((assert(bounds.object(native.plan))).placement_kind, "native")
            local request_id = fresh("placement-docker")
            test.eq(code(call("bee.tests.harness.launch:admit", {request_id = request_id, definition_ref = DEFINITION,
                workspace_id = workspace, brief = "ping", placement = "docker"})), "FORBIDDEN")
            with_overrides({"brief", "placement"}, {"placement"}, function()
                local refused = call("bee.tests.harness.launch:admit", {request_id = request_id, definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", placement = "docker"})
                test.eq(code(refused), "PLACEMENT_UNAVAILABLE")
            end)
            test.eq(code(call("bee.threads.binding:get", {thread_id = "thread:" .. request_id})), "NOT_FOUND")
            -- "vm" names no installed placement package, but decoding no
            -- longer refuses it by shape: the definition's own override
            -- allow-list is what refuses it here, same as "docker" above.
            test.eq(code(call("bee.tests.harness.launch:admit", {request_id = request_id, definition_ref = DEFINITION,
                workspace_id = workspace, brief = "ping", placement = "vm"})), "FORBIDDEN")
            test.eq(code(call("bee.tests.harness.launch:admit", {request_id = fresh("placement-malformed"), definition_ref = DEFINITION,
                workspace_id = workspace, brief = "ping", placement = "bad\0placement"})), "INVALID")
        end)
        test.it("selects an installed placement package once the host's policy names its binding", function()
            local FIXTURE_PLACEMENT = "bee.tests.harness:fixture_placement_binding"
            with_overrides({"brief", "placement"}, {"placement"}, function()
                local unselected = call("bee.tests.harness.launch:admit", {request_id = fresh("placement-fixture-unselected"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", placement = "fixture"})
                test.eq(code(unselected), "PLACEMENT_UNAVAILABLE")
                test.is_true(refusal_message(unselected):find("it places it native", 1, true) ~= nil)
                with_entry(POLICY, function(changed) changed.placement_binding = FIXTURE_PLACEMENT end, function()
                    local plan = value(call("bee.tests.harness.launch:resolve", {definition_ref = DEFINITION}))
                    test.eq(plan.placement_kind, "fixture")
                    local admitted = value(call("bee.tests.harness.launch:admit", {request_id = fresh("placement-fixture-selected"), definition_ref = DEFINITION,
                        workspace_id = workspace, brief = "ping", placement = "fixture"}))
                    test.eq((assert(bounds.object(admitted.plan))).placement_kind, "fixture")
                end)
            end)
        end)
        test.it("sets up a folder under an admitted root as the working directory only under a workdir override", function()
            local plan = value(call("bee.tests.harness.launch:resolve", {definition_ref = DEFINITION}))
            local refused = call_setup({workspace_id = workspace, definition_ref = DEFINITION,
                expected_plan_digest = plan.plan_digest, workdir = {root_ref = ROOT, path = "chosen"}})
            test.eq(refused.ok, false)
            test.eq(refused.error, "the launch does not allow a workdir override")
            with_overrides({"brief", "workdir"}, {"workdir"}, function()
                local allowed = value(call("bee.tests.harness.launch:resolve", {definition_ref = DEFINITION}))
                local reply = call_setup({workspace_id = workspace, definition_ref = DEFINITION,
                    expected_plan_digest = allowed.plan_digest, workdir = {root_ref = ROOT, path = "chosen/deeper"}})
                if reply.ok ~= true then error(tostring(reply.error)) end
                local name = tostring((assert(bounds.object(reply))).workdir)
                test.is_true(name:match("^folder%-[0-9a-f]+$") ~= nil)
                local found: {[string]: unknown}? = nil
                for _, association in ipairs(associations(workspace)) do
                    if association.name == name then found = association end
                end
                if not found then error("folder association is missing") end
                test.eq(found.root_ref, ROOT)
                test.eq(found.subpath, "chosen/deeper")
                local again = call_setup({workspace_id = workspace, definition_ref = DEFINITION,
                    expected_plan_digest = allowed.plan_digest, workdir = {root_ref = ROOT, path = "chosen/deeper"}})
                test.eq((assert(bounds.object(again))).workdir, name)
                local admitted = value(call("bee.tests.harness.launch:admit", {request_id = fresh("folder-workdir"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", workdir = name, expected_plan_digest = allowed.plan_digest}))
                test.eq((assert(bounds.object(admitted.request))).working_directory, name)
                for _, bad in ipairs({{root_ref = ROOT, path = "../escape"}, {root_ref = ROOT, path = "/abs"}, {root_ref = "bee.harness.catalog:not_a_root", path = "x"},
                    {root_ref = ROOT, path = "x", extra = true}}) do
                    local denied = call_setup({workspace_id = workspace, definition_ref = DEFINITION,
                        expected_plan_digest = allowed.plan_digest, workdir = bad})
                    test.eq(denied.ok, false)
                end
            end)
        end)
        test.it("sets up a saved profile's folder as the working directory unless the request chooses another", function()
            with_overrides({"brief", "workdir"}, {"workdir"}, function()
                local saved_id = fresh("folder-profile")
                value(call("bee.harness.binding:call", {operation = "put", workspace_id = workspace, profile_id = saved_id,
                    expected_revision = 0, idempotency_key = fresh("save"), profile = {schema_revision = "bee.agent-profile@3", name = "Profiled folder",
                        definition_ref = DEFINITION, driver_binding_ref = "bee.driver.claude.binding:binding", provider = {}, bee = {mcp = {}},
                        workdir = {root_ref = ROOT, path = "profiled"}}}))
                local plan = value(call("bee.tests.harness.launch:resolve", {definition_ref = DEFINITION, workspace_id = workspace,
                    saved_profile_id = saved_id, saved_profile_revision = 1}))
                local function subpath_of(reply: {[string]: unknown}): unknown
                    if reply.ok ~= true then error(tostring(reply.error)) end
                    local name = reply.workdir
                    for _, association in ipairs(associations(workspace)) do
                        if association.name == name then return association.subpath end
                    end
                    error("folder association " .. tostring(name) .. " is missing")
                end
                test.eq(subpath_of(call_setup({workspace_id = workspace, definition_ref = DEFINITION, expected_plan_digest = plan.plan_digest,
                    saved_profile_id = saved_id, saved_profile_revision = 1})), "profiled")
                test.eq(subpath_of(call_setup({workspace_id = workspace, definition_ref = DEFINITION, expected_plan_digest = plan.plan_digest,
                    saved_profile_id = saved_id, saved_profile_revision = 1, workdir = {root_ref = ROOT, path = "chosen"}})), "chosen")
            end)
        end)
        fixture.restore_host()
    end)
end
return test.run_cases(define_tests)
