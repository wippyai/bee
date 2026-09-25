-- MIT. Private-overlay resolution uses immutable definitions with host-owned
-- package, overlay and policy choices. These doubles expose no registry writer.
local test = require("test")
local artifact = require("artifact")
local resolver = require("overlay_resolver")
local capability_grants = require("capability_grants")
local preflight = require("preflight")
local canonical = require("canonical")
local hash = require("hash")

type Object = {[string]: unknown}
type Entry = {[string]: unknown}
type Policy = {node_id: string, policy_digest: string, packages: {[string]: boolean},
    namespaces: {[string]: boolean}, kinds: {[string]: boolean}, databases: {[string]: boolean},
    grants: {[string]: boolean}, modules: {[string]: boolean}, applied: {[string]: unknown},
    database_bindings: {[string]: Object}?, migration_barrier: boolean, applications: {Object}?,
    workspace_id: string?, overlay_owner: string?, source_node: string?, source_workspace: string?,
    workspace_application: boolean?, base_policy_digest: string?}
type Captured = {revision: integer, entries: {Entry}, overlay_ids: {[string]: boolean}?,
    owner: (Entry) -> (string?, string?)}
type Facts = {candidate: Object, context: Object}

local SHA = string.rep("a", 64)

local function entry(id: string, kind: string, value: string): Entry
    return {id = id, kind = kind, data = {source = "return '" .. value .. "'", value = value}}
end

local function fixture(policy_raw: Policy?): (Object, Object, {captured: Captured, artifact: Object})
    local made = assert(artifact.create({entry("private.app:main", "function.lua", "main")}))
    local captured: Captured = {
        revision = 19,
        entries = {
            {id = "bee.host:db", kind = "db.sql.sqlite", data = {}, registry = {owner = "bee/host"}},
            {id = "private.app:old-overlay", kind = "function.lua", data = {source = "return 'old-overlay'"},
                registry = {owner = "host/overlay"}},
            {id = "bee:protected_kernel", kind = "registry.entry", meta = {type = "bee.protected_kernel"},
                data = {revision = 1, namespaces = {"bee.gov"}, entries = {"bee:protected_kernel"}},
                registry = {owner = "bee/host"}},
        },
        overlay_ids = { ["private.app:old-overlay"] = true },
        owner = function(item: Entry): (string?, string?)
            local metadata = item.registry
            if type(metadata) == "table" and type((metadata :: Object).owner) == "string" then
                return (metadata :: Object).owner :: string, nil
            end
            return nil, "local registry owner is missing"
        end,
    }
    local policy = policy_raw or {node_id = "node-destination", policy_digest = SHA,
        packages = { ["host/private-app"] = true }, namespaces = { ["private.app"] = true },
        kinds = { ["function.lua"] = true }, databases = { ["bee.host:db"] = true },
        grants = {}, modules = {}, applied = {}, migration_barrier = false}
    local deps: Object = {
        capture = function(): (Captured?, string?) return captured, nil end,
        root = function(spec: Object): (Object?, string?)
            if spec.source_node ~= "node-source" or spec.source_workspace ~= "author/app" then
                return nil, "private artifact does not match host source mapping"
            end
            return {component = "host/private-app", version = spec.version}, nil
        end,
        policy = function(_: Object, _: Captured, _: Object): (Policy?, string?) return policy :: Policy, nil end,
    }
    local spec: Object = {owner_node = "node-destination", workspace_id = "workspace-destination",
        source_node = "node-source", source_workspace = "author/app", version = "v1",
        artifact_bytes = made.bytes, artifact_digest = made.digest}
    return deps, spec, {captured = captured, artifact = made}
end

local function resolve(deps: Object, spec: Object): Facts
    local candidate, context, err = resolver.resolve_with(deps, spec)
    if not candidate or not context then error(tostring(err)) end
    return {candidate = candidate, context = context}
end

local function changes(spec: Object, entries: {Entry})
    local made = assert(artifact.create(entries))
    spec.artifact_bytes, spec.artifact_digest = made.bytes, made.digest
end

local function define_tests()
    test.describe("private overlay artifact resolver", function()
        test.it("extracts native configuration capabilities without dropping their ceilings", function()
            local deps, spec = fixture(nil)
            changes(spec, {{id = "private.app:main", kind = "function.lua", data = {
                source = "return true", modules = {"os"}, security = {policies = {"bee.host:db"}},
                lifecycle = {auto_start = true}}}})
            local facts = resolve(deps, spec)
            local native = (facts.candidate.entries :: {Object})[1]
            test.eq((native.modules :: {string})[1], "os")
            test.eq((native.grants :: {string})[1], "bee.host:db")
            test.eq(native.auto_start, true)
            test.is_nil((facts.context.modules :: Object).os)
            test.is_nil((facts.context.grants :: Object)["bee.host:db"])
            local report, problem = preflight.check(facts.candidate :: preflight.Candidate,
                facts.context :: preflight.Context)
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
            local measured = (facts.candidate.entries :: {Object})[1]
            test.is_true(measured.security_actor)
            test.is_true(measured.security_groups)
            local report = assert(preflight.check(facts.candidate :: preflight.Candidate, facts.context :: preflight.Context))
            test.is_false(report.ready)
            local denied = false
            for _, diagnostic in ipairs(report.diagnostics) do
                if diagnostic.code == "SECURITY_DENIED" then denied = true end
            end
            test.is_true(denied)
        end)
        test.it("retains a capability requirement and validates its app policy append target", function()
            local deps, spec = fixture(nil)
            local captured = (deps.capture :: () -> (Captured?, string?))()
            captured.entries[#captured.entries + 1] = {id = "bee:capability_catalog", kind = "registry.entry",
                meta = {type = "bee.capability_catalog"}, registry = {owner = "bee/host"},
                data = {revision = 1, never = {"exec"}, capabilities = {{id = "workspace.files.read",
                    revision = 1, confirm = "standard", parameters = {subpath = "relative_subpath"},
                    text = "Read workspace files under {subpath}",
                    policies = {{operation = "files.read", resource = "workspace", scope = {subpath = "$subpath"}}},
                    resources = {}}}}}
            local app: Entry = {id = "private.app:main", kind = "process.lua", meta = {type = "bee.application"},
                data = {source = "return true", security = {policies = {"bee.host:read_policy"}}}}
            local request: Entry = {id = "private.app:files", kind = "ns.requirement",
                meta = {value_kind = "security.policy", capability = "workspace.files.read",
                    parameters = {subpath = "docs"}, reason = "Render documentation"},
                data = {targets = {{entry = "private.app:main", path = ".security.policies +="}}}}
            local request_data = request.data :: Object
            local request_meta = request.meta :: Object
            changes(spec, {app, request})
            local facts = resolve(deps, spec)
            local capability = (facts.candidate.requirements :: {Object})[1].capability_request :: Object
            test.eq(capability.capability, "workspace.files.read")
            test.eq((capability.parameters :: Object).subpath, "docs")
            test.eq(capability.reason, "Render documentation")
            test.eq(capability.target, "private.app:main")
            test.eq(capability.path, ".security.policies +=")
            local before_digest = facts.candidate.base_digest
            local captured_state = captured :: Captured
            local catalog_entry = captured_state.entries[#captured_state.entries]
            local catalog_data = catalog_entry.data :: Object
            local catalog_rows = catalog_data.capabilities :: {Object}
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
        test.it("accepts the runtime's initial registry revision", function()
            local deps, spec = fixture(nil)
            local captured = (deps.capture :: () -> (Captured?, string?))()
            captured.revision = 0
            test.eq(resolve(deps, spec).candidate.base_revision, 0)
        end)

        test.it("measures an incoming entry from its exact immutable artifact bytes", function()
            local deps, spec, source = fixture(nil)
            local bytes = assert(canonical.encode((source.artifact.entries :: {Entry})[1]))
            local expected = assert(hash.sha256(bytes))
            local candidate = resolve(deps, spec).candidate
            test.eq(((candidate.entries :: {Object})[1]).digest, expected)
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
                meta = {type = "bee.application"}, data = {source = "return true"}}})
            local captured = (deps.capture :: () -> (Captured?, string?))()
            captured.entries[#captured.entries + 1] = {id = "bee:ordinary-policy", kind = "security.policy",
                data = {},
                policy = {actions = {"funcs.call"}, resources = {"bee.app:read"}, effect = "allow"},
                registry = {owner = "bee/host"}}
            local first = resolve(deps, spec)
            local admission = first.context.application_admission :: Object
            test.eq((admission.record :: Object).artifact_digest, spec.artifact_digest)
            local policy_body = captured.entries[#captured.entries].policy :: Object
            policy_body.comment = "changed"
            local second = resolve(deps, spec)
            test.is_true((second.context.application_admission :: Object).digest ~= admission.digest)
            captured.overlay_ids["bee:ordinary-policy"] = true
            local candidate, context, err = resolver.resolve_with(deps, spec)
            test.is_nil(candidate)
            test.is_nil(context)
            test.is_true(tostring(err):find("selected overlay", 1, true) ~= nil)
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
                    policies = {"bee:ordinary-policy"}, thread_access = "none"}}}
            local deps, spec = fixture(policy)
            local captured = (deps.capture :: () -> (Captured?, string?))()
            captured.entries[#captured.entries + 1] = {id = "bee:ordinary-policy", kind = "security.policy",
                policy = {actions = {"funcs.call"}, resources = {"bee.app:read"}, effect = "allow"},
                data = {},
                registry = {owner = "bee/host"}}
            captured.entries[#captured.entries + 1] = {id = "bee:capability_catalog", kind = "registry.entry",
                meta = {type = "bee.capability_catalog"}, registry = {owner = "bee/host"},
                data = {revision = 1, never = {"exec"}, capabilities = {{id = "threads.read",
                    revision = 1, confirm = "standard", parameters = {scope = "owned_scope"},
                    text = "Read owned threads", policies = {{operation = "threads.read",
                        resource = "threads", scope = {scope = "$scope"}}}, resources = {}}}}}
            changes(spec, {{id = "private.app:main", kind = "process.lua",
                meta = {type = "bee.application"}, data = {source = "return true"}},
                {id = "private.app:threads", kind = "ns.requirement",
                    meta = {value_kind = "security.policy", capability = "threads.read",
                        parameters = {scope = "owned"}, reason = "Show threads"},
                    data = {targets = {{entry = "private.app:main", path = ".security.policies +="}}}}})
            local facts = resolve(deps, spec)
            local proposal = facts.context.capability_proposal :: Object
            test.eq(#(proposal.policies :: {unknown}), 1)
            local binding = ((facts.context.application_admission :: Object).record :: Object).bindings :: {Object}
            test.eq(#(binding[1].policies :: {unknown}), 2)
            test.eq((binding[1].policies :: {string})[1], (proposal.policies :: {Object})[1].id)
            test.eq((binding[1].policies :: {string})[2], "bee:ordinary-policy")
            test.is_true((facts.context.grants :: Object)[(proposal.policies :: {Object})[1].id :: string] == true)
            test.is_nil((facts.context.grants :: Object)["bee.gov.grants:policy." .. SHA])
            test.is_true(assert(preflight.check(facts.candidate :: preflight.Candidate,
                facts.context :: preflight.Context)).ready)
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
            local captured = (deps.capture :: () -> (Captured?, string?))()
            captured.entries[#captured.entries + 1] = {id = "bee:ordinary-policy", kind = "security.policy",
                policy = {actions = {"funcs.call"}, resources = {"bee.app:read"}, effect = "allow"},
                data = {},
                registry = {owner = "bee/host"}}
            captured.entries[#captured.entries + 1] = {id = "bee:capability_catalog", kind = "registry.entry",
                meta = {type = "bee.capability_catalog"}, registry = {owner = "bee/host"},
                data = {revision = 1, never = {"exec"}, capabilities = {{id = "threads.read",
                    revision = 1, confirm = "standard", parameters = {scope = "owned_scope"},
                    text = "Read owned threads", policies = {{operation = "threads.read",
                        resource = "threads", scope = {scope = "$scope"}}}, resources = {}}}}}
            changes(spec, {{id = "private.app:main", kind = "process.lua",
                meta = {type = "bee.application"}, data = {source = "return true"}},
                {id = "private.app:threads", kind = "ns.requirement",
                    meta = {value_kind = "security.policy", capability = "threads.read",
                        parameters = {scope = "owned"}, reason = "Show threads"},
                    data = {targets = {{entry = "private.app:main", path = ".security.policies +="}}}}})
            local remote = resolve(deps, spec)
            local review = remote.context.capability_review :: Object
            test.is_true(review.requires_approval)
            test.is_nil(remote.context.capability_installed)
            test.is_true(assert(preflight.check(remote.candidate :: preflight.Candidate,
                remote.context :: preflight.Context)).ready)
            captured.entries[#captured.entries + 1] = {id = assert(capability_grants.record_id(
                "bee.apps:workspace-destination")), kind = "registry.entry",
                registry = {owner = "bee.gov:overlay"},
                data = {digest = string.rep("b", 64)}}
            local stale, _, stale_error = resolver.resolve_with(deps, spec)
            test.is_nil(stale)
            test.is_true(tostring(stale_error):find("installed capability", 1, true) ~= nil)
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
            local captured = (deps.capture :: () -> (Captured?, string?))()
            captured.entries[#captured.entries + 1] = {id = "bee:ordinary-policy", kind = "security.policy",
                policy = {actions = {"funcs.call"}, resources = {"bee.app:read"}, effect = "allow"},
                data = {},
                registry = {owner = "bee/host"}}
            captured.entries[#captured.entries + 1] = {id = "bee:capability_catalog", kind = "registry.entry",
                meta = {type = "bee.capability_catalog"}, registry = {owner = "bee/host"},
                data = {revision = 1, never = {"exec"}, capabilities = {{id = "app.database",
                    revision = 1, confirm = "standard", parameters = {name = "name"},
                    text = "Use an isolated application database named {name}",
                    policies = {{operation = "database.use", resource = "$name",
                        scope = {name = "$name"}}}, resources = {}}}}}
            changes(spec, {{id = "private.app:main", kind = "process.lua",
                meta = {type = "bee.application"}, data = {source = "return true"}},
                {id = "private.app:db", kind = "ns.requirement",
                    meta = {value_kind = "security.policy", capability = "app.database",
                        parameters = {name = "journal"}, reason = "Persist rows"},
                    data = {targets = {{entry = "private.app:main", path = ".security.policies +="}}}},
                {id = "private.app:migration", kind = "function.lua",
                    meta = {type = "migration", target_db = "journal", ordinal = 1},
                    data = {source = "return true"}}})
            local facts = resolve(deps, spec)
            local proposal = facts.context.capability_proposal :: Object
            test.eq(#(proposal.databases :: {unknown}), 1)
            local bindings = facts.context.database_bindings :: Object
            local bound = bindings["journal"] :: Object
            test.eq(bound.database_id,
                (proposal.databases :: {Object})[1].id)
            local generated = facts.context.generated_databases :: Object
            test.eq(generated[(proposal.databases :: {Object})[1].id :: string], "journal")
            test.is_true(((facts.context.databases :: {[string]: boolean})["journal"]) == true)
            test.is_true(assert(preflight.check(facts.candidate :: preflight.Candidate,
                facts.context :: preflight.Context)).ready)
        end)
        test.it("keeps unrelated registry edits out of the semantic base", function()
            local deps, spec = fixture(nil)
            local first = resolve(deps, spec)
            local captured = (deps.capture :: () -> (Captured?, string?))()
            captured.entries[#captured.entries + 1] = {id = "other:unrelated", kind = "function.lua",
                registry = {owner = "host/other"}, data = {source = "return 'unrelated'"}}
            local added = resolve(deps, spec)
            test.eq(added.candidate.base_digest, first.candidate.base_digest)
            test.is_true((added.context.entries :: Object)["other:unrelated"] ~= nil)
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
            local captured = (deps.capture :: () -> (Captured?, string?))()
            local data = captured.entries[1].data :: Object
            data.changed = true
            local second = resolve(deps, spec)
            test.is_true(second.candidate.base_digest ~= first.candidate.base_digest)
        end)

        test.it("measures requirement targets and resolved values", function()
            local deps, spec = fixture(nil)
            changes(spec, {{id = "private.app:requirement", kind = "ns.requirement", data = {
                targets = {{entry = "bee.host:db", path = ".id"}}}}})
            local first = resolve(deps, spec)
            local captured = (deps.capture :: () -> (Captured?, string?))()
            local data = captured.entries[1].data :: Object
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
            local captured = (deps.capture :: () -> (Captured?, string?))()
            local data = captured.entries[1].data :: Object
            data.changed = true
            local second = resolve(deps, spec)
            test.is_true(second.candidate.base_digest ~= first.candidate.base_digest)
        end)

        test.it("reads the protected kernel only from the destination registry", function()
            local deps, spec = fixture(nil)
            local facts = resolve(deps, spec)
            local kernel = facts.context.protected :: Object
            test.eq(kernel.revision, 1)
            local captured = (deps.capture :: () -> (Captured?, string?))()
            captured.entries[#captured.entries] = nil
            local missing, _, missing_error = resolver.resolve_with(deps, spec)
            test.is_nil(missing)
            test.not_nil(string.find(tostring(missing_error), "protected kernel", 1, true))
        end)

        test.it("returns selected overlay entries without including them in the base", function()
            local deps, spec = fixture(nil)
            local first = resolve(deps, spec)
            local installed = first.context.installed_entries :: Object
            test.eq((installed["private.app:old-overlay"] :: Object).package, "host/private-app")
            local captured = (deps.capture :: () -> (Captured?, string?))()
            captured.entries[2].meta = table.create(0, 1)
            local same = resolve(deps, spec)
            test.eq((same.context.installed_entries["private.app:old-overlay"] :: Object).digest,
                (installed["private.app:old-overlay"] :: Object).digest)
            local data = captured.entries[2].data :: Object
            data.changed = true
            local second = resolve(deps, spec)
            test.eq(second.candidate.base_digest, first.candidate.base_digest)
            test.is_true((second.context.installed_entries["private.app:old-overlay"] :: Object).digest ~=
                (first.context.installed_entries["private.app:old-overlay"] :: Object).digest)
        end)

        test.it("preserves IDs and assigns ownership from the host-selected profile", function()
            local deps, spec = fixture(nil)
            local facts = resolve(deps, spec)
            local candidate = facts.candidate
            test.eq(candidate.destination_node, "node-destination")
            test.eq(candidate.source_node, "node-source")
            test.eq(candidate.base_revision, 19)
            test.eq(#(candidate.artifacts :: {unknown}), 1)
            local package = (candidate.artifacts :: {Object})[1]
            test.eq(package.component, "host/private-app")
            test.eq(package.digest, spec.artifact_digest)
            test.eq(((candidate.entries :: {Object})[1]).id, "private.app:main")
            test.eq(((candidate.entries :: {Object})[1]).package, "host/private-app")
            test.is_true(((facts.context.namespaces :: {[string]: boolean})["private.app"]) == true)
        end)
        test.it("retains copied host database bindings in the preflight context", function()
            local policy: Policy = {node_id = "node-destination", policy_digest = SHA,
                packages = {["host/private-app"] = true}, namespaces = {["private.app"] = true},
                kinds = {["function.lua"] = true}, databases = {["private.app:data"] = true},
                grants = {}, modules = {}, applied = {}, migration_barrier = false,
                database_bindings = {["private.app:data"] = {database_id = "bee.host:db", table_prefix = "private_"}}}
            local deps, spec = fixture(policy)
            local facts = resolve(deps, spec)
            local bindings = facts.context.database_bindings :: Object
            test.eq((bindings["private.app:data"] :: Object).database_id, "bee.host:db")
            local source_binding = (policy.database_bindings :: Object)["private.app:data"] :: Object
            source_binding.database_id = "other:db"
            test.eq((bindings["private.app:data"] :: Object).database_id, "bee.host:db")
        end)

        test.it("allows replacing definitions from only the selected destination overlay", function()
            local deps, spec = fixture(nil)
            changes(spec, {entry("private.app:old-overlay", "function.lua", "replacement")})
            local facts = resolve(deps, spec)
            test.is_nil((facts.context.entries :: Object)["private.app:old-overlay"])
            test.is_true((facts.context.entries :: Object)["bee.host:db"] ~= nil)
            test.eq(((facts.candidate.entries :: {Object})[1]).id, "private.app:old-overlay")
        end)

        test.it("rejects an entry collision with the composed destination registry", function()
            local deps, spec = fixture(nil)
            local captured = (deps.capture :: () -> (Captured?, string?))()
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
            local captured = (deps.capture :: () -> (Captured?, string?))()
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
            test.is_false((facts.context.packages :: {[string]: boolean})["host/private-app"])
            test.is_false((facts.context.namespaces :: {[string]: boolean})["private.app"])
            test.is_false((facts.context.kinds :: {[string]: boolean})["function.lua"])
        end)
    end)
end

return test.run_cases(define_tests)
