-- MIT. Hub resolution tests use a host-owned registry preview double.  The
-- double is deliberately small: it exposes the same capture/root/policy
-- boundaries as the destination host without granting this test a registry
-- writer or an execution capability.
local test = require("test")
local artifact = require("artifact")
local resolver = require("hub_resolver")

type Object = {[string]: unknown}
type Spec = {owner_node: string, source_node: string, artifact_bytes: string, artifact_digest: string,
    parameters: {unknown}?}
type Artifact = {schema_revision: string, entries: {Object}, bytes: string, digest: string}
type CandidateEntry = {id: string, kind: string, package: string, digest: string,
    references: {string}, auto_start: boolean, grants: {string}, modules: {string}}
type Candidate = {destination_node: string, source_node: string, base_revision: integer,
    base_digest: string, artifacts: {Object}, entries: {CandidateEntry}, requirements: {Object}, migrations: {Object}}
type Context = {node_id: string, registry_revision: integer, registry_digest: string,
    policy_digest: string, packages: {[string]: boolean}, namespaces: {[string]: boolean},
    kinds: {[string]: boolean}, databases: {[string]: boolean}, grants: {[string]: boolean},
    modules: {[string]: boolean}, entries: {[string]: CandidateEntry}, applied: {[string]: Object},
    exact_expansion: boolean, migration_barrier: boolean}
type Facts = {candidate: Candidate, context: Context}
type Captured = {revision: integer, entries: {Object}, resolution: Object?, preview: (Object) -> (Object?, string?)}
type Policy = {node_id: string, policy_digest: string, packages: {[string]: boolean},
    namespaces: {[string]: boolean}, kinds: {[string]: boolean}, databases: {[string]: boolean},
    grants: {[string]: boolean}, modules: {[string]: boolean}, applied: {[string]: unknown},
    migration_barrier: boolean}

local SHA = string.rep("a", 64)

local function entry(id: string, package_name: string, value: string): Object
    return {id = id, kind = "function.lua", registry = {owner = package_name},
        source = "return '" .. value .. "'", data = {value = value}}
end

local function source_artifact(): Artifact
    -- Ownership is deliberately absent from transferred artifact entries.
    -- The destination must obtain it from the registry preview.
    local made = artifact.create({
        {id = "app:claimed", kind = "function.lua", source = "return 'registry-owner'", data = {value = "registry-owner"}},
        {id = "app:kept", kind = "function.lua", source = "return 'unchanged'", data = {value = "unchanged"}},
        {id = "app:new", kind = "function.lua", source = "return 'preview-created'", data = {value = "preview-created"}},
    })
    if not made then error("cannot create resolver artifact") end
    return made
end

local function deps_fixture(policy: Object?): (Object, Spec, {root: Object?, captured: Captured?})
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
    }
    local updated_entry = entry("app:claimed", "vendor/app", "registry-owner")
    local preview_entry = entry("app:new", "vendor/app", "preview-created")
    local deleted_entry = entry("app:removed", "vendor/app", "removed-by-preview")
    local preview: Object = {
        -- A runtime preview normally contains changes, so this intentionally
        -- omits app:kept.  The resolver must flatten the selected package's
        -- unchanged registry entries together with these changes.
        digest = SHA,
        changes = {{kind = "entry.update", entry = updated_entry},
            {kind = "entry.create", entry = preview_entry},
            {kind = "entry.delete", entry = deleted_entry}},
        resolution = {modules = {
            {name = "vendor/app", version = "1.2.0", digest = "sha256:" .. SHA},
            {name = "host/base", version = "1.0.0", digest = SHA},
        }},
    }
    local captured: Captured = {
        revision = 23, entries = current, resolution = {base = "captured"},
        preview = function(root_entry: Object): (Object?, string?)
            observed.root = root_entry
            return preview, nil
        end,
    }
    observed.captured = captured
    local selected_policy: Policy
    if policy then
        selected_policy = policy :: Policy
    else
        selected_policy = {node_id = "node-destination", policy_digest = SHA,
            packages = {["vendor/app"] = true}, namespaces = {app = true},
            kinds = {["function.lua"] = true}, databases = {["host:db"] = true},
            grants = {}, modules = {}, applied = {}, migration_barrier = true}
    end
    local deps: Object = {
        capture = function(): (unknown?, string?) return captured, nil end,
        root = function(root_spec: Object): (Object?, string?)
            return {component = "vendor/app", version = "1.2.0", parameters = root_spec.parameters or {}}, nil
        end,
        policy = function(_: Object, _: Captured, _: Object): (Policy?, string?) return selected_policy, nil end,
    }
    return deps, spec, observed
end

local function facts(deps: Object, spec: Spec): Facts
    local candidate, context, err = resolver.resolve_with(deps, spec)
    if not candidate or not context then error(tostring(err)) end
    return {candidate = candidate :: Candidate, context = context :: Context}
end

local function find_entry(entries: {CandidateEntry}, id: string): CandidateEntry?
    for _, item in ipairs(entries) do if item.id == id then return item end end
    return nil
end

local function define_tests()
    test.describe("Hub registry resolver", function()
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

        test.it("omits empty dependency parameters from the native preview root", function()
            local deps, spec, observed = deps_fixture(nil)
            spec.parameters = {}
            local resolved = facts(deps, spec)
            local root = observed.root
            test.is_true(root ~= nil)
            test.is_nil(((root :: Object).data :: Object).parameters)
            test.eq(resolved.candidate.base_revision, 23)
        end)

        test.it("keeps the relevant base digest stable when unrelated definitions change", function()
            local deps, spec, observed = deps_fixture(nil)
            local first = facts(deps, spec)
            local captured = observed.captured :: Captured
            captured.entries[#captured.entries + 1] = entry("other:unrelated", "host/other", "first")
            local second = facts(deps, spec)
            test.eq(second.candidate.base_digest, first.candidate.base_digest)
            test.eq((second.context :: Context).registry_digest, first.candidate.base_digest)
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
            test.eq((claimed :: CandidateEntry).package, "vendor/app")
            test.eq((resolved.context.entries["app:claimed"] :: CandidateEntry).package, "vendor/app")
        end)

        test.it("requires the reviewed artifact bytes and digest to match exactly", function()
            local deps, spec = deps_fixture(nil)
            local altered = source_artifact()
            altered.entries[2].source = "return 'altered'"
            local rebuilt = assert(artifact.create(altered.entries))
            spec.artifact_bytes, spec.artifact_digest = rebuilt.bytes, rebuilt.digest
            local candidate, context, err = resolver.resolve_with(deps, spec)
            test.is_true(candidate == nil)
            test.is_true(context == nil)
            test.is_true(err ~= nil)
        end)

        test.it("keeps the host policy authoritative over package claims", function()
            local denied: Object = {
                node_id = "node-destination", registry_digest = SHA, policy_digest = SHA,
                packages = {["vendor/app"] = false}, namespaces = {app = false},
                kinds = {["function.lua"] = false}, databases = {["host:db"] = true},
                grants = {}, modules = {}, entries = {}, applied = {},
                exact_expansion = true, migration_barrier = true,
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
