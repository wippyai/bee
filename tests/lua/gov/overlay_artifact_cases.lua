-- MIT. Focused overlay resolver test cases.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local artifact = require("artifact")
local resolver = require("overlay_resolver")
local capability_grants = require("capability_grants")
local preflight = require("preflight")
local canonical = require("canonical")
local hash = require("hash")

local support = require("support")
type Object = support.Object
type Entry = support.Entry
type Policy = support.Policy
type Deps = support.Deps
type Facts = support.Facts
local SHA = support.SHA
local proposal = support.proposal
local admission = support.admission
local entry = support.entry
local fixture = support.fixture
local resolve = support.resolve
local changes = support.changes
local M = {}
function M.define()
    test.it("blocks checkpoint metadata the application catalog cannot open", function()
        local deps, spec = fixture(nil)
        changes(spec, {{id = "private.app:main", kind = "process.lua",
            meta = {type = "bee.app", application = {restart_policy = "automatic"}},
            data = {source = "return true"}}})
        local facts = resolve(deps, spec)
        local measured = (principals.objects(facts.candidate.entries))[1]
        test.is_true(measured.application_checkpoint_invalid)
        local report = assert(preflight.check(facts.candidate, facts.context))
        local denied = false
        for _, diagnostic in ipairs(report.diagnostics) do
            if diagnostic.code == "APPLICATION_CHECKPOINT" then denied = true end
        end
        test.is_true(denied)
    end)
    test.it("extracts native configuration capabilities without dropping their ceilings", function()
        local deps, spec = fixture(nil)
        changes(spec, {{id = "private.app:main", kind = "function.lua", data = {
            source = "return true", modules = {"os"}, security = {policies = {"bee.host:db"}},
            lifecycle = {auto_start = true}}}})
        local facts = resolve(deps, spec)
        local native = (principals.objects(facts.candidate.entries))[1]
        test.eq((principals.strings(native.modules))[1], "os")
        test.eq((principals.strings(native.grants))[1], "bee.host:db")
        test.eq(native.auto_start, true)
        test.is_nil((assert(bounds.object(facts.context.modules))).os)
        test.is_nil((assert(bounds.object(facts.context.grants)))["bee.host:db"])
        local report, problem = preflight.check(facts.candidate,
            facts.context)
        if not report then error(tostring(problem)) end
        test.is_false(report.ready)
        local denied: {[string]: boolean} = {}
        for _, diagnostic in ipairs(report.diagnostics) do denied[diagnostic.code] = true end
        test.is_true(denied.MODULE_DENIED)
        test.is_true(denied.GRANT_DENIED)
        -- The fixture policy admits no auto start, so the self-starting
        -- entry is refused as well.
        test.is_false(facts.context.auto_start)
        test.is_true(denied.AUTO_START_DENIED)
    end)
    test.it("measures actor and groups for preflight refusal", function()
        local deps, spec = fixture(nil)
        changes(spec, {{id = "private.app:main", kind = "function.lua", data = {
            source = "return true", security = {actor = "private.app:owner", groups = {"private.app:admins"}}}}})
        local facts = resolve(deps, spec)
        local measured = (principals.objects(facts.candidate.entries))[1]
        test.is_true(measured.security_actor)
        test.is_true(measured.security_groups)
        local report = assert(preflight.check(facts.candidate, facts.context))
        test.is_false(report.ready)
        local denied = false
        for _, diagnostic in ipairs(report.diagnostics) do
            if diagnostic.code == "SECURITY_DENIED" then denied = true end
        end
        test.is_true(denied)
    end)
    test.it("retains a capability requirement and validates its app policy append target", function()
        local deps, spec = fixture(nil)
        local captured = (deps.capture)()
        captured.entries[#captured.entries + 1] = {id = "bee.capability:catalog", kind = "registry.entry",
            meta = {type = "bee.capability_catalog"}, registry = {owner = "bee/host"},
            data = {revision = 1, never = {"exec"}, capabilities = {{id = "workspace.files.read",
                revision = 1, confirm = "standard", parameters = {subpath = "relative_subpath"},
                text = "Read workspace files under {subpath}",
                policies = {{operation = "files.read", resource = "workspace", scope = {subpath = "$subpath"}}},
                resources = {}}}}}
        local app: Entry = {id = "private.app:main", kind = "process.lua", meta = {type = "bee.app"},
            data = {source = "return true", security = {policies = {"bee.host:read_policy"}}}}
        local request: Entry = {id = "private.app:files", kind = "ns.requirement",
            meta = {value_kind = "security.policy", capability = "workspace.files.read",
                parameters = {subpath = "docs"}, reason = "Render documentation"},
            data = {targets = {{entry = "private.app:main", path = ".security.policies +="}}}}
        local request_data = assert(bounds.object(request.data))
        local request_meta = assert(bounds.object(request.meta))
        changes(spec, {app, request})
        local facts = resolve(deps, spec)
        local capability = assert(bounds.object((principals.objects(facts.candidate.requirements))[1].capability_request))
        test.eq(capability.capability, "workspace.files.read")
        test.eq((assert(bounds.object(capability.parameters))).subpath, "docs")
        test.eq(capability.reason, "Render documentation")
        test.eq(capability.target, "private.app:main")
        test.eq(capability.path, ".security.policies +=")
        local before_digest = facts.candidate.base_digest
        local captured_state = assert(captured)
        local catalog_entry = captured_state.entries[#captured_state.entries]
        local catalog_data = assert(bounds.object(catalog_entry.data))
        local catalog_rows = principals.objects(catalog_data.capabilities)
        catalog_rows[1].revision = 2
        test.is_true(resolve(deps, spec).candidate.base_digest ~= before_digest)
        for _, bad_path in ipairs({".security.policies", ".security.groups +=", ".security.policies += .other"}) do
            request_data.targets = {{entry = "private.app:main", path = bad_path}}
            changes(spec, {app, request})
            local candidate = resolver.resolve_with(deps, spec)
            test.is_nil(candidate)
        end
        request_data.targets = {{entry = "private.app:main", path = ".security.policies +="}}
        request_meta.value_kind = "security.actor"
        changes(spec, {app, request})
        local wrong_kind = resolver.resolve_with(deps, spec)
        test.is_nil(wrong_kind)
        request_meta.value_kind = "security.policy"
        request_meta.parameters = {subpath = "docs/../private"}
        changes(spec, {app, request})
        local wrong_path = resolver.resolve_with(deps, spec)
        test.is_nil(wrong_path)
    end)
    test.it("accepts a Hive exposure request for the artifact's own operations", function()
        local deps, spec = fixture(nil)
        local captured = (deps.capture)()
        captured.entries[#captured.entries + 1] = {id = "bee.capability:catalog", kind = "registry.entry",
            meta = {type = "bee.capability_catalog"}, registry = {owner = "bee/host"},
            data = {revision = 7, never = {"exec"}, capabilities = {{id = "hive.expose",
                revision = 2, confirm = "explicit",
                parameters = {operations = "hive_operations", mode = "hive_mode", audiences = "hive_audiences"},
                text = "Expose Hive operations {operations} in {mode} mode to {audiences}",
                policies = {{operation = "hive.expose", resource = "$mode",
                    scope = {operations = "$operations", audiences = "$audiences"}}},
                resources = {{kind = "hive.operations", mode = "exposed"}}}}}}
        local op: Entry = {id = "private.app:telemetry", kind = "function.lua",
            meta = {hive = "open"}, data = {source = "return true"}}
        local other: Entry = {id = "private.app:extra", kind = "function.lua",
            meta = {hive = "open"}, data = {source = "return true"}}
        local request: Entry = {id = "private.app:exposure", kind = "ns.requirement",
            meta = {value_kind = "security.policy", capability = "hive.expose",
                parameters = {operations = {"private.app:telemetry"}, mode = "open", audiences = {"node-1"}},
                reason = "Expose telemetry"},
            data = {targets = {{entry = "private.app:telemetry", path = ".security.policies +="}}}}
        local request_data = assert(bounds.object(request.data))
        local request_meta = assert(bounds.object(request.meta))
        changes(spec, {op, other, request})
        local facts = resolve(deps, spec)
        local capability = assert(bounds.object((principals.objects(facts.candidate.requirements))[1].capability_request))
        test.eq(capability.capability, "hive.expose")
        test.eq(capability.target, "private.app:telemetry")
        test.eq((principals.strings((assert(bounds.object(capability.parameters))).operations))[1], "private.app:telemetry")
        test.eq((assert(bounds.object(capability.parameters))).mode, "open")
        request_data.targets = {{entry = "private.app:extra", path = ".security.policies +="}}
        changes(spec, {op, other, request})
        test.is_nil((resolver.resolve_with(deps, spec)))
        request_data.targets = {{entry = "private.app:telemetry", path = ".security.policies +="}}
        request_meta.parameters = {operations = {"private.app:telemetry"}, mode = "policy", audiences = {"node-1"}}
        changes(spec, {op, other, request})
        test.is_nil((resolver.resolve_with(deps, spec)))
        request_meta.parameters = {operations = {"bee.host:db"}, mode = "open", audiences = {"node-1"}}
        changes(spec, {op, other, request})
        test.is_nil((resolver.resolve_with(deps, spec)))
    end)
    test.it("requires every agents.launch definition to be a launch definition", function()
        local deps, spec = fixture(nil)
        local captured = (deps.capture)()
        captured.entries[#captured.entries + 1] = {id = "bee.capability:catalog", kind = "registry.entry",
            meta = {type = "bee.capability_catalog"}, registry = {owner = "bee/host"},
            data = {revision = 7, never = {"exec"}, capabilities = {{id = "agents.launch",
                revision = 1, confirm = "explicit",
                parameters = {definitions = "definitions"},
                text = "Launch managed agents from {definitions}",
                policies = {{operation = "agents.launch", resource = "managed_agents",
                    scope = {definitions = "$definitions"}}},
                resources = {}}}}}
        captured.entries[#captured.entries + 1] = {id = "bee.host:worker", kind = "registry.entry",
            meta = {type = "bee.launch_definition"}, data = {launch_id = "worker"},
            registry = {owner = "bee/host"}}
        captured.entries[#captured.entries + 1] = {id = "bee.host:private_callable", kind = "function.lua",
            data = {source = "return true"}, registry = {owner = "bee/host"}}
        local app: Entry = {id = "private.app:main", kind = "process.lua", meta = {type = "bee.app"},
            data = {source = "return true", security = {policies = {"bee.host:read_policy"}}}}
        local request: Entry = {id = "private.app:launch", kind = "ns.requirement",
            meta = {value_kind = "security.policy", capability = "agents.launch",
                parameters = {definitions = {"bee.host:worker"}},
                reason = "Launch the allow-listed worker"},
            data = {targets = {{entry = "private.app:main", path = ".security.policies +="}}}}
        local request_meta = assert(bounds.object(request.meta))
        changes(spec, {app, request})
        test.not_nil((resolver.resolve_with(deps, spec)))
        -- A callable entry named as a definition would widen the generated
        -- funcs.call grant beyond the launch facade, so it is refused.
        request_meta.parameters = {definitions = {"bee.host:private_callable"}}
        changes(spec, {app, request})
        test.is_nil((resolver.resolve_with(deps, spec)))
    end)
    test.it("requires every agent tool to be one of this artifact's own tool functions with no authority of its own", function()
        local deps, spec = fixture(nil)
        local captured = (deps.capture)()
        captured.entries[#captured.entries + 1] = {id = "bee.capability:catalog", kind = "registry.entry",
            meta = {type = "bee.capability_catalog"}, registry = {owner = "bee/host"},
            data = {revision = 5, never = {"env"}, capabilities = {{id = "agent.tools",
                revision = 1, confirm = "explicit", parameters = {tools = "own_functions"},
                text = "Let agents you enable call {tools} as this application",
                policies = {{operation = "agent.tools", resource = "application", scope = {tools = "$tools"}}},
                resources = {}}}}}
        captured.entries[#captured.entries + 1] = {id = "bee.host:helper", kind = "function.lua",
            meta = {type = "tool", llm_alias = "helper", llm_description = "Host helper",
                input_schema = '{"type":"object"}'}, data = {source = "return true"}, registry = {owner = "bee/host"}}
        local app: Entry = {id = "private.app:main", kind = "process.lua", meta = {type = "bee.app"},
            data = {source = "return true"}}
        local function tool(name: string, alias: string, data: Entry?): Entry
            return {id = "private.app:" .. name, kind = "function.lua",
                meta = {type = "tool", llm_alias = alias, llm_description = "Adds a note",
                    input_schema = '{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}'},
                data = data or {source = "return {handle = function() return {ok = true} end}", method = "handle"}}
        end
        local function request(tools: {string}): Entry
            return {id = "private.app:agents", kind = "ns.requirement",
                meta = {value_kind = "security.policy", capability = "agent.tools",
                    parameters = {tools = tools}, reason = "Let agents add notes"},
                data = {targets = {{entry = "private.app:main", path = ".security.policies +="}}}}
        end
        local function refusal(entries: {Entry}): string
            changes(spec, entries)
            local candidate, _, err = resolver.resolve_with(deps, spec)
            test.is_nil(candidate)
            return tostring(err)
        end
        changes(spec, {app, tool("add", "add_note"), request({"private.app:add"})})
        test.not_nil((resolver.resolve_with(deps, spec)))
        test.contains(refusal({app, tool("add", "add_note"), request({"bee.host:helper"})}),
            "agent tool bee.host:helper is not this artifact's own tool function")
        local plain: Entry = {id = "private.app:plain", kind = "function.lua", data = {source = "return true"}}
        test.contains(refusal({app, plain, request({"private.app:plain"})}), "is not a function tool")
        test.contains(refusal({app, tool("add", "add_note", {source = "return true", security = {policies = {"bee.host:read_policy"}}}),
            request({"private.app:add"})}), "declares its own security")
        test.contains(refusal({app, tool("add", "notes"), tool("list", "notes"), request({"private.app:add", "private.app:list"})}),
            "share the alias notes")
        local wide = tool("add", "add_note")
        local wide_meta = assert(bounds.object(wide.meta))
        wide_meta.input_schema = '{"type":"object","$ref":"#/x"}'
        test.contains(refusal({app, wide, request({"private.app:add"})}), "schema Bee does not advertise")
    end)
    test.it("accepts the runtime's initial registry revision", function()
        local deps, spec = fixture(nil)
        local captured = (deps.capture)()
        captured.revision = 0
        test.eq(resolve(deps, spec).candidate.base_revision, 0)
    end)

    test.it("measures an incoming entry from its exact immutable artifact bytes", function()
        local deps, spec, source = fixture(nil)
        local bytes = assert(canonical.encode((source.artifact.entries)[1]))
        local expected = assert(hash.sha256(bytes))
        local candidate = resolve(deps, spec).candidate
        test.eq(((principals.objects(candidate.entries))[1]).digest, expected)
    end)

    test.it("derives application admission from the pinned external policy definition", function()
        local policy: Policy = {node_id = "node-destination", policy_digest = SHA,
            packages = {["host/private-app"] = true}, namespaces = {["private.app"] = true},
            kinds = {["process.lua"] = true}, databases = {}, grants = {}, modules = {},
            applied = {}, migration_barrier = false, workspace_id = "workspace-destination",
            overlay_owner = "bee.apps:workspace-destination", source_node = "node-source",
            source_workspace = "author/app", applications = {{definition_id = "private.app:main",
                policies = {"bee:ordinary-policy"}, thread_access = "observe_post"}}}
        local deps, spec = fixture(policy)
        changes(spec, {{id = "private.app:main", kind = "process.lua",
            meta = {type = "bee.app"}, data = {source = "return true"}}})
        local captured = (deps.capture)()
        captured.entries[#captured.entries + 1] = {id = "bee:ordinary-policy", kind = "security.policy",
            data = {},
            policy = {actions = {"funcs.call"}, resources = {"bee.app:read"}, effect = "allow"},
            registry = {owner = "bee/host"}}
        local first = resolve(deps, spec)
        local first_admission = admission(first.context)
        test.eq(first_admission.record.artifact_digest, spec.artifact_digest)
        local policy_body = assert(bounds.object(captured.entries[#captured.entries].policy))
        policy_body.comment = "changed"
        local second = resolve(deps, spec)
        test.is_true(admission(second.context).digest ~= first_admission.digest)
        captured.overlay_ids["bee:ordinary-policy"] = true
        local candidate, context, err = resolver.resolve_with(deps, spec)
        test.is_nil(candidate)
        test.is_nil(context)
        test.eq(err, "cannot measure restored durable definition omitted by candidate: bee:ordinary-policy")
    end)

    test.it("projects a requested thread grant before its atomic install", function()
        local policy: Policy = {node_id = "node-destination", policy_digest = SHA,
            base_policy_digest = SHA, workspace_application = true,
            packages = {["host/private-app"] = true}, namespaces = {["private.app"] = true},
            kinds = {["process.lua"] = true, ["ns.requirement"] = true}, databases = {},
            grants = {["bee.gov.grants:policy." .. SHA] = true}, modules = {}, applied = {}, migration_barrier = false,
            workspace_id = "workspace-destination", overlay_owner = "bee.apps:workspace-destination",
            source_node = "node-source", source_workspace = "author/app",
            applications = {{definition_id = "private.app:main",
                policies = {"bee:ordinary-policy"}, thread_access = "none",
                appearance_write = true, close_grace_ms = 1000}}}
        local deps, spec = fixture(policy)
        local captured = (deps.capture)()
        captured.entries[#captured.entries + 1] = {id = "bee:ordinary-policy", kind = "security.policy",
            policy = {actions = {"funcs.call"}, resources = {"bee.app:read"}, effect = "allow"},
            data = {},
            registry = {owner = "bee/host"}}
        captured.entries[#captured.entries + 1] = {id = "bee.capability:catalog", kind = "registry.entry",
            meta = {type = "bee.capability_catalog"}, registry = {owner = "bee/host"},
            data = {revision = 1, never = {"exec"}, capabilities = {{id = "threads.read",
                revision = 1, confirm = "standard", parameters = {scope = "owned_scope"},
                text = "Read owned threads", policies = {{operation = "threads.read",
                    resource = "threads", scope = {scope = "$scope"}}}, resources = {}}}}}
        changes(spec, {{id = "private.app:main", kind = "process.lua",
            meta = {type = "bee.app"}, data = {source = "return true"}},
            {id = "private.app:threads", kind = "ns.requirement",
                meta = {value_kind = "security.policy", capability = "threads.read",
                    parameters = {scope = "owned"}, reason = "Show threads"},
                data = {targets = {{entry = "private.app:main", path = ".security.policies +="}}}}})
        local facts = resolve(deps, spec)
        local capability_proposal = proposal(facts.context)
        test.eq(#capability_proposal.policies, 1)
        local binding = admission(facts.context).record.bindings
        test.is_true(binding[1].appearance_write == true)
        test.eq(binding[1].close_grace_ms, 1000)
        test.is_true(binding[1].application_stop == false)
        test.eq(#(principals.items(binding[1].policies)), 2)
        test.eq(binding[1].policies[1], capability_proposal.policies[1].id)
        test.eq((principals.strings(binding[1].policies))[2], "bee:ordinary-policy")
        test.is_true(facts.context.grants[capability_proposal.policies[1].id] == true)
        test.is_nil((assert(bounds.object(facts.context.grants)))["bee.gov.grants:policy." .. SHA])
        test.is_true(assert(preflight.check(facts.candidate,
            facts.context)).ready)
    end)

    test.it("asks the destination person for a first Hive-received plan and reads only its own grants", function()
        local policy: Policy = {node_id = "node-destination", policy_digest = SHA,
            base_policy_digest = SHA, workspace_application = true,
            packages = {["host/private-app"] = true}, namespaces = {["private.app"] = true},
            kinds = {["process.lua"] = true, ["ns.requirement"] = true}, databases = {},
            grants = {}, modules = {}, applied = {}, migration_barrier = false,
            workspace_id = "workspace-destination", overlay_owner = "bee.apps:workspace-destination",
            source_node = "node-source", source_workspace = "author/app",
            applications = {{definition_id = "private.app:main",
                policies = {"bee:ordinary-policy"}, thread_access = "none"}}}
        local deps, spec = fixture(policy)
        local captured = (deps.capture)()
        captured.entries[#captured.entries + 1] = {id = "bee:ordinary-policy", kind = "security.policy",
            policy = {actions = {"funcs.call"}, resources = {"bee.app:read"}, effect = "allow"},
            data = {},
            registry = {owner = "bee/host"}}
        captured.entries[#captured.entries + 1] = {id = "bee.capability:catalog", kind = "registry.entry",
            meta = {type = "bee.capability_catalog"}, registry = {owner = "bee/host"},
            data = {revision = 1, never = {"exec"}, capabilities = {{id = "threads.read",
                revision = 1, confirm = "standard", parameters = {scope = "owned_scope"},
                text = "Read owned threads", policies = {{operation = "threads.read",
                    resource = "threads", scope = {scope = "$scope"}}}, resources = {}}}}}
        changes(spec, {{id = "private.app:main", kind = "process.lua",
            meta = {type = "bee.app"}, data = {source = "return true"}},
            {id = "private.app:threads", kind = "ns.requirement",
                meta = {value_kind = "security.policy", capability = "threads.read",
                    parameters = {scope = "owned"}, reason = "Show threads"},
                data = {targets = {{entry = "private.app:main", path = ".security.policies +="}}}}})
        local remote = resolve(deps, spec)
        local capability = remote.context.host_evidence.capability
        if capability.kind ~= "new" then error("new capability review is missing") end
        test.is_true(capability.review.requires_approval)
        test.is_true(assert(preflight.check(remote.candidate,
            remote.context)).ready)
        captured.entries[#captured.entries + 1] = {id = assert(capability_grants.record_id(
            "bee.apps:workspace-destination")), kind = "registry.entry",
            registry = {owner = "bee.gov:overlay"},
            data = {digest = string.rep("b", 64)}}
        local stale, _, stale_error = resolver.resolve_with(deps, spec)
        test.is_nil(stale)
        test.is_true(tostring(stale_error):find("installed capability", 1, true) ~= nil)
    end)

    test.it("roots a workspace file grant in the host-resolved workspace folder", function()
        local policy: Policy = {node_id = "node-destination", policy_digest = SHA,
            base_policy_digest = SHA, workspace_application = true,
            packages = {["host/private-app"] = true}, namespaces = {["private.app"] = true},
            kinds = {["process.lua"] = true, ["ns.requirement"] = true}, databases = {},
            grants = {}, modules = {}, applied = {}, migration_barrier = false,
            workspace_id = "workspace-destination", overlay_owner = "bee.apps:workspace-destination",
            source_node = "node-source", source_workspace = "author/app",
            applications = {{definition_id = "private.app:main", policies = {}, thread_access = "none"}}}
        local deps, spec = fixture(policy)
        local captured = (deps.capture)()
        captured.entries[#captured.entries + 1] = {id = "bee.capability:catalog", kind = "registry.entry",
            meta = {type = "bee.capability_catalog"}, registry = {owner = "bee/host"},
            data = {revision = 1, never = {"exec"}, capabilities = {{id = "workspace.files.read",
                revision = 1, confirm = "standard", parameters = {subpath = "relative_subpath"},
                text = "Read workspace files under {subpath}",
                policies = {{operation = "files.read", resource = "workspace", scope = {subpath = "$subpath"}}},
                resources = {}}}}}
        changes(spec, {{id = "private.app:main", kind = "process.lua",
            meta = {type = "bee.app"}, data = {source = "return true"}},
            {id = "private.app:files", kind = "ns.requirement",
                meta = {value_kind = "security.policy", capability = "workspace.files.read",
                    parameters = {subpath = "docs"}, reason = "Render documentation"},
                data = {targets = {{entry = "private.app:main", path = ".security.policies +="}}}}})
        local unrooted, _, unrooted_error = resolver.resolve_with(deps, spec)
        test.is_nil(unrooted)
        test.not_nil((string.find(tostring(unrooted_error), "workspace folder", 1, true)))
        deps.folder = function(): (unknown?, string?)
            return {root_ref = "bee.env:workspace_root", directory = ".", base = "project",
                subpath = "projects/alpha"}, nil
        end
        local facts = resolve(deps, spec)
        local volume = proposal(facts.context).volumes[1]
        test.eq((assert(bounds.object(volume.data))).directory, "projects/alpha/docs")
        test.is_true((assert(bounds.object(volume.data))).readonly)
    end)

    test.it("admits a native module only through the approved capability that authorizes it", function()
        local function app_policy(): Policy
            return {node_id = "node-destination", policy_digest = SHA,
                base_policy_digest = SHA, workspace_application = true,
                packages = {["host/private-app"] = true}, namespaces = {["private.app"] = true},
                kinds = {["process.lua"] = true, ["ns.requirement"] = true}, databases = {},
                grants = {}, modules = {json = true}, applied = {}, migration_barrier = false,
                workspace_id = "workspace-destination", overlay_owner = "bee.apps:workspace-destination",
                source_node = "node-source", source_workspace = "author/app",
                applications = {{definition_id = "private.app:main", policies = {}, thread_access = "none"}}}
        end
        local function prepared(policy: Policy, requested: boolean): (Deps, Object)
            local deps, spec = fixture(policy)
            local captured = (deps.capture)()
            captured.entries[#captured.entries + 1] = {id = "bee.capability:catalog", kind = "registry.entry",
                meta = {type = "bee.capability_catalog"}, registry = {owner = "bee/host"},
                data = {revision = 4, never = {"env"}, capabilities = {{id = "process.exec",
                    revision = 1, confirm = "explicit", parameters = {command = "command", directory = "relative_subpath"},
                    text = "Run {command} in workspace folder {directory}", modules = {"exec"}, tools = {"process_run"},
                    policies = {{operation = "process.exec", resource = "$command", scope = {subpath = "$directory"}}},
                    resources = {}}}}}
            deps.folder = function(): (unknown?, string?)
                return {root_ref = "bee.env:workspace_root", directory = ".", base = "project", subpath = "alpha"}, nil
            end
            local entries: {Entry} = {{id = "private.app:main", kind = "process.lua",
                meta = {type = "bee.app"}, data = {source = "return true", modules = {"exec", "json"}}}}
            if requested then
                entries[#entries + 1] = {id = "private.app:run", kind = "ns.requirement",
                    meta = {value_kind = "security.policy", capability = "process.exec",
                        parameters = {command = "make test", directory = "."}, reason = "Run the test suite"},
                    data = {targets = {{entry = "private.app:main", path = ".security.policies +="}}}}
            end
            changes(spec, entries)
            return deps, spec
        end
        local function module_denials(facts: Facts): {preflight.Diagnostic}
            local report = assert(preflight.check(facts.candidate, facts.context))
            local denied: {preflight.Diagnostic} = {}
            for _, diagnostic in ipairs(report.diagnostics) do
                if diagnostic.code == "MODULE_DENIED" then denied[#denied + 1] = diagnostic end
            end
            return denied
        end
        local host = app_policy()
        local granted = resolve(prepared(host, true))
        test.is_true(granted.context.modules.exec)
        test.is_true(granted.context.modules.json)
        test.is_nil(host.modules.exec)
        test.eq(#module_denials(granted), 0)
        local refused = resolve(prepared(app_policy(), false))
        test.is_nil(refused.context.modules.exec)
        local denied = module_denials(refused)
        test.eq(#denied, 1)
        test.eq(denied[1].message, "App tried " .. denied[1].target .. ": unadmitted runtime module exec.")
        test.is_true(denied[1].remedy:find("request capability process.exec", 1, true) ~= nil)
    end)

    test.it("binds an application database grant to its provisioned store", function()
        local policy: Policy = {node_id = "node-destination", policy_digest = SHA,
            base_policy_digest = SHA, workspace_application = true,
            packages = {["host/private-app"] = true}, namespaces = {["private.app"] = true},
            kinds = {["process.lua"] = true, ["ns.requirement"] = true, ["function.lua"] = true},
            databases = {}, grants = {}, modules = {}, applied = {}, migration_barrier = false,
            workspace_id = "workspace-destination", overlay_owner = "bee.apps:workspace-destination",
            source_node = "node-source", source_workspace = "author/app",
            applications = {{definition_id = "private.app:main",
                policies = {"bee:ordinary-policy"}, thread_access = "none"}}}
        local deps, spec = fixture(policy)
        local captured = (deps.capture)()
        captured.entries[#captured.entries + 1] = {id = "bee:ordinary-policy", kind = "security.policy",
            policy = {actions = {"funcs.call"}, resources = {"bee.app:read"}, effect = "allow"},
            data = {},
            registry = {owner = "bee/host"}}
        captured.entries[#captured.entries + 1] = {id = "bee.capability:catalog", kind = "registry.entry",
            meta = {type = "bee.capability_catalog"}, registry = {owner = "bee/host"},
            data = {revision = 1, never = {"exec"}, capabilities = {{id = "app.database",
                revision = 1, confirm = "standard", parameters = {name = "name"},
                text = "Use an isolated application database named {name}",
                policies = {{operation = "database.use", resource = "$name",
                    scope = {name = "$name"}}}, resources = {}}}}}
        changes(spec, {{id = "private.app:main", kind = "process.lua",
            meta = {type = "bee.app"}, data = {source = "return true"}},
            {id = "private.app:db", kind = "ns.requirement",
                meta = {value_kind = "security.policy", capability = "app.database",
                    parameters = {name = "journal"}, reason = "Persist rows"},
                data = {targets = {{entry = "private.app:main", path = ".security.policies +="}}}},
            {id = "private.app:migration", kind = "function.lua",
                meta = {type = "migration", target_db = "journal", ordinal = 1},
                data = {source = "return true"}}})
        local facts = resolve(deps, spec)
        local capability_proposal = proposal(facts.context)
        test.eq(#capability_proposal.databases, 1)
        local bindings = assert(bounds.object(facts.context.database_bindings))
        local bound = assert(bounds.object(bindings["journal"]))
        test.eq(bound.database_id,
            capability_proposal.databases[1].id)
        local generated = assert(bounds.object(facts.context.generated_databases))
        test.eq(generated[capability_proposal.databases[1].id], "journal")
        test.is_true(((facts.context.databases)["journal"]) == true)
        test.is_true(assert(preflight.check(facts.candidate,
            facts.context)).ready)
    end)
    test.it("keeps unrelated registry edits out of the semantic base", function()
        local deps, spec = fixture(nil)
        local first = resolve(deps, spec)
        local captured = (deps.capture)()
        captured.entries[#captured.entries + 1] = {id = "other:unrelated", kind = "function.lua",
            registry = {owner = "host/other"}, data = {source = "return 'unrelated'"}}
        local added = resolve(deps, spec)
        test.eq(added.candidate.base_digest, first.candidate.base_digest)
        test.is_true((assert(bounds.object(added.context.entries)))["other:unrelated"] ~= nil)
        captured.entries[#captured.entries].data = {source = "return 'changed'"}
        test.eq(resolve(deps, spec).candidate.base_digest, first.candidate.base_digest)
        captured.entries[#captured.entries] = nil
        test.eq(resolve(deps, spec).candidate.base_digest, first.candidate.base_digest)
    end)

    test.it("measures a referenced external definition in the semantic base", function()
        local deps, spec = fixture(nil)
        changes(spec, {{id = "private.app:main", kind = "function.lua", data = {
            source = "return true", config = "bee.host:db"}}})
        local first = resolve(deps, spec)
        local captured = (deps.capture)()
        local data = assert(bounds.object(captured.entries[1].data))
        data.changed = true
        local second = resolve(deps, spec)
        test.is_true(second.candidate.base_digest ~= first.candidate.base_digest)
    end)

    test.it("measures requirement targets and resolved values", function()
        local deps, spec = fixture(nil)
        changes(spec, {{id = "private.app:requirement", kind = "ns.requirement", data = {
            targets = {{entry = "bee.host:db", path = ".id"}}}}})
        local first = resolve(deps, spec)
        local captured = (deps.capture)()
        local data = assert(bounds.object(captured.entries[1].data))
        data.changed = true
        local second = resolve(deps, spec)
        test.is_true(second.candidate.base_digest ~= first.candidate.base_digest)
    end)

    test.it("measures the physical database selected for a migration", function()
        local policy: Policy = {node_id = "node-destination", policy_digest = SHA,
            packages = {["host/private-app"] = true}, namespaces = {["private.app"] = true},
            kinds = {["function.lua"] = true}, databases = {["private.app:data"] = true},
            grants = {}, modules = {}, applied = {}, migration_barrier = false,
            database_bindings = {["private.app:data"] = {database_id = "bee.host:db"}}}
        local deps, spec = fixture(policy)
        changes(spec, {{id = "private.app:migration", kind = "function.lua",
            meta = {type = "migration", target_db = "private.app:data", ordinal = 1},
            data = {source = "return true"}}})
        local first = resolve(deps, spec)
        local captured = (deps.capture)()
        local data = assert(bounds.object(captured.entries[1].data))
        data.changed = true
        local second = resolve(deps, spec)
        test.is_true(second.candidate.base_digest ~= first.candidate.base_digest)
    end)

    test.it("reads the protected kernel only from the destination registry", function()
        local deps, spec = fixture(nil)
        local facts = resolve(deps, spec)
        local kernel = assert(bounds.object(facts.context.protected))
        test.eq(kernel.revision, 1)
        local captured = (deps.capture)()
        captured.entries[#captured.entries] = nil
        local missing, _, missing_error = resolver.resolve_with(deps, spec)
        test.is_nil(missing)
        test.not_nil((string.find(tostring(missing_error), "protected kernel", 1, true)))
    end)

    test.it("returns selected overlay entries without including them in the base", function()
        local deps, spec = fixture(nil)
        local first = resolve(deps, spec)
        local installed = assert(bounds.object(first.context.installed_entries))
        test.eq((assert(bounds.object(installed["private.app:old-overlay"]))).package, "host/private-app")
        local captured = (deps.capture)()
        captured.entries[2].meta = table.create(0, 1)
        local same = resolve(deps, spec)
        test.eq((assert(bounds.object(same.context.installed_entries["private.app:old-overlay"]))).digest,
            (assert(bounds.object(installed["private.app:old-overlay"]))).digest)
        local data = assert(bounds.object(captured.entries[2].data))
        data.changed = true
        local second = resolve(deps, spec)
        test.eq(second.candidate.base_digest, first.candidate.base_digest)
        test.is_true((assert(bounds.object(second.context.installed_entries["private.app:old-overlay"]))).digest ~=
            (assert(bounds.object(first.context.installed_entries["private.app:old-overlay"]))).digest)
    end)

    test.it("preserves IDs and assigns ownership from the host-selected profile", function()
        local deps, spec = fixture(nil)
        local facts = resolve(deps, spec)
        local candidate = facts.candidate
        test.eq(candidate.destination_node, "node-destination")
        test.eq(candidate.source_node, "node-source")
        test.eq(candidate.base_revision, 19)
        test.eq(#(principals.items(candidate.artifacts)), 1)
        local package = (principals.objects(candidate.artifacts))[1]
        test.eq(package.component, "host/private-app")
        test.eq(package.digest, spec.artifact_digest)
        test.eq(((principals.objects(candidate.entries))[1]).id, "private.app:main")
        test.eq(((principals.objects(candidate.entries))[1]).package, "host/private-app")
        test.is_true(((facts.context.namespaces)["private.app"]) == true)
    end)
    test.it("retains copied host database bindings in the preflight context", function()
        local policy: Policy = {node_id = "node-destination", policy_digest = SHA,
            packages = {["host/private-app"] = true}, namespaces = {["private.app"] = true},
            kinds = {["function.lua"] = true}, databases = {["private.app:data"] = true},
            grants = {}, modules = {}, applied = {}, migration_barrier = false,
            database_bindings = {["private.app:data"] = {database_id = "bee.host:db", table_prefix = "private_"}}}
        local deps, spec = fixture(policy)
        local facts = resolve(deps, spec)
        local bindings = assert(bounds.object(facts.context.database_bindings))
        test.eq((assert(bounds.object(bindings["private.app:data"]))).database_id, "bee.host:db")
        local source_binding = assert(bounds.object((assert(bounds.object(policy.database_bindings)))["private.app:data"]))
        source_binding.database_id = "other:db"
        test.eq((assert(bounds.object(bindings["private.app:data"]))).database_id, "bee.host:db")
    end)

    test.it("allows replacing definitions from only the selected destination overlay", function()
        local deps, spec = fixture(nil)
        changes(spec, {entry("private.app:old-overlay", "function.lua", "replacement")})
        local facts = resolve(deps, spec)
        test.is_nil((assert(bounds.object(facts.context.entries)))["private.app:old-overlay"])
        test.is_true((assert(bounds.object(facts.context.entries)))["bee.host:db"] ~= nil)
        test.eq(((principals.objects(facts.candidate.entries))[1]).id, "private.app:old-overlay")
    end)

    test.it("admits only granted durable shadows and binds their identity and external base", function()
        local policy: Policy = {node_id = "node-destination", policy_digest = SHA,
            packages = {["host/private-app"] = true}, namespaces = {["private.app"] = true},
            kinds = {["function.lua"] = true}, databases = {}, grants = {}, modules = {},
            applied = {}, migration_barrier = false, super_edit = true}
        local deps, spec, state = fixture(policy)
        state.captured.entries[2] = entry("private.app:main", "function.lua", "original")
        state.captured.entries[2].registry = {owner = "bee/settings"}
        state.captured.entries[#state.captured.entries + 1] = entry("private.app:sibling", "function.lua", "retained")
        state.captured.entries[#state.captured.entries].registry = {owner = "bee/settings"}
        local replacement = entry("private.app:main", "function.lua", "approved")
        assert(bounds.object(replacement.data)).imports = {sibling = "private.app:sibling"}
        changes(spec, {replacement})
        local facts = resolve(deps, spec)
        local report = assert(preflight.check(facts.candidate, facts.context))
        if not report.ready then error(assert(canonical.encode(report.diagnostics))) end
        test.eq(facts.context.entries["private.app:main"].package, "bee/settings")
        test.is_true(facts.context.entries["private.app:sibling"] ~= nil)
        local baseline = facts.candidate.base_digest
        state.captured.entries[2].data = {source = "return 'changed original'"}
        test.eq(resolve(deps, spec).candidate.base_digest, baseline)
        state.captured.entries[2].registry = {owner = "bee/other"}
        test.is_true(resolve(deps, spec).candidate.base_digest ~= baseline)
        state.captured.entries[2].registry = {owner = "bee/settings"}
        state.captured.entries[2].kind = "library.lua"
        local changed_kind = resolve(deps, spec)
        test.is_true(changed_kind.candidate.base_digest ~= baseline)
        test.is_false(assert(preflight.check(changed_kind.candidate, changed_kind.context)).ready)
        state.captured.entries[2].kind = "function.lua"
        local kernel = assert(bounds.object(state.captured.entries[3].data))
        kernel.namespaces = {"bee.gov", "private.app"}
        local protected = resolve(deps, spec)
        local protected_report = assert(preflight.check(protected.candidate, protected.context))
        test.is_false(protected_report.ready)
        local guarded = false
        for _, diagnostic in ipairs(protected_report.diagnostics) do
            if diagnostic.code == "PROTECTED_KERNEL" then guarded = true end
        end
        test.is_true(guarded)
        kernel.namespaces = {"bee.gov"}
        policy.namespaces["private.app"] = false
        local denied, _, denied_error = resolver.resolve_with(deps, spec)
        test.is_nil(denied)
        test.is_true(tostring(denied_error):find("entry collides", 1, true) ~= nil)
        policy.namespaces["private.app"] = true
        policy.super_edit = false
        local ordinary = resolver.resolve_with(deps, spec)
        test.is_nil(ordinary)
    end)

    test.it("keeps a durable shadow's base stable after apply and refuses an unmeasured restoration", function()
        local policy: Policy = {node_id = "node-destination", policy_digest = SHA,
            packages = {["host/private-app"] = true}, namespaces = {["private.app"] = true},
            kinds = {["function.lua"] = true}, databases = {}, grants = {}, modules = {},
            applied = {}, migration_barrier = false, super_edit = true}
        local deps, spec, state = fixture(policy)
        local durable = entry("private.app:main", "function.lua", "durable")
        durable.registry = {owner = "bee/settings"}
        state.captured.entries[2] = durable
        local shadow = entry("private.app:main", "function.lua", "shadow")
        changes(spec, {shadow})
        local before = resolve(deps, spec)
        state.captured.entries[2] = shadow
        shadow.registry = {owner = "bee/settings"}
        assert(state.captured.overlay_ids)["private.app:main"] = true
        local applied = resolve(deps, spec)
        test.eq(applied.candidate.base_digest, before.candidate.base_digest)
        local before_report = assert(preflight.check(before.candidate, before.context))
        local applied_report = assert(preflight.check(applied.candidate, applied.context))
        test.is_true(applied_report.ready)
        test.eq(applied_report.plan_digest, before_report.plan_digest)
        test.eq(applied.context.entries["private.app:main"].package, "bee/settings")
        test.is_true(applied.context.installed_entries["private.app:main"] ~= nil)
        local next_entry = entry("private.app:next", "function.lua", "next")
        assert(bounds.object(next_entry.data)).imports = {original = "private.app:main"}
        changes(spec, {next_entry})
        local replaced, _, problem = resolver.resolve_with(deps, spec)
        test.is_nil(replaced)
        test.eq(problem, "cannot measure restored durable definition omitted by candidate: private.app:main")
    end)

    test.it("measures an applied overlay whose generated entries the runtime reports with an empty owner", function()
        local policy: Policy = {node_id = "node-destination", policy_digest = SHA,
            packages = {["host/private-app"] = true}, namespaces = {["private.app"] = true},
            kinds = {["function.lua"] = true}, databases = {}, grants = {}, modules = {},
            applied = {}, migration_barrier = false, super_edit = false}
        local deps, spec, state = fixture(policy)
        local authored = entry("private.app:main", "function.lua", "authored")
        changes(spec, {authored})
        local before = resolve(deps, spec)
        local installed = entry("private.app:main", "function.lua", "authored")
        installed.registry = {owner = "", root = false}
        local generated = entry("private.app:record", "function.lua", "generated")
        generated.registry = {owner = "", root = false}
        local entries = state.captured.entries
        entries[#entries + 1] = installed
        entries[#entries + 1] = generated
        local overlay = assert(state.captured.overlay_ids)
        overlay["private.app:main"] = true
        overlay["private.app:record"] = true
        local applied = resolve(deps, spec)
        test.eq(applied.candidate.base_digest, before.candidate.base_digest)
        test.is_true(applied.context.installed_entries["private.app:main"] ~= nil)
    end)

    test.it("rejects an entry collision with the composed destination registry", function()
        local deps, spec = fixture(nil)
        local captured = (deps.capture)()
        captured.entries[2] = {id = "private.app:old", kind = "function.lua", data = {},
            registry = {owner = "some/other-package"}}
        changes(spec, {entry("private.app:old", "function.lua", "new")})
        local candidate, context, err = resolver.resolve_with(deps, spec)
        test.is_nil(candidate)
        test.is_nil(context)
        test.is_true(tostring(err):find("entry collides", 1, true) ~= nil)
    end)

    test.it("rejects namespace collision with a definition outside the selected overlay", function()
        local deps, spec = fixture(nil)
        local captured = (deps.capture)()
        captured.entries[2] = {id = "private.app:foreign", kind = "function.lua", data = {},
            registry = {owner = "some/other-package"}}
        changes(spec, {entry("private.app:new", "function.lua", "new")})
        local candidate, context, err = resolver.resolve_with(deps, spec)
        test.is_nil(candidate)
        test.is_nil(context)
        test.is_true(tostring(err):find("namespace collides", 1, true) ~= nil)
    end)

    test.it("rejects remote registry ownership metadata instead of trusting it", function()
        local deps, spec = fixture(nil)
        local invalid, invalid_error = artifact.create({{id = "private.app:main", kind = "function.lua",
            registry = {owner = "attacker/authorized-package"}, data = {source = "return true"}}})
        test.is_nil(invalid)
        test.is_true(tostring(invalid_error):find("unknown field registry", 1, true) ~= nil)
    end)

    test.it("rejects Hub dependency directives and malformed migration definitions", function()
        local deps, spec = fixture(nil)
        changes(spec, {{id = "private.app:dependency", kind = "ns.dependency", data = {component = "attacker/pkg"}}})
        local candidate, _, err = resolver.resolve_with(deps, spec)
        test.is_nil(candidate)
        test.is_true(tostring(err):find("dependency directives", 1, true) ~= nil)
        changes(spec, {{id = "private.app:migration", kind = "registry.entry",
            meta = {type = "migration", target_db = "bee.host:db", ordinal = 1}, data = {sql = "ALTER TABLE x"}}})
        candidate, _, err = resolver.resolve_with(deps, spec)
        test.is_nil(candidate)
        test.is_true(tostring(err):find("callable definition", 1, true) ~= nil)
    end)

    test.it("retains host capability ceilings unchanged", function()
        local denied: Policy = {node_id = "node-destination", policy_digest = SHA,
            packages = {["host/private-app"] = false}, namespaces = {["private.app"] = false},
            kinds = {["function.lua"] = false}, databases = {}, grants = {}, modules = {},
            applied = {}, migration_barrier = false}
        local deps, spec = fixture(denied)
        local facts = resolve(deps, spec)
        test.is_false((facts.context.packages)["host/private-app"])
        test.is_false((facts.context.namespaces)["private.app"])
        test.is_false((facts.context.kinds)["function.lua"])
    end)
end
return M
