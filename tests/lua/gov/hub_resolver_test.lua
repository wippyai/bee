-- MIT. Hub resolution tests use a host-owned registry plan double.  The
-- double is deliberately small: it exposes the same capture/root/policy
-- boundaries as the destination host without granting this test a registry
-- writer or an execution capability.
local test = require("test")
local bounds = require("bounds")
local KERNEL: {revision: integer, namespaces: {string}, super_edit: {string}, entries: {string}} =
    {revision = 1, namespaces = {"bee.gov"}, super_edit = {}, entries = {"bee.gov:protected_kernel"}}
local artifact = require("artifact")
local resolver = require("hub_resolver")
local preflight = require("preflight")

type Object = {[string]: unknown}
type Spec = {owner_node: string, source_node: string, artifact_bytes: string, artifact_digest: string,
    parameters: {unknown}?}
type Artifact = artifact.Artifact
type CandidateEntry = preflight.Entry
type Candidate = preflight.Candidate
type Context = preflight.Context
type Facts = {candidate: preflight.Candidate, context: preflight.Context}
type Captured = resolver.Captured
type Policy = resolver.Policy
type Deps = resolver.Deps

local SHA = string.rep("a", 64)

local function entry(id: string, package_name: string, value: string): Object
    return {id = id, kind = "function.lua", registry = {owner = package_name},
        data = {source = "return '" .. value .. "'", value = value}}
end

local function source_artifact(): Artifact
    -- Ownership is deliberately absent from transferred artifact entries.
    -- The destination must obtain it from the registry preview.
    local made = artifact.create({
        {id = "app:claimed", kind = "function.lua", data = {source = "return 'registry-owner'", value = "registry-owner"}},
        {id = "app:kept", kind = "function.lua", data = {source = "return 'unchanged'", value = "unchanged"}},
        {id = "app:new", kind = "function.lua", data = {source = "return 'preview-created'", value = "preview-created"}},
    })
    if not made then error("cannot create resolver artifact") end
    return made
end

local function deps_fixture(policy: Policy?): (Deps, Spec, {root: Object?, captured: Captured?})
    local supplied = source_artifact()
    local spec: Spec = {owner_node = "node-destination", source_node = "node-source",
        artifact_bytes = supplied.bytes, artifact_digest = supplied.digest}
    local observed: {root: Object?, captured: Captured?} = {}
    local current: {Object} = {
        {id = "app:root", kind = "ns.dependency", registry = {owner = "vendor/app"},
            data = {component = "vendor/app"}},
        entry("app:kept", "vendor/app", "unchanged"),
        entry("app:claimed", "vendor/app", "stale-preview-value"),
        entry("app:removed", "vendor/app", "removed-by-preview"),
        entry("host:db", "host/base", "database"),
        {id = "bee.gov:protected_kernel", kind = "registry.entry", registry = {owner = "host/base"},
            meta = {type = "bee.protected_kernel"}, data = KERNEL},
    }
    local updated_entry = entry("app:claimed", "vendor/app", "registry-owner")
    local preview_entry = entry("app:new", "vendor/app", "preview-created")
    local deleted_entry = entry("app:removed", "vendor/app", "removed-by-preview")
    local preview: resolver.RegistryPlan = {
        -- A runtime plan normally contains changes, so this intentionally
        -- omits app:kept.  The resolver must flatten the selected package's
        -- unchanged registry entries together with these changes.
        digest = SHA,
        changes = {{op = "update", entry = updated_entry},
            {op = "create", entry = preview_entry},
            {op = "delete", entry = deleted_entry}},
        resolution = {modules = {
            {name = "vendor/app", version = "1.2.0", digest = "sha256:" .. SHA},
            {name = "host/base", version = "1.0.0", digest = SHA},
        }},
    }
    local captured: Captured = {
        revision = 23, entries = current, resolution = {base = "captured"},
            preview = function(root_entry: Object): (resolver.RegistryPlan?, string?)
                observed.root = root_entry
                return preview, nil
        end,
    }
    observed.captured = captured
    local selected_policy: Policy
    if policy then
        selected_policy = policy
    else
        selected_policy = {node_id = "node-destination", policy_digest = SHA,
            packages = {["vendor/app"] = true}, namespaces = {app = true},
            kinds = {["function.lua"] = true}, databases = {["host:db"] = true},
            grants = {}, modules = {}, applied = {}, migration_barrier = true, auto_start = false}
    end
    local deps: Deps = {
        capture = function(): (resolver.Captured?, string?) return captured, nil end,
        root = function(_root_spec: unknown): (resolver.Root?, string?)
            local parameters: {unknown} = spec.parameters or {}
            return {component = "vendor/app", version = "1.2.0", parameters = parameters}, nil
        end,
        policy = function(_: unknown, _: unknown, _: unknown): (Policy?, string?) return selected_policy, nil end,
    }
    return deps, spec, observed
end

local function facts(deps: Deps, spec: Spec): Facts
    local candidate, context, err = resolver.resolve_with(deps, spec)
    if not candidate then error(tostring(err)) end
    if not context then error(tostring(err)) end
    return {candidate = candidate, context = context}
end

local function find_entry(entries: {preflight.Entry}, id: string): preflight.Entry?
    for _, item in ipairs(entries) do if item.id == id then return item end end
    return nil
end

local function define_tests()
    test.describe("Hub registry resolver", function()
        test.it("resolves an application database capability from the host catalog", function()
            local deps, spec, observed = deps_fixture(nil)
            local captured = assert(observed.captured)
            captured.entries[#captured.entries + 1] = {id = "bee.capability:catalog", kind = "registry.entry",
                registry = {owner = "host/base"}, meta = {type = "bee.capability_catalog"},
                data = {revision = 1, never = {"exec"}, capabilities = {{id = "app.database", revision = 1,
                    confirm = "standard", parameters = {name = "name"},
                    text = "Use database {name}", resources = {},
                    policies = {{operation = "database.use", resource = "$name", scope = {name = "$name"}}},
                    modules = {"sql"}}}}}
            local entries: {Object} = {
                {id = "app.progress:database", kind = "ns.requirement",
                    meta = {value_kind = "security.policy", capability = "app.database",
                        parameters = {name = "progress"}, reason = "Keep tasks"},
                    data = {targets = {{entry = "app.progress:app", path = ".security.policies +="}}}},
                {id = "app.progress:app", kind = "process.lua", meta = {type = "bee.app"}, data = {}},
            }
            local made = assert(artifact.create(entries))
            spec.artifact_bytes, spec.artifact_digest = made.bytes, made.digest
            captured.preview = function(_: Object): (resolver.RegistryPlan?, string?)
                local changes: {resolver.RegistryChange} = {}
                for _, raw in ipairs(entries) do
                    local value: Object = {}
                    for key, child in pairs(raw) do value[key] = child end
                    value.registry = {owner = "bee/progress"}
                    changes[#changes + 1] = {op = "create", entry = value}
                end
                return {digest = SHA, changes = changes,
                    resolution = {modules = {{name = "bee/progress", version = "1.0.0", digest = SHA}}}}, nil
            end
            deps.root = function(_: unknown): (resolver.Root?, string?)
                return {component = "bee/progress", version = "1.0.0", parameters = {}}, nil
            end
            local resolved = facts(deps, spec)
            local request = assert(resolved.candidate.requirements[1].capability_request)
            test.eq(request.capability, "app.database")
            test.eq(request.parameters.name, "progress")
            test.eq(request.target, "app.progress:app")
            test.eq(request.path, ".security.policies +=")
        end)

        test.it("accepts the runtime's initial registry revision", function()
            local deps, spec, observed = deps_fixture(nil)
            local captured = observed.captured
            if not captured then error("resolver did not expose its captured state") end
            captured.revision = 0
            test.eq(facts(deps, spec).candidate.base_revision, 0)
        end)

        test.it("applies native preview changes and retains unchanged selected-package entries", function()
            local deps, spec = deps_fixture(nil)
            local resolved = facts(deps, spec)
            test.eq(resolved.candidate.destination_node, spec.owner_node)
            test.eq(resolved.candidate.source_node, spec.source_node)
            test.eq(resolved.candidate.base_revision, 23)
            test.eq(#resolved.candidate.entries, 3)
            test.is_true(find_entry(resolved.candidate.entries, "app:kept") ~= nil)
            test.is_true(find_entry(resolved.candidate.entries, "app:new") ~= nil)
            test.is_nil(find_entry(resolved.candidate.entries, "app:removed"))
            test.is_true(find_entry(resolved.candidate.entries, "app:claimed") ~= nil)
            test.eq(resolved.candidate.artifacts[1].component, "vendor/app")
            test.eq(resolved.candidate.artifacts[1].digest, SHA)
        end)

        test.it("retains copied host database bindings in the preflight context", function()
            local policy: Policy = {node_id = "node-destination", policy_digest = SHA,
                packages = {["vendor/app"] = true}, namespaces = {app = true},
                kinds = {["function.lua"] = true}, databases = {["app:data"] = true},
                grants = {}, modules = {}, applied = {}, migration_barrier = true,
                auto_start = false,
                database_bindings = {["app:data"] = {database_id = "host:db", table_prefix = "app_"}}}
            local deps, spec = deps_fixture(policy)
            local resolved = facts(deps, spec)
            test.eq(resolved.context.database_bindings["app:data"].database_id, "host:db")
            test.eq(resolved.context.database_bindings["app:data"].table_prefix, "app_")
            local source_binding = assert(bounds.object((assert(bounds.object(policy.database_bindings)))["app:data"]))
            source_binding.database_id = "other:db"
            test.eq(resolved.context.database_bindings["app:data"].database_id, "host:db")
        end)

        test.it("omits empty dependency parameters from the native preview root", function()
            local deps, spec, observed = deps_fixture(nil)
            spec.parameters = {}
            local resolved = facts(deps, spec)
            local root = observed.root
            test.is_true(root ~= nil)
            test.is_nil((assert(bounds.object((assert(bounds.object(root))).data))).parameters)
            test.eq(resolved.candidate.base_revision, 23)
        end)

        test.it("keeps the relevant base digest stable when unrelated definitions change", function()
            local deps, spec, observed = deps_fixture(nil)
            local first = facts(deps, spec)
            local captured = observed.captured
            captured.entries[#captured.entries + 1] = entry("other:unrelated", "host/other", "first")
            local second = facts(deps, spec)
            test.eq(second.candidate.base_digest, first.candidate.base_digest)
            test.eq((second.context).registry_digest, first.candidate.base_digest)
        end)

        test.it("removes dependency directives from the flattened artifact", function()
            local deps, spec = deps_fixture(nil)
            local resolved = facts(deps, spec)
            for _, item in ipairs(resolved.candidate.entries) do
                test.is_false(item.kind == "ns.dependency")
            end
            test.is_true(find_entry(resolved.candidate.entries, "app:root") == nil)
        end)

        test.it("takes entry ownership from registry metadata rather than artifact claims", function()
            local deps, spec = deps_fixture(nil)
            local resolved = facts(deps, spec)
            local claimed = find_entry(resolved.candidate.entries, "app:claimed")
            test.eq((claimed).package, "vendor/app")
            test.eq((resolved.context.entries["app:claimed"]).package, "vendor/app")
        end)

        test.it("requires the reviewed artifact bytes and digest to match exactly", function()
            local deps, spec = deps_fixture(nil)
            local altered = source_artifact()
            altered.entries[2].data.source = "return 'altered'"
            local rebuilt = assert(artifact.create(altered.entries))
            spec.artifact_bytes, spec.artifact_digest = rebuilt.bytes, rebuilt.digest
            local candidate, context, err = resolver.resolve_with(deps, spec)
            test.is_true(candidate == nil)
            test.is_true(context == nil)
            test.is_true(err ~= nil)
        end)

        test.it("keeps the host policy authoritative over package claims", function()
            local denied: Policy = {
                node_id = "node-destination", registry_digest = SHA, policy_digest = SHA,
                packages = {["vendor/app"] = false}, namespaces = {app = false},
                kinds = {["function.lua"] = false}, databases = {["host:db"] = true},
                grants = {}, modules = {}, entries = {}, applied = {},
                exact_expansion = true, protected = KERNEL, migration_barrier = true, auto_start = false,
            }
            local deps, spec = deps_fixture(denied)
            local candidate, context, err = resolver.resolve_with(deps, spec)
            if not candidate or not context then error(tostring(err)) end
            -- Resolution may describe a denied candidate so preflight can
            -- report all diagnostics.  It must carry the host's ceiling
            -- unchanged; registry/package claims cannot widen it.
            test.is_false(context.packages["vendor/app"])
            test.is_false(context.namespaces.app)
            test.is_false(context.kinds["function.lua"])
        end)
    end)
end

return test.run_cases(define_tests)
